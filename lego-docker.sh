#!/bin/bash

# Updates the cert files on the docker host and then restarts the
# container(s) (which should have cert storage mapped to them as an
# ro partition)

## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# server hosting key/cert
server=certdp.local:port
# name of the key/cert (as it is on server)
cert_name=plex.example.com

# URL paths
api_cert_path=certwarden/api/v1/download/certificates/$cert_name
api_key_path=certwarden/api/v1/download/privatekeys/$cert_name
# local user who will own certs
cert_owner=root
# local cert storage
local_certs=/opt/certwarden/certs
# path to store a timestamp to easily see when script last ran
time_stamp=/opt/certwarden/timestamp.txt
# temp folder
temp_certs=$local_certs/temp

## Script
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo "Not running as root"
    exit
fi

# stop / fail on any error
set -e

mkdir -p $temp_certs
mkdir -p $local_certs
chown root:root $local_certs
chmod 0700 $local_certs

# Fetch certs, if curl returns anything other than 200 success, abort
http_statuscode=$(curl -L https://$server/$api_cert_path -H "apiKey: $cert_apikey" --output $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi
http_statuscode=$(curl -L https://$server/$api_key_path -H "apiKey: $key_apikey" --output $temp_certs/key.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

if ( ! cmp -s "$temp_certs/certchain.pem" "$local_certs/certchain.pem" ) || ( ! cmp -s "$temp_certs/key.pem" "$local_certs/key.pem" ) ; then
    
    # make plex compatible key/certificate
    sudo openssl pkcs12 -inkey $temp_certs/key.pem -in $temp_certs/certchain.pem -export -out $temp_certs/certchain_key.pfx -passout pass:""

    ## stop whatever services (that run the containers)
	systemctl stop mycontainer1
    systemctl stop mycontainer2

    cp -rf $temp_certs/* $local_certs/

    chown $cert_owner:$cert_owner $local_certs/*

    chmod 600 $local_certs/key.pem
    chmod 644 $local_certs/certchain.pem

    ## start whatever services (that run the containers)
    systemctl start mycontainer1
    systemctl start mycontainer2
fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
