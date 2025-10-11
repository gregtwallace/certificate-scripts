#!/bin/sh
# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I placed the script in /root/certwarden and it seems fine.
# chmod +x /root/certwarden/cw-iobroker.sh

# Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# In ioBroker you must define the certs
# Go to WEB UI system settings => certificates and ad the follwing 2 certs
# name: privateKey => /opt/certs/privateKey.pem
# name: publicCert => /opt/certs/publicCert.pem
# run this script on command line
# change in the WEB UI admin.0 and web.0 encrypted connection (HTTPS) to active
# change public certificate to "publicCert"
# change private certificate to "privateKey"
# save and enjoy Let's encrypt certificate


# NOTE: If Cert Warden server is running on a VM, add sleep 300-600 to wait 5-10 minutes for
# the VM to come up

# Variables (Replace placeholders with your actual values)
cert_apikey="<your_cert_api_key>"
key_apikey="<your_key_api_key>"
server="<your_cert_warden_server>:<port>"
cert_name="<your_certificate_name>"

# ioBroker certificate and key paths
iobroker_cert_dir="/opt/certs"
iobroker_cert="/opt/certs/publicCert.pem"
iobroker_key="/opt/certs/privateKey.pem"
cert_owner="iobroker:iobroker"
cert_permissions="640"
temp_certs="/tmp/tempcerts"
time_stamp_dir="/root/certwarden"
time_stamp="$time_stamp_dir/timestamp.txt"

# Stop the script on any error
set -e

# Set umask
umask 077

# Create temp directory for certs and timestamp directory if they don't exist
mkdir -p $temp_certs
mkdir -p $time_stamp_dir

mkdir -p $iobroker_cert_dir
touch $iobroker_key
touch $iobroker_cert
chown -R $cert_owner $iobroker_cert_dir

# Fetch certificate and chain from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/certificates/$cert_name" --header="X-API-Key: $cert_apikey" -O "$temp_certs/iobroker-ssl.pem" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the certificate and chain. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Fetch private key from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/privatekeys/$cert_name" --header="X-API-Key: $key_apikey" -O "$temp_certs/iobroker-ssl.key" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the private key. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Verify that the files are not empty
if [ ! -s "$temp_certs/iobroker-ssl.pem" ] || [ ! -s "$temp_certs/iobroker-ssl.key" ]; then
    echo "Error: One or more downloaded files are empty"
    exit 1
fi

# Compare the new certificate with the existing one
if ! diff -s "$iobroker_cert" "$temp_certs/iobroker-ssl.pem"; then
    # If different, update the Proxmox VE certificate and key
    cp -f "$temp_certs/iobroker-ssl.pem" "$iobroker_cert"
    cp -f "$temp_certs/iobroker-ssl.key" "$iobroker_key"
    
    # Set ownership and permissions as per Proxmox documentation
    chown $cert_owner "$iobroker_cert" "$iobroker_key"
    chmod $cert_permissions "$iobroker_cert" "$iobroker_key"

    # Reload the admin.0 and web.0 adapter (check your own config. normaly the instance is 0) to apply the new certificate (without restarting)
    iobroker restart admin.0
    iobroker restart web.0
    echo "Certificate and key updated, and iobroker admin and web services reloaded."
else
    echo "Certificate is already up to date."
fi

# Clean up temporary files
rm -rf $temp_certs

# Log the last run time
echo "Last Run: $(date)" > $time_stamp
