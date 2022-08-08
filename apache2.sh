#!/bin/bash

# Updates pem files and restarts apache2 service

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# local path to store key/cert
local_certs=/etc/apache2/certs
# server hosting key/cert
server=certdp.local
# name of the key/cert (as it is on server)
cert_name=adguard.local
# path to store a timestamp to easily see when script last ran
time_stamp=/etc/apache2/certera.txt

## Script

sudo mkdir $local_certs/temp
# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(sudo curl https://$server/api/certificate/$cert_name -H "apiKey: $cert_apikey" --out $local_certs/temp/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(sudo curl https://$server/api/key/$cert_name -H "apiKey: $key_apikey" --out $local_certs/temp/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

if ( ! cmp -s "$local_certs/temp/certchain.pem" "$local_certs/certchain.pem" ) || ( ! cmp -s "$local_certs/temp/key.pem" "$local_certs/key.pem" ) ; then

        sudo service apache2 stop

        sudo cp -rf $local_certs/temp/* $local_certs/

        sudo chown root:root $local_certs/*

        sudo chmod 600 $local_certs/key.pem
        sudo chmod 644 $local_certs/certchain.pem

        sudo service apache2 start
fi

sudo rm -rf $local_certs/temp
echo "Last Run: $(date)" > $time_stamp
