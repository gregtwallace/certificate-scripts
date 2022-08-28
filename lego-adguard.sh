#!/bin/bash

# Script converts key/cert into pfx and then updates them
# in unifi's keystore. It also restarts the unifi service.

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# ECDSA Keys ARE supported

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# server hosting key/cert
server=certdp.local:port
# name of the key/cert (as it is on server)
cert_name=adguard.example.com

# URL paths
api_cert_path=api/v1/download/certificates/$cert_name
api_key_path=api/v1/download/privatekeys/$cert_name
# local user who will own certs
cert_owner=root
# local cert storage
local_certs=/opt/AdGuardHome/certs
# path to store a timestamp to easily see when script last ran
time_stamp=/opt/AdGuardHome/certs/cert_timestamp.txt
# temp folder
temp_certs=/tmp/tempcerts

## Script
sudo rm -rf $temp_certs
sudo mkdir $temp_certs
sudo mkdir -p $local_certs
# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(sudo curl https://$server/$api_cert_path -H "apiKey: $cert_apikey" --out $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(sudo curl https://$server/$api_key_path -H "apiKey: $key_apikey" --out $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

if ( ! cmp -s "$temp_certs/certchain.pem" "$local_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$local_certs/key.pem" ) ; then

		echo "different"

        sudo service AdGuardHome stop

        sudo cp -rf $temp_certs/* $local_certs/

        sudo chown $cert_owner:$cert_owner $local_certs/*

        sudo chmod 600 $local_certs/key.pem
        sudo chmod 644 $local_certs/certchain.pem

        sudo service AdGuardHome start
fi

sudo rm -rf $local_certs/temp
echo "Last Run: $(date)" > $time_stamp
