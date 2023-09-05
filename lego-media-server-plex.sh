#!/bin/bash

# Script converts key/cert into pfx and then updates the plex
# certificate and the neginx certificate. It also restarts the
# plex and nginx services.

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
cert_name=plex.example.com

# URL paths
api_cert_path=legocerthub/api/v1/download/certificates/$cert_name
api_key_path=legocerthub/api/v1/download/privatekeys/$cert_name
# local user who will own the plex cert
plex_user=plex
# local cert storage
plex_certs=/home/plex/certs
nginx_certs=/etc/nginx/certs
# path to store a timestamp to easily see when script last ran
time_stamp=/home/plex/cert_timestamp.txt
# temp folder
temp_certs=/tmp/tempcerts

## Script
sudo rm -rf $temp_certs
sudo mkdir $temp_certs
sudo mkdir -p $plex_certs
sudo mkdir -p $nginx_certs

# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(sudo -L curl https://$server/$api_cert_path -H "apiKey: $cert_apikey" --out $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(sudo -L curl https://$server/$api_key_path -H "apiKey: $key_apikey" --out $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

# Update plex
# if different
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
# if different
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
