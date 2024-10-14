#!/bin/bash

# This script updates Nginx certificates and keys by downloading them from Cert Warden.
# It supports multiple websites, each with its own API keys.
# It reloads the Nginx service to apply any new certificates.
# Place this script securely with limited access (e.g., owned by root with permissions of 700)
# to avoid compromising the API keys.

# Recommended cron jobs:
# @reboot sleep 15 && /path/to/this/script
# 5 4 * * 2 /path/to/this/script

# NOTE: If the Cert Warden server is running on a VM, add `sleep 300-600` to wait 5-10 minutes for
# the VM to become available.

## Variables (Replace placeholders with your actual values)
server="<your_cert_warden_server>:<port>"

# List of certificates with their own API keys and corresponding Nginx configurations
# Each entry is in the format:
# cert_name:cert_apikey:key_apikey:nginx_cert_path:nginx_key_path
certs=(
  "example.com:cert_api_key_1:key_api_key_1:/etc/nginx/ssl/example.com.crt:/etc/nginx/ssl/example.com.key"
  "example.org:cert_api_key_2:key_api_key_2:/etc/nginx/ssl/example.org.crt:/etc/nginx/ssl/example.org.key"
  # Add more entries as needed
)

cert_owner="root"
cert_group="www-data"
key_permissions="640"
cert_permissions="644"

# Temporary directory for certs
temp_certs=$(mktemp -d)
time_stamp_dir="/root/certwarden"
time_stamp="$time_stamp_dir/timestamp.txt"

# Exit on any error, treat unset variables as errors, and propagate errors in pipelines
set -euo pipefail

# Enable debugging (optional, uncomment for detailed logs)
# set -x

# Ensure the temporary directory is cleaned up on exit
trap 'rm -rf "$temp_certs"' EXIT

# Create timestamp directory if it doesn't exist
mkdir -p "$time_stamp_dir"

# Initialize a flag to track if any certificates were updated
certs_updated=0

# Iterate over each certificate configuration
for entry in "${certs[@]}"; do
    IFS=":" read -r cert_name cert_apikey key_apikey nginx_cert nginx_key <<< "$entry"
    echo "Processing certificate: $cert_name"

    # Ensure the directories for certificate and key exist
    cert_dir=$(dirname "$nginx_cert")
    key_dir=$(dirname "$nginx_key")

    echo "Ensuring certificate directory exists: $cert_dir"
    if mkdir -p "$cert_dir"; then
        echo "Successfully ensured certificate directory: $cert_dir"
    else
        echo "Error: Failed to create certificate directory: $cert_dir"
        exit 1
    fi

    echo "Ensuring key directory exists: $key_dir"
    if mkdir -p "$key_dir"; then
        echo "Successfully ensured key directory: $key_dir"
    else
        echo "Error: Failed to create key directory: $key_dir"
        exit 1
    fi

    # Fetch certificate and chain from Cert Warden
    echo "Downloading certificate for $cert_name..."
    if curl -fL -o "$temp_certs/$cert_name.crt" -H "X-API-Key: $cert_apikey" "https://$server/certwarden/api/v1/download/certificates/$cert_name"; then
        echo "Successfully downloaded certificate for $cert_name."
    else
        echo "Error: Failed to download certificate for $cert_name."
        exit 1
    fi

    # Fetch private key from Cert Warden
    echo "Downloading private key for $cert_name..."
    if curl -fL -o "$temp_certs/$cert_name.key" -H "X-API-Key: $key_apikey" "https://$server/certwarden/api/v1/download/privatekeys/$cert_name"; then
        echo "Successfully downloaded private key for $cert_name."
    else
        echo "Error: Failed to download private key for $cert_name."
        exit 1
    fi

    # Verify that the files are not empty
    if [ ! -s "$temp_certs/$cert_name.crt" ] || [ ! -s "$temp_certs/$cert_name.key" ]; then
        echo "Error: One or more downloaded files for $cert_name are empty."
        exit 1
    fi

    # Validate that the certificate and key match
    echo "Validating that certificate and key match for $cert_name..."
    cert_pubkey_fingerprint=$(openssl x509 -in "$temp_certs/$cert_name.crt" -noout -pubkey \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256)

    key_pubkey_fingerprint=$(openssl pkey -in "$temp_certs/$cert_name.key" -pubout -outform DER 2>/dev/null \
        | openssl dgst -sha256)

    if [ "$cert_pubkey_fingerprint" != "$key_pubkey_fingerprint" ]; then
        echo "ERROR: Certificate and key for $cert_name do not match!"
        exit 1
    fi
    echo "Certificate and key match for $cert_name."

    # Compare the new certificate with the existing one
    if [ -f "$nginx_cert" ]; then
        echo "Comparing new certificate with existing certificate for $cert_name..."
        if ! cmp -s "$nginx_cert" "$temp_certs/$cert_name.crt"; then
            cert_changed=true
            echo "Certificate for $cert_name has changed."
        else
            cert_changed=false
            echo "Certificate for $cert_name is already up to date."
        fi
    else
        echo "Existing certificate for $cert_name not found. It will be created."
        cert_changed=true
    fi

    if [ "$cert_changed" = true ]; then
        # If different, update the Nginx certificate and key
        echo "Updating certificate and key for $cert_name..."
        if cp -f "$temp_certs/$cert_name.crt" "$nginx_cert" && cp -f "$temp_certs/$cert_name.key" "$nginx_key"; then
            echo "Successfully copied certificate and key for $cert_name to $nginx_cert and $nginx_key."
        else
            echo "Error: Failed to copy certificate and/or key for $cert_name."
            exit 1
        fi

        # Set ownership and permissions
        echo "Setting ownership and permissions for $nginx_cert and $nginx_key..."
        if chown "$cert_owner":"$cert_group" "$nginx_cert" "$nginx_key" && \
           chmod "$cert_permissions" "$nginx_cert" && \
           chmod "$key_permissions" "$nginx_key"; then
            echo "Successfully set ownership and permissions for $cert_name."
        else
            echo "Error: Failed to set ownership and/or permissions for $cert_name."
            exit 1
        fi

        echo "Certificate and key for $cert_name updated."
        certs_updated=1
    fi
done

if [ "$certs_updated" -eq 1 ]; then
    echo "Testing Nginx configuration..."
    if nginx -t; then
        echo "Nginx configuration test passed."
    else
        echo "ERROR: Nginx configuration test failed."
        exit 1
    fi

    echo "Reloading Nginx service..."
    if systemctl reload nginx; then
        echo "Nginx service reloaded successfully."
    else
        echo "ERROR: Failed to reload Nginx service."
        exit 1
    fi
else
    echo "No certificates were updated. Nginx reload not required."
fi

# Log the last run time
echo "Last Run: $(date)" > "$time_stamp"
echo "Script execution completed."
