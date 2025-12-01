#!/bin/sh
# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I placed the script in /root/certwarden and it seems fine.
# chmod +x /root/certwarden/cw-gitlab.sh

# Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# Setup gitlab for ssl (the following is an example. Read the manual  of gitlab for details)
# Edit the /etc/gitlab/gitlab.rb file to set the ssl_certificate and ssl_certificate_key
# paths to the certificate and key files managed by this script.  Usually just uncommenting
# the following two lines is sufficient.
#nginx['ssl_certificate'] = "/etc/gitlab/ssl/#{node['fqdn']}.crt"
#nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/#{node['fqdn']}.key"

# NOTE: If Cert Warden server is running on a VM, add sleep 300-600 to wait 5-10 minutes for
# the VM to come up

# Variables (Replace placeholders with your actual values)
cert_apikey="<your_cert_api_key>"
key_apikey="<your_key_api_key>"
server="<your_cert_warden_server>:<port>"
cert_name="<your_certificate_name>"
fqdn="<Gitlab_FQDN>"

# gitlab certificate and key paths
gitlab_cert_root="/etc/gitlab/ssl/"
gitlab_cert_dir="/etc/gitlab/ssl/"
gitlab_cert="/etc/gitlab/ssl/$fqdn.crt"
gitlab_key="/etc/gitlab/ssl/$fqdn.key"
cert_owner="gitlab:gitlab" # Use the appropriate user and group for GitLab
cert_permissions="640"
temp_certs="/tmp/tempcerts"
time_stamp_dir="/root/certwarden"  # Update to your desired directory
time_stamp="$time_stamp_dir/timestamp.txt"

# Stop the script on any error
set -e

# Set umask
umask 077

# Create temp directory for certs and timestamp directory if they don't exist
mkdir -p $temp_certs
mkdir -p $time_stamp_dir

mkdir -p $gitlab_cert_dir
touch $gitlab_key
touch $gitlab_cert
chown -R $cert_owner $gitlab_cert_root

# Fetch certificate and chain from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/certificates/$cert_name" --header="X-API-Key: $cert_apikey" -O "$temp_certs/gitlab-ssl.pem" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the certificate and chain. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Fetch private key from Cert Warden
http_statuscode=$(wget "https://$server/certwarden/api/v1/download/privatekeys/$cert_name" --header="X-API-Key: $key_apikey" -O "$temp_certs/gitlab-ssl.key" --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if [ "$http_statuscode" -ne 200 ]; then
    echo "Error: Failed to fetch the private key. HTTP Status Code: $http_statuscode"
    exit 1
fi

# Verify that the files are not empty
if [ ! -s "$temp_certs/gitlab-ssl.pem" ] || [ ! -s "$temp_certs/gitlab-ssl.key" ]; then
    echo "Error: One or more downloaded files are empty"
    exit 1
fi

# Compare the new certificate with the existing one
if ! diff -s "$gitlab_cert" "$temp_certs/gitlab-ssl.pem"; then
    # If different, update the GitLab certificate and key
    cp -f "$temp_certs/gitlab-ssl.pem" "$gitlab_cert"
    cp -f "$temp_certs/gitlab-ssl.key" "$gitlab_key"
    
    # Set ownership and permissions as per GitLab documentation
    chown $cert_owner "$gitlab_cert" "$gitlab_key"
    chmod $cert_permissions "$gitlab_cert" "$gitlab_key"

    # Reload gitlab to apply the new certificate
    gitlab-ctl hup nginx
    gitlab-ctl hup registry

    echo "Certificate and key updated, and gitlab services restarted."
else
    echo "Certificate is already up to date."
fi

# Clean up temporary files
rm -rf $temp_certs

# Log the last run time
echo "Last Run: $(date)" > $time_stamp