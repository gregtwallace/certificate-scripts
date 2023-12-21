#!/bin/sh

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I placed the script in /root/lego and it seems fine.

# Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# NOTE: If LeGo server is running on a VM, add sleep 300-600 to wait 5-10 minutes for
# the VM to come up

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# server hosting key/cert
server=certdp.local:port
# name of the key/cert (as it is on server)
cert_name=unifi.example.com

# URL paths
api_cert_path=legocerthub/api/v1/download/certificates/$cert_name
api_key_path=legocerthub/api/v1/download/privatekeys/$cert_name


# other
xcp_cert=/etc/xensource/xapi-ssl.pem
cert_owner=root:root
# temp folder
temp_certs=/tmp/tempcerts
# path to store a timestamp to easily see when script last ran
time_stamp=/root/lego/timestamp.txt

####
# stop / fail on any error
set -e

mkdir $temp_certs
# Fetch LeGo
http_statuscode=$(wget https://$server/$api_cert_path --header="apiKey: $cert_apikey" -O $temp_certs/cert.pem --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if test $http_statuscode -ne 200; then exit 1; fi
http_statuscode=$(wget https://$server/$api_key_path --header="apiKey: $key_apikey" -O $temp_certs/key.pem --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if test $http_statuscode -ne 200; then exit 1; fi

# concat to expected single file
cat $temp_certs/key.pem > $temp_certs/xapi-ssl.pem
echo "" >> $temp_certs/xapi-ssl.pem
cat $temp_certs/cert.pem >> $temp_certs/xapi-ssl.pem

diffs=$(diff "$xcp_cert" "$temp_certs/xapi-ssl.pem")
diffcode=$?

if [ "$diffcode" != 0 ] ; then

	#no need to stop anything

	cp -f "$temp_certs/xapi-ssl.pem" "$xcp_cert"
	chown $cert_owner "$xcp_cert"
	chmod 400 "$xcp_cert"

	#restart api
	systemctl restart xapi
fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
