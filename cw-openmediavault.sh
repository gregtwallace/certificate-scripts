#!/bin/bash
set -e

. /usr/share/openmediavault/scripts/helper-functions

##############################################################################
# Config
##############################################################################

certwardenUrl="https://<<your certwarden address>>/certwarden"
certName="<<cert_name>>"
certApiKey="<<cert_api_key>>"

keyName="<<key_name>>"
keyApiKey="<<key_api_key>>"


comment="<< a static comment>>"
dummyCn="<<maybe your IP>>"

##############################################################################
# Script
##############################################################################

tmpDir="$(mktemp -d)"
trap 'rm -rf "$tmpDir"' EXIT

certificateFile="$tmpDir/fullchain.pem"
privateKeyFile="$tmpDir/privkey.pem"

get_cert_uuid() {
  omv-confdbadm read conf.system.certificate.ssl \
    | grep -B3 -A3 "\"comment\": \"$comment\"" \
    | grep '"uuid"' \
    | head -n1 \
    | cut -d'"' -f4
}

create_dummy_cert() {
  omv-rpc "CertificateMgmt" "create" \
    "{\"cn\":\"$dummyCn\",\"size\":2048,\"days\":365,\"c\":\"DE\",\"st\":\"Niedersachsen\",\"l\":\"Oldenburg\",\"o\":\"Home\",\"ou\":\"IT\",\"email\":\"admin@example.local\",\"comment\":\"$comment\"}" \
    | grep -o '"uuid":"[^"]*"' \
    | cut -d'"' -f4
}

json_escape_file() {
  sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g' "$1"
}

curl -fsSL \
  -H "X-API-Key: $certApiKey" \
  "$certwardenUrl/api/v1/download/certificates/$certName" \
  -o "$certificateFile"

curl -fsSL \
  -H "X-API-Key: $keyApiKey" \
  "$certwardenUrl/api/v1/download/privatekeys/$keyName" \
  -o "$privateKeyFile"

openssl x509 -in "$certificateFile" -noout >/dev/null
openssl pkey -in "$privateKeyFile" -noout >/dev/null

certUuid="$(get_cert_uuid || true)"

if [ -z "$certUuid" ]; then
  echo "No certificate with comment '$comment' found! - create dummy"
  certUuid="$(create_dummy_cert)"
fi

if [ -z "$certUuid" ]; then
  echo "Could not get UUID!"
  exit 1
fi

newFingerprint="$(openssl x509 -in "$certificateFile" -noout -fingerprint -sha256 | cut -d= -f2)"

omvCertificateFile="/etc/ssl/certs/openmediavault-${certUuid}.crt"

if [ -f "$omvCertificateFile" ]; then
  currentFingerprint="$(openssl x509 -in "$omvCertificateFile" -noout -fingerprint -sha256 | cut -d= -f2)"
else
  currentFingerprint=""
fi

if [ "$newFingerprint" = "$currentFingerprint" ]; then
  echo "No change - exit."
  exit 0
fi

certkey="$(json_escape_file "$certificateFile")"
privkey="$(json_escape_file "$privateKeyFile")"

rpcparams="{\"uuid\":\"$certUuid\",\"certificate\":\"$certkey\",\"privatekey\":\"$privkey\",\"comment\":\"$comment\"}"

omv-rpc "CertificateMgmt" "set" "$rpcparams" >/dev/null

settings="$(omv-rpc "WebGui" "getSettings")"

settings="$(echo "$settings" \
  | sed "s/\"sslcertificateref\":\"[^\"]*\"/\"sslcertificateref\":\"$certUuid\"/" \
  | sed 's/"enablessl":false/"enablessl":true/' \
  | sed 's/"enablessl":0/"enablessl":true/')"

omv-rpc "WebGui" "setSettings" "$settings" >/dev/null

omv_exec_rpc "Config" "applyChanges" "{\"modules\":[\"certificatemgmt\"],\"force\":false}" >/dev/null
omv_exec_rpc "Config" "applyChanges" "{\"modules\":[],\"force\":false}" >/dev/null

systemctl reload nginx

echo "Certificates successfully updated. UUID: $certUuid"
