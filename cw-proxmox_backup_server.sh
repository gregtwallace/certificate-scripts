#!/bin/sh
# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I placed the script in /root/certwarden and it seems fine.

# Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# apt install cron -y
# crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# NOTE: If Cert Warden server is running on a VM, add sleep 300-600 to wait 5-10 minutes for
# the VM to come up

# Variables (Replace placeholders with your actual values)
cert_apikey="<your_cert_api_key>"
key_apikey="<your_key_api_key>"
server="<your_cert_warden_server>:<port>"
cert_name="<your_certificate_name>"

# Proxmox Backup Server certificate and key paths (adjust as necessary)
pbs_cert="/etc/proxmox-backup/proxy.pem"
pbs_key="/etc/proxmox-backup/proxy.key"
cert_owner="root:backup"
cert_permissions="640"
temp_certs="/tmp/tempcerts"
time_stamp_dir="/root/certwarden"
time_stamp="/root/certwarden/timestamp.txt"

# Stop the script on any error
set -e

# Set umask
umask 077

# Create temp directory for certs
mkdir -p $temp_certs
mkdir -p $time_stamp_dir

# Special API key format required by Cert Warden for combined key & cert with chain download
combined_apikey="$cert_apikey.$key_apikey"

# Fetch certificate and chain from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/certificates/$cert_name" --header="X-API-Key: $cert_apikey" -O "$temp_certs/proxy.pem" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the certificate and chain. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Fetch private key from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/privatekeys/$cert_name" --header="X-API-Key: $key_apikey" -O "$temp_certs/proxy.key" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the private key. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Verify that the files are not empty
if [ ! -s "$temp_certs/proxy.pem" ] || [ ! -s "$temp_certs/proxy.key" ]; then
    echo "Error: One or more downloaded files are empty"
    exit 1
fi

# Compare the new certificate with the existing one
if ! diff -s "$pbs_cert" "$temp_certs/proxy.pem"; then
    # If different, update the Proxmox Backup Server certificate and key
    cp -f "$temp_certs/proxy.pem" "$pbs_cert"
    cp -f "$temp_certs/proxy.key" "$pbs_key"
    
    # Set ownership and permissions as per Proxmox documentation
    chown $cert_owner "$pbs_cert" "$pbs_key"
    chmod $cert_permissions "$pbs_cert" "$pbs_key"

    # Reload the Proxmox Backup Proxy service (without restarting)
    systemctl reload proxmox-backup-proxy
    echo "Certificate and key updated, and Proxmox Backup Proxy service reloaded."
else
    echo "Certificate is already up to date."
fi

# Clean up temporary files
rm -rf $temp_certs

# Log the last run time
echo "Last Run: $(date)" > $time_stamp
