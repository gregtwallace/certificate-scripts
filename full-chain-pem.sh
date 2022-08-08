#!/bin/bash

# Generic script to store key and cert locally in pem format
# if desired, the if block can be edited to stop and start
# any relevant services

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
local_certs=/opt/certera/certs
# local user to own the key/cert
user=root
# server hosting key/cert
server=certdp.local
# name of the key/cert (as it is on server)
cert_name=adguard.local
# path to store a timestamp to easily see when script last ran
time_stamp=/opt/certera/timestamp.txt

## Script

sudo mkdir $local_certs/temp
# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(sudo curl https://$server/api/certificate/$cert_name -H "apiKey: $cert_apikey" --out $local_certs/temp/fullchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(sudo curl https://$server/api/key/$cert_name -H "apiKey: $key_apikey" --out $local_certs/temp/privkey.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

if ( ! cmp -s "$local_certs/temp/fullchain.pem" "$local_certs/fullchain.pem" ) || ( ! cmp -s "$local_certs/temp/privkey.pem" "$local_certs/privkey.pem" ) ; then

		echo "different"

        # if desired, stop services
        # sudo service SomeService stop

        sudo cp -rf $local_certs/temp/* $local_certs/

        # set owner as appropriate
        sudo chown $user:$user $local_certs/*

        sudo chmod 600 $local_certs/privkey.pem
        sudo chmod 644 $local_certs/fullchain.pem

        # if desired, start services
        # sudo service SomeService start
fi

sudo rm -rf $local_certs/temp
echo "Last Run: $(date)" > $time_stamp
