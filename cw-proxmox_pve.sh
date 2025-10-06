#!/bin/sh
# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I placed the script in /root/certwarden and it seems fine.

# Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# NOTE: If Cert Warden server is running on a VM, add sleep 300-600 to wait 5-10 minutes for
# the VM to come up

# Variables (Replace placeholders with your actual values)
cert_apikey="<your_cert_api_key>"
key_apikey="<your_key_api_key>"
server="<your_cert_warden_server>:<port>"
cert_name="<your_certificate_name>"
pve_node_name=$(hostname)  # Get the node name dynamically

# Proxmox VE certificate and key paths
pve_cert="/etc/pve/nodes/$pve_node_name/pveproxy-ssl.pem"
pve_key="/etc/pve/nodes/$pve_node_name/pveproxy-ssl.key"
cert_owner="root:www-data"
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

# Fetch certificate and chain from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/certificates/$cert_name" --header="X-API-Key: $cert_apikey" -O "$temp_certs/pve-ssl.pem" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the certificate and chain. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Fetch private key from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/privatekeys/$cert_name" --header="X-API-Key: $key_apikey" -O "$temp_certs/pve-ssl.key" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the private key. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Verify that the files are not empty
if [ ! -s "$temp_certs/pve-ssl.pem" ] || [ ! -s "$temp_certs/pve-ssl.key" ]; then
    echo "Error: One or more downloaded files are empty"
    exit 1
fi

# Compare the new certificate with the existing one
if ! diff -s "$pve_cert" "$temp_certs/pve-ssl.pem"; then
    # If different, update the Proxmox VE certificate and key
    cp -f "$temp_certs/pve-ssl.pem" "$pve_cert"
    cp -f "$temp_certs/pve-ssl.key" "$pve_key"
    
    # Set ownership and permissions as per Proxmox documentation
    chown $cert_owner "$pve_cert" "$pve_key"
    chmod $cert_permissions "$pve_cert" "$pve_key"

    # Reload the pveproxy service to apply the new certificate (without restarting)
    systemctl reload pveproxy
    echo "Certificate and key updated, and pveproxy service reloaded."
else
    echo "Certificate is already up to date."
fi

# Clean up temporary files
rm -rf $temp_certs

# Log the last run time
echo "Last Run: $(date)" > $time_stamp
