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
# stop / fail on any error
set -e

rm -rf $temp_certs
mkdir -p $temp_certs
mkdir -p $plex_certs
chown $plex_user:$plex_user $plex_certs
chmod 0755 $plex_certs
mkdir -p $nginx_certs
chown root:root $nginx_certs
chmod 0755 $nginx_certs

# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(-L curl https://$server/$api_cert_path -H "apiKey: $cert_apikey" --out $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(-L curl https://$server/$api_key_path -H "apiKey: $key_apikey" --out $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

# Update plex
# if different
if ( ! cmp -s "$temp_certs/certchain.pem" "$plex_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$plex_certs/key.pem" ) ; then
	service plexmediaserver stop

	cp -rf $temp_certs/* $plex_certs/

	openssl pkcs12 -export -out $temp_certs/certchain_key.p12 \
		-certpbe AES-256-CBC -keypbe AES-256-CBC -macalg SHA256 \
		-inkey $temp_certs/key.pem -in $temp_certs/certchain.pem \
		-passout pass:

	chown $plex_user:$plex_user $plex_certs/*

	chmod 600 $plex_certs/key.pem
	chmod 644 $plex_certs/certchain.pem
	chmod 600 $plex_certs/certchain_key.pfx

	service plexmediaserver start
fi

# Update nginx (reverse proxy)
# if different
if ( ! cmp -s "$temp_certs/certchain.pem" "$nginx_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$nginx_certs/key.pem" ) ; then
	service nginx stop

	cp -rf $temp_certs/* $nginx_certs/

	chown root:root $nginx_certs/*

	chmod 600 $nginx_certs/key.pem
	chmod 644 $nginx_certs/certchain.pem

	service nginx start
fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
