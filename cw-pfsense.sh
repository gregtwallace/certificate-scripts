#!/bin/sh

# Script updates the specified (already existing) certificate
# on the pfSense box.

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys
# /conf is the recommended path as a good persistent storage
# location.

# ECDSA Keys ARE supported

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# cron package must be installed and then settings can be configured
# in Services > Cron
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# /conf is a persisting path (e.g. use /conf/certwarden)

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# server hosting key/cert
server=certdp.local:port
# name of the key/cert (as it is on server)
cert_name=pfsense.example.com

# URL paths
api_cert_path=certwarden/api/v1/download/certificates/$cert_name
api_key_path=certwarden/api/v1/download/privatekeys/$cert_name
# path to store a timestamp to easily see when script last ran
time_stamp=/conf/certwarden_timestamp.txt
# temp folder
temp_certs=/tmp/tempcerts

# pfSense config
pfsense_config=/conf/config.xml
# no base64 package, so use python (may need to change version depending
# on what version of pfSense is installed)
python_bin="/usr/local/bin/python3.9"
# Descriptive name of the cert to update
pfsense_cert_name="certwarden pfsense.example.com"

## Script
# stop / fail on any error
set -e

# Set umask
umask 077

# Make folders if don't exist
mkdir -p "$temp_certs"

# Check for python
if [ ! -f $python_bin ] ; then
	echo "python binary missing"
	exit 1
fi

# base64 encoding command
base64_enc="${python_bin} -m base64 -e"

# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(curl https://$server/$api_cert_path -H "apiKey: $cert_apikey" --output $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then echo "get cert failed"; exit "$http_statuscode"; fi
http_statuscode=$(curl https://$server/$api_key_path -H "apiKey: $key_apikey" --output $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then echo "get  failed"; exit "$http_statuscode"; fi

# Convert new cert/key to proper format; first step encodes, second step removes spaces
cert=$(cat $temp_certs/certchain.pem | $base64_enc)
cert=$(echo $cert | sed "s/ //g")
key=$(cat $temp_certs/key.pem | $base64_enc)
key=$(echo $key | sed "s/ //g")

# Find old cert/key in config to check if matches (and to potentially replace)
# Note: if somehow <crt> or <prv> end up before description, this won't work
oldcertificate=$(grep -A4 "$pfsense_cert_name" $pfsense_config | awk '/<crt>/ { print $1}' | sed "s|<crt>||g" | sed "s|</crt>||g")
oldprivatekey=$(grep -A4 "$pfsense_cert_name" $pfsense_config | awk '/<prv>/ { print $1}' | sed "s|<prv>||g" | sed "s|</prv>||g")

# check if different
if [ "$cert" != "$oldcertificate" ] || [ "$key" != "$oldprivatekey" ] ; then

	# don't need to stop a service

	# replace the cert/key in config file
	# first check only between <cert> blocks
	# then check between exact starting description and end of that cert block
	# then do replacement
	# Note: if somehow <crt> or <prv> end up before description, this won't work
	sed -i -E '/\t<cert>/,/\t<\/cert>/ {
		/<descr><!\[CDATA\['"$pfsense_cert_name"'\]\]>/,/<\/cert>/ {
			s/\(<crt>\).*\(<\/crt>\)/\1'"$cert"'\2/g;
			s/\(<prv>\).*\(<\/prv>\)/\1'"$key"'\2/g;
		};
	}' $pfsense_config

	# must delete config cache or it won't load the new cert
	rm /tmp/config.cache

	# restart webui
	/etc/rc.restart_webgui
	# IF using cert in unbound, restart it also
	/usr/local/sbin/pfSsh.php playback svc restart unbound

fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
