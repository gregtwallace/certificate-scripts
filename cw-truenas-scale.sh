#!/bin/sh

# Script contributed by DevZwF (https://github.com/devzwf)
# Tested on TrueNAS SCALE 25.10 (Community Edition).

# Fetches a certificate and key from Cert Warden and installs them on
# TrueNAS SCALE: the certificate is imported into TrueNAS, set as the web UI
# certificate, and apps that used the previous certificate (e.g. MinIO,
# whose app settings have a certificate field) are switched to the new one.
# Older imports made by this script are then deleted and the UI restarted.
# Nothing happens if the UI already uses the current certificate.

# It talks to the local TrueNAS middleware (truenas_api_client, shipped with
# TrueNAS), so no TrueNAS API key is needed and the private key is never
# passed on a command line. It must run as root on the TrueNAS host.

# This script should be securely placed with limited access to avoid
# compromising the API Keys. Do not put it in /root or /etc: TrueNAS
# upgrades replace the OS. Put it on a dataset instead, e.g.:
#   create dataset <pool>/certwarden, then
#   chmod 700 /mnt/<pool>/certwarden
#   chmod 700 /mnt/<pool>/certwarden/cw-truenas-scale.sh

# Run it from a TrueNAS Cron Job (System > Advanced Settings > Cron Jobs):
#   Command: sh /mnt/<pool>/certwarden/cw-truenas-scale.sh
#   Run As User: root
#   Schedule: daily, at a time of your choice
# Tick "Hide Standard Output" and leave "Hide Standard Error" unticked to get
# an email from TrueNAS only when something fails.

set -e
umask 077

##############################################################################
# Config
##############################################################################

server="<your_cert_warden_server>:<port>"
cert_name="<your_certificate_name>"
cert_apikey="<your_cert_api_key>"
key_name="<your_key_name>"
key_apikey="<your_key_api_key>"

# Name prefix of the certificates this script imports into TrueNAS. Only
# imports with this prefix are ever deleted by the script.
truenas_cert_prefix="certwarden"

# Switch apps that used the previous UI certificate to the new one
# (true/false). Those apps are redeployed, so they restart.
update_apps="true"

##############################################################################
# Script
##############################################################################

temp_certs="$(mktemp -d)"
trap 'rm -rf "$temp_certs"' EXIT

cert_file="$temp_certs/fullchain.pem"
key_file="$temp_certs/privkey.pem"

# API keys are passed in a header file so they do not show up in ps
printf 'X-API-Key: %s\n' "$cert_apikey" > "$temp_certs/cert_header"
printf 'X-API-Key: %s\n' "$key_apikey" > "$temp_certs/key_header"

curl -fsS --max-time 30 -H @"$temp_certs/cert_header" \
  "https://$server/certwarden/api/v1/download/certificates/$cert_name" -o "$cert_file"
curl -fsS --max-time 30 -H @"$temp_certs/key_header" \
  "https://$server/certwarden/api/v1/download/privatekeys/$key_name" -o "$key_file"

# Sanity checks: valid PEM, key matches certificate, not expired
openssl x509 -in "$cert_file" -noout
openssl pkey -in "$key_file" -noout
cert_pub="$(openssl x509 -in "$cert_file" -noout -pubkey | openssl pkey -pubin -outform DER | cksum)"
key_pub="$(openssl pkey -in "$key_file" -pubout -outform DER | cksum)"
if [ "$cert_pub" != "$key_pub" ]; then
  echo "Error: the private key does not match the certificate"
  exit 1
fi
if ! openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null; then
  echo "Error: the downloaded certificate is expired"
  exit 1
fi

python3 -I - "$cert_file" "$key_file" "$truenas_cert_prefix" "$update_apps" <<'EOF'
import subprocess
import sys

from truenas_api_client import Client

cert_file, key_file, prefix, update_apps = sys.argv[1:5]
cert = open(cert_file).read()
key = open(key_file).read()


def first_cert(pem):
    """First certificate block of a PEM chain, whitespace removed."""
    begin = pem.find("-----BEGIN CERTIFICATE-----")
    end = pem.find("-----END CERTIFICATE-----", begin)
    return "".join(pem[begin:end].split()) if begin >= 0 and end > begin else ""


# Name the import after the certificate's expiry, e.g. certwarden-202701201842
not_after = subprocess.run(
    ["openssl", "x509", "-noout", "-enddate", "-dateopt", "iso_8601", "-in", cert_file],
    check=True, capture_output=True, text=True).stdout.strip().split("=", 1)[1]
name = prefix + "-" + not_after[:16].replace("-", "").replace(" ", "").replace(":", "")

with Client() as c:
    ui = c.call("system.general.config")["ui_certificate"]
    if ui and first_cert(ui["certificate"]) == first_cert(cert):
        print(f"Certificate is already up to date ({ui['name']}).")
        sys.exit(0)
    prev_ui = ui["id"] if ui else None

    found = c.call("certificate.query", [["name", "=", name]])
    if found:
        cid = found[0]["id"]
    else:
        c.call("certificate.create", {
            "name": name,
            "create_type": "CERTIFICATE_CREATE_IMPORTED",
            "certificate": cert,
            "privatekey": key,
            "add_to_trusted_store": False,
        }, job=True)
        cid = c.call("certificate.query", [["name", "=", name]], {"get": True})["id"]
        print(f"Imported {name} (id {cid}).")

    c.call("system.general.update", {"ui_certificate": cid})
    print(f"UI certificate set to {name}.")

    if update_apps == "true":
        old_ids = {prev_ui} | {x["id"] for x in c.call("certificate.query", [["name", "^", prefix + "-"]])}
        old_ids.discard(cid)
        for app in c.call("app.query"):
            # app.config also returns certificates with their private keys: never print it
            network = c.call("app.config", app["name"]).get("network")
            if not isinstance(network, dict) or network.get("certificate_id") not in old_ids:
                continue
            # app.update only merges top-level keys: send the whole network section back,
            # otherwise the app's ports would be reset to their defaults
            network["certificate_id"] = cid
            c.call("app.update", app["name"], {"values": {"network": network}}, job=True)
            print(f"App {app['name']} switched to {name}.")

    for old in c.call("certificate.query", [["name", "^", prefix + "-"], ["id", "!=", cid]]):
        try:
            c.call("certificate.delete", old["id"], job=True)
            print(f"Deleted old import {old['name']}.")
        except Exception as e:
            print(f"Warning: could not delete {old['name']}: {e}")

    c.call("system.general.ui_restart")
    print("Web UI restarted.")
EOF
