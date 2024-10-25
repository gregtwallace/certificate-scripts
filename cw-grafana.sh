#!/bin/sh
# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I placed the script in /root/certwarden and it seems fine.
# chmod +x /root/certwarden/cw-grafana.sh

# Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# Setup grafana for ssl (the following is an example. Read the manual  of Grafana
# vi /etc/grafana/grafana.ini
# Section [server]
# add:
# root_url = https://grafana.fqdn
# cert_key = /etc/grafana/grafana.key
# cert_file = /etc/grafana/grafana.crt
# protocol = https
# run this script on command line
# enjoy Let's encrypt certificate

# NOTE: If Cert Warden server is running on a VM, add sleep 300-600 to wait 5-10 minutes for
# the VM to come up

# Variables (Replace placeholders with your actual values)
cert_apikey="<your_cert_api_key>"
key_apikey="<your_key_api_key>"
server="<your_cert_warden_server>:<port>"
cert_name="<your_certificate_name>"

# grafana certificate and key paths
grafana_cert_dir="/etc/grafana/"
grafana_cert="/etc/grafana/grafana.crt"
grafana_key="/etc/grafana/grafana.key"
cert_owner="root:grafana"
cert_permissions="640"
temp_certs="/tmp/tempcerts"
time_stamp_dir="/root/certwarden"
time_stamp="$time_stamp_dir/timestamp.txt"

# Stop the script on any error
set -e

# Create temp directory for certs and timestamp directory if they don't exist
mkdir -p $temp_certs
mkdir -p $time_stamp_dir

mkdir -p $grafana_cert_dir
touch $grafana_key
touch $grafana_cert

# Fetch certificate and chain from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/certificates/$cert_name" --header="X-API-Key: $cert_apikey" -O "$temp_certs/grafana-ssl.pem" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the certificate and chain. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Fetch private key from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/privatekeys/$cert_name" --header="X-API-Key: $key_apikey" -O "$temp_certs/grafana-ssl.key" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the private key. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Verify that the files are not empty
if [ ! -s "$temp_certs/grafana-ssl.pem" ] || [ ! -s "$temp_certs/grafana-ssl.key" ]; then
    echo "Error: One or more downloaded files are empty"
    exit 1
fi

# Compare the new certificate with the existing one
if ! diff -s "$grafana_cert" "$temp_certs/grafana-ssl.pem"; then
    # If different, update the Grafana certificate and key
    cp -f "$temp_certs/grafana-ssl.pem" "$grafana_cert"
    cp -f "$temp_certs/grafana-ssl.key" "$grafana_key"
    
    # Set ownership and permissions as per Grafana documentation
    chown $cert_owner "$grafana_cert" "$grafana_key"
    chmod $cert_permissions "$grafana_cert" "$grafana_key"

    # Reload grafana to apply the new certificate
    systemctl restart grafana-server.service
    echo "Certificate and key updated, and grafana services restartet."
else
    echo "Certificate is already up to date."
fi

# Clean up temporary files
rm -rf $temp_certs

# Log the last run time
echo "Last Run: $(date)" > $time_stamp
