#!/bin/bash

# Script to store key and cert locally in pem format AND
# to also store them in pfx format (which is what Plex uses)
# script will also stop and start nginx and plex

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# local path to store key/cert pems (usually for an nginx reverse proxy)
nginx_certs=/etc/nginx/certs
# local path to store pfx for plex, and user that should own the pfx file
plex_certs=/home/plex/certs
plex_user=plex
# server hosting key/cert
server=certdp.local
# name of the key/cert (as it is on server)
cert_name=media-server.local
# path to store a timestamp to easily see when script last ran
time_stamp=/opt/certera/timestamp.txt

# temporary certificate storage (will be removed after script runs)
temp_certs=/tmp/tempcerts

## Script
script_path="`( cd \"$MY_PATH\" && pwd )`"

sudo mkdir $temp_certs
# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(sudo curl https://$server/api/certificate/$cert_name -H "apiKey: $cert_apikey" --out $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(sudo curl https://$server/api/key/$cert_name -H "apiKey: $key_apikey" --out $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

# Update plex
if ( ! cmp -s "$temp_certs/certchain.pem" "$plex_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$plex_certs/key.pem" ) ; then

                sudo service plexmediaserver stop

                sudo cp -rf $temp_certs/* $plex_certs/
                sudo openssl pkcs12 -inkey $plex_certs/key.pem -in $plex_certs/certchain.pem -export -out $plex_certs/certchain_key.pfx -passout pass:""

                sudo chown $plex_user:$plex_user $plex_certs/*
                sudo chown $plex_user:$plex_user $plex_certs/*

                sudo chmod 600 $plex_certs/key.pem
                sudo chmod 644 $plex_certs/certchain.pem
                sudo chmod 600 $plex_certs/certchain_key.pfx

                sudo service plexmediaserver start
fi

# Update nginx (reverse proxy)
if ( ! cmp -s "$temp_certs/certchain.pem" "$nginx_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$nginx_certs/key.pem" ) ; then

                sudo service nginx stop

                sudo cp -rf $temp_certs/* $nginx_certs/

                sudo chown root:root $nginx_certs/*

                sudo chmod 600 $nginx_certs/key.pem
                sudo chmod 644 $nginx_certs/certchain.pem

                sudo service nginx start
fi

sudo rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
