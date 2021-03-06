#!/bin/bash

VERSION=`cat /etc/steemdversion`

STEEMD="/usr/local/steemd-testnet/bin/steemd"

UTILS="/usr/local/steemd-testnet/bin"

chown -R steemd:steemd $HOME

# clean out data dir since it may be semi-persistent block storage on the ec2 with stale data
rm -rf $HOME/*

mkdir -p $HOME/testnet_datadir

# for the seed node to connect to the bootstrap node
ARGS+=" --p2p-seed-node=127.0.0.1:12001"
ARGS+=" --chain-id=$CHAIN_ID"
BOOTARGS+=" --chain-id=$CHAIN_ID"

# copy over config for testnet init and bootstrap nodes
cp /etc/steemd/testnet.config.ini $HOME/config.ini
cp /etc/steemd/fastgen.config.ini $HOME/testnet_datadir/config.ini

chown steemd:steemd $HOME/config.ini
chown steemd:steemd $HOME/testnet_datadir/config.ini

cd $HOME

mv /etc/nginx/nginx.conf /etc/nginx/nginx.original.conf
cp /etc/nginx/steemd.nginx.conf /etc/nginx/nginx.conf
# testnet nginx conf is pulled in directly from steem repo
# leaving the line below for when we change that flow
# cp ./testnet-web-console.conf /etc/nginx/sites-enabled/testnet-web-console.conf

# for appbase tags plugin loading
ARGS+=" --tags-skip-startup-update"

cd $HOME

# setup tinman
git clone --branch master https://github.com/steemit/tinman
virtualenv -p $(which python3) ~/ve/tinman
source ~/ve/tinman/bin/activate
cd tinman
pip install pipenv && pipenv install
pip install .

cd $HOME

cp $HOME/tinman/gatling.conf.example $HOME/gatling.conf
cp $HOME/tinman/durables.conf.example $HOME/durables.conf

# get latest actions list from s3
if [[ -n "$SKIP_MAIN_ACCOUNT_CREATION" ]]; then
  echo steemd-testnet: actions will skip main account creation and backfill
  aws s3 cp s3://$S3_BUCKET/no-accounts-txgen-latest.actions ./txgen.actions
elif [[ -n "$SKIP_BACKFILL_ACTIONS" ]]; then
  echo steemd-testnet: actions will skip backfill
  aws s3 cp s3://$S3_BUCKET/txgen-latest.actions ./txgen.actions
else
  echo "steemd-testnet: using full actions (with backfill and main account creation)"
  aws s3 cp s3://$S3_BUCKET/txgen-backfill-latest.actions ./txgen.actions
fi

chown -R steemd:steemd $HOME/*

echo steemd-testnet: starting bootstrap node
# start the bootstrap node
exec chpst -usteemd \
    $STEEMD \
        --webserver-ws-endpoint=0.0.0.0:9990 \
        --webserver-http-endpoint=0.0.0.0:9990 \
        --p2p-endpoint=0.0.0.0:12001 \
        --data-dir=$HOME/testnet_datadir \
        $BOOTARGS \
        2>&1&

# give the bootstrap node some time to startup
sleep 120

# pipe the transactions through keysub and into the fastgen node
echo steemd-testnet: pipelining transactions into bootstrap node, this may take some time
( \
  echo [\"set_secret\", {\"secret\":\"$SHARED_SECRET\"}] ; \
  cat txgen.actions \
) | \
tinman keysub --get-dev-key $UTILS/get_dev_key | \
tinman submit --realtime -t http://127.0.0.1:9990 --signer $UTILS/sign_transaction -c $CHAIN_ID --timeout 600

# add a newline to the config file in case it does not end with a newline
echo -en '\n' >> config.ini

# add witness names to config file
i=0 ; while [ $i -lt 21 ] ; do echo witness = '"'init-$i'"' >> config.ini ; let i=i+1 ; done

# add keys derived from shared secret to config file
$UTILS/get_dev_key $SHARED_SECRET block-init-0:21 | cut -d '"' -f 4 | sed 's/^/private-key = /' >> config.ini

# sleep for an arbitrary amount of time before starting the seed
sleep 10

if [[ -n "$SKIP_SEED_NODE" ]]; then
  echo steemd-testnet: done early
  exit 0
else
  # let's get going
  echo steemd-testnet: bringing up witness / seed / full node
  cp /etc/nginx/healthcheck.conf.template /etc/nginx/healthcheck.conf
  echo server 127.0.0.1:8091\; >> /etc/nginx/healthcheck.conf
  echo } >> /etc/nginx/healthcheck.conf
  rm /etc/nginx/sites-enabled/default
  cp /etc/nginx/healthcheck.conf /etc/nginx/sites-enabled/default
  /etc/init.d/fcgiwrap restart
  service nginx restart
  exec chpst -usteemd \
      $STEEMD \
          --webserver-ws-endpoint=0.0.0.0:8091 \
          --webserver-http-endpoint=0.0.0.0:8091 \
          --p2p-endpoint=0.0.0.0:2001 \
          --data-dir=$HOME \
          $ARGS \
          2>&1&

  # give the seed some time to start up
  sleep 120

  # wait for seed to be synced before proceeding

  all_clear=1
  
  if [[ -z "$SKIP_WARDEN" ]]; then
    while [[ $all_clear -ne 0 ]]
    do
        tinman warden -s http://127.0.0.1:8091
        all_clear=$?
        echo Waiting for warden to sound the all-clear.
        sleep 60
    done

    echo steemd-testnet: seed is synced
  fi
fi

if [[ -z "$SKIP_DASHBOARD" ]]; then
  jq ".shared_secret=\"$SHARED_SECRET\"" $HOME/tinman/server.conf.example > $HOME/server.conf.temp
  jq ".transaction_target.node=\"http://127.0.0.1:8091\"" $HOME/server.conf.temp > $HOME/server.conf
  rm $HOME/server.conf.temp
  
  chown -R steemd:steemd $HOME/*
  
  echo server-testnet: starting server on port 5000
  tinman server \
    --get-dev-key $UTILS/get_dev_key \
    --signer $UTILS/sign_transaction \
    --timeout 600 \
    --chain-id $CHAIN_ID &
fi

finished=0
while [[ $finished == 0 ]]
do
if [[ -z "$SKIP_GATLING" ]]; then
  echo steemd-testnet: launching gatling to pipe transactions from mainnet to testnet
  if [[ -z "$SKIP_DURABLES" ]]; then
    echo steemd-testnet: launching gatling to pipe transactions from mainnet to testnet
    ( \
      echo "[\"set_secret\", {\"secret\":\"$SHARED_SECRET\"}]" ; \
      tinman durables -c durables.conf ; \
      tinman gatling -c gatling.conf -f 0 -t 0 -o - | tinman prefixsub \
    ) | \
    tinman keysub --get-dev-key $UTILS/get_dev_key | \
    tinman submit --realtime -t http://127.0.0.1:8091 \
        --signer $UTILS/sign_transaction \
        -c $CHAIN_ID \
        --timeout 600
  else
    echo "steemd-testnet: launching gatling (wihout durables) to pipe transactions from mainnet to testnet"
    ( \
      echo "[\"set_secret\", {\"secret\":\"$SHARED_SECRET\"}]" ; \
      tinman gatling -c gatling.conf -f 0 -t 0 -o - | tinman prefixsub \
    ) | \
    tinman keysub --get-dev-key $UTILS/get_dev_key | \
    tinman submit --realtime -t http://127.0.0.1:8091 \
        --signer $UTILS/sign_transaction \
        -c $CHAIN_ID \
        --timeout 600
  fi
fi

# prevent flapping
sleep 60
done

echo steemd-testnet: done
