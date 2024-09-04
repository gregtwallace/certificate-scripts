#!/bin/bash

# Script converts key/cert into pfx and then updates them
# in unifi's keystore. It also restarts the unifi service.

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# The Unifi Controller does NOT support ECDSA Keys as of 2022.08.27

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
cert_name=unifi.example.com

# URL paths
api_cert_path=certwarden/api/v1/download/certificates/$cert_name
api_key_path=certwarden/api/v1/download/privatekeys/$cert_name
# local user who will own certs
cert_owner=unifi
# unifi controller keystore location
unifi_keystore=/var/lib/unifi/keystore
# local cert storage
app_certs=/var/lib/unifi/certs
# temp folder
temp_certs=/tmp/tempcerts
# path to store a timestamp to easily see when script last ran
time_stamp=/var/lib/unifi/cert_timestamp.txt

## Script
# stop / fail on any error
set -e

rm -rf $temp_certs
mkdir -p $temp_certs
mkdir -p $app_certs
# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(curl -L https://$server/$api_cert_path -H "apiKey: $cert_apikey" --output $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(curl -L https://$server/$api_key_path -H "apiKey: $key_apikey" --output $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

# if different
if ( ! cmp -s "$temp_certs/certchain.pem" "$app_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$app_certs/key.pem" ) ; then
	systemctl stop unifi

	cp -rf $temp_certs/* $app_certs/
	openssl pkcs12 -inkey $app_certs/key.pem -in $app_certs/certchain.pem -export -out $app_certs/certchain_key.pfx -passout pass:""

	chown $cert_owner:$cert_owner $app_certs/*
	chmod 600 $app_certs/key.pem
	chmod 600 $app_certs/certchain_key.pfx
	chmod 644 $app_certs/certchain.pem

  keytool -delete -alias 1 -keystore $unifi_keystore -deststorepass "aircontrolenterprise"
  keytool -importkeystore -srckeystore $app_certs/certchain_key.pfx -srcstoretype PKCS12 -srcstorepass "" -destkeystore $unifi_keystore \
		  -deststorepass "aircontrolenterprise" -destkeypass "aircontrolenterprise" -trustcacerts

	systemctl start unifi
fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
