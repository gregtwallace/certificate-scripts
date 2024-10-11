#!/bin/bash

# Script converts key/cert into pfx and then updates them
# in unifi's keystore. It also restarts the unifi service.

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>

# local cert storage
app_certs=/home/greg/unifi-certs
# server hosting key/cert
server=certdp.local
# name of the key/cert (as it is on server)
cert_name=unifi.local
# local user who will own certs
cert_owner=unifi

# unifi controller keystore location
unifi_keystore=/var/lib/unifi/keystore

# temp folder
temp_certs=/tmp/tempcerts

# path to store a timestamp to easily see when script last ran
time_stamp=/home/greg/certera.txt

## Script
sudo mkdir $temp_certs
# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(sudo curl https://$server/api/certificate/$cert_name -H "apiKey: $cert_apikey" --output $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(sudo curl https://$server/api/key/$cert_name -H "apiKey: $key_apikey" --output $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

# if different
if ( ! cmp -s "$temp_certs/certchain.pem" "$app_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$app_certs/key.pem" ) ; then
	sudo systemctl stop unifi

	sudo cp -rf $temp_certs/* $app_certs/
	sudo openssl pkcs12 -inkey $app_certs/key.pem -in $app_certs/certchain.pem -export -out $app_certs/certchain_key.pfx -passout pass:""

	sudo chown $cert_owner:$cert_owner $app_certs/*
	sudo chmod 600 $app_certs/key.pem
	sudo chmod 600 $app_certs/certchain_key.pfx
	sudo chmod 644 $app_certs/certchain.pem

	sudo keytool -delete -alias 1 -keystore $unifi_keystore -deststorepass "aircontrolenterprise"
	sudo keytool -importkeystore -srckeystore $app_certs/certchain_key.pfx -srcstoretype PKCS12 -srcstorepass "" -destkeystore $unifi_keystore \
		-deststorepass "aircontrolenterprise" -destkeypass "aircontrolenterprise" -alias 1 -trustcacerts

	sudo systemctl start unifi
fi

sudo rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
