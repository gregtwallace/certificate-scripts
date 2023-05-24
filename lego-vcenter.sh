#!/bin/sh

# Script updates vCenter server certificate. Run this script on the
# vCenter server. The vCenter server should either be in Hybrid or
# Full Custom Certificate Mode.

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# vCenter 6.7 only supports RSA 2,048 bit. It appears vCenter 7 adds
# additional key lengths, but I have not tested this.

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# su to login as local root user
# `crontab -e` to edit crontab
## Recommended Content:
# 45 3 * * 3 /opt/lego/lego.sh
# @reboot sleep 600 && /opt/lego/lego.sh


## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# server hosting key/cert
server=certdp.local:port
# name of the key/cert (as it is on server)
cert_name=vcenter.example.com
# vCenter sso login
sso_admin=<username>
sso_password=<password>

# path to root cert (at time of writing: ISRG Root X1) self-signed PEM
# available at: https://letsencrypt.org/certificates/
root_pem=/opt/lego/isrgrootx1.pem

# URL paths
api_cert_path=api/v1/download/certificates/$cert_name
api_key_path=api/v1/download/privatekeys/$cert_name
# temp folder
temp_certs=/tmp/tempcerts
# path to store a timestamp to easily see when script last ran
time_stamp=/opt/lego/timestamp.txt

# vCenter cli apps
vecs_cli="/usr/lib/vmware-vmafd/bin/vecs-cli"

## Script
mkdir $temp_certs

# Fetch LeGo cert
http_statuscode=$(curl https://$server/$api_cert_path -H "apiKey: $cert_apikey" --output $temp_certs/certchain.pem --write-out "%{http_code}")
if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

# Split the certchain (0 = cert, 1 = intermediate cert, 2 = CA cert)
cat $temp_certs/certchain.pem | awk -v tempcerts=$temp_certs 'split_after==1{n++;split_after=0} /-----END CERTIFICATE-----/ {split_after=1} {if(length($0) > 0) print > tempcerts "/certpiece" n ".pem"}'

# Create certificate using cert
cat "$temp_certs/certpiece.pem" > "$temp_certs/cert.pem"

# Load existing cert for comparison
$vecs_cli entry getcert --store MACHINE_SSL_CERT --alias __MACHINE_CERT > /$temp_certs/currentcert.pem

# Compare fetched to current
diff_status=$(diff "$temp_certs/cert.pem" "/$temp_certs/currentcert.pem" -B)
cert_diffcode=$?

if ( test $cert_diffcode != 0 ) ; then

	# Get Key
	http_statuscode=$(curl https://$server/$api_key_path -H "apiKey: $key_apikey" --output $temp_certs/key.pem --write-out "%{http_code}")
	if test $http_statuscode -ne 200; then exit "$http_statuscode"; fi

	# Create signing chain with root
	cat "$temp_certs/certpiece1.pem" "$root_pem" > "$temp_certs/rootchain.pem"

	(
	  printf '1\n%s\n' "$sso_admin"
	  sleep 1
	  printf '%s\n' "$sso_password"
	  sleep 1
	  printf '2\n'
	  sleep 1
	  printf '%s\n%s\n%s\ny\n\n' "$temp_certs/cert.pem" "$temp_certs/key.pem" "$temp_certs/rootchain.pem"
	) | setsid /usr/lib/vmware-vmca/bin/certificate-manager

	# VAMI restart (to update VAMI cert)
	/sbin/service vami-lighttp restart

fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
