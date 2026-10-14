#!/bin/bash

# --- CONFIGURATION ---
CERT_NAME="mycockpit-server"                     # The Name field of the certificate in Cert Warden
BASE_URL="https://certwarden.example.com/certwarden/api/v1" 
CERT_API_KEY="<certificate_api_key"  # Cockpit will be looking for 2 files so this is using both instead of a combined
KEY_API_KEY="<private_key_api_key"
TARGET_DIR="/etc/cockpit/ws-certs.d"

# Ensure the target folder exists
mkdir -p "$TARGET_DIR"

# 1a. Download the certificate
echo "Fetching certificate from Cert Warden..."
curl -s -f -H "X-API-Key: ${CERT_API_KEY}" \
     "${BASE_URL}/download/certificates/${CERT_NAME}" > "/tmp/$CERT_NAME.cert"
echo "Download complete"

# 1b. Download the key
echo "Fetching private key from Cert Warden..."
curl -s -f -H "X-API-Key: ${KEY_API_KEY}" \
	"${BASE_URL}/download/privatekeys/${CERT_NAME}" > "/tmp/$CERT_NAME.key"
#      echo "Download complete"

# 2a. Verify the download succeeded and is not an empty file
if [ ! -s "/tmp/$CERT_NAME.cert" ]; then
    echo "Error: Failed to fetch certificate from Cert Warden or file is empty."
        rm -f "/tmp/$CERT_NAME.cert"
    exit 1
fi

# 2b. Verify the download succeeded and is not an empty file
 if [ ! -s "/tmp/$CERT_NAME.key" ]; then
    echo "Error: Failed to fetch private key from Cert Warden or file is empty."
        rm -f "/tmp/$CERT_NAME.key"
    exit 1
             fi

# 3a. Securely copy to Cockpit's directory with the correct permissions and cleanup the temp files
echo "Deploying to Cockpit..."
cp "/tmp/$CERT_NAME.cert" "$TARGET_DIR/$CERT_NAME.cert"
chmod 600  "$TARGET_DIR/$CERT_NAME.cert"
chown root:root  "$TARGET_DIR/$CERT_NAME.cert"
rm -f "/tmp/$CERT_NAME.cert"

#3b. Securely copy to Cockpit's directory with the correct permissions and cleanup the temp files
echo "Deploying to Cockpit..."
cp "/tmp/$CERT_NAME.key" "$TARGET_DIR/$CERT_NAME.key"
chmod 600 "$TARGET_DIR/$CERT_NAME.key"
chown root:root "$TARGET_DIR/$CERT_NAME.key"
rm -f "/tmp/$CERT_NAME.key"

# 4. Force Cockpit to reload and capture the new certificate
echo "Reloading Cockpit service..."
systemctl restart cockpit

