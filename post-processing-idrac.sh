#!/bin/bash

# Script to place on the LeGo server (e.g. ./data/scripts/this_script.sh) to then use as a post
# processing script to install certificate onto a Dell iDRAC

# Note: Only RSA keys seem to be supported on iDRAC.

# Required additional binary:
# goracadm-amd64-linux -- see: https://github.com/gregtwallace/goracadm

# Required additional environment variables (in LeGo post processing setup):
# IDRAC_HOST - hostname or IP of the idrac (strongly prefer hostname for security)
# IDRAC_USER - username to login to the idrac
# IDRAC_PASSWORD - password for the above username to login to the idrac

# Note: Strict HTTPS verification is enabled below. Ensure the IDRAC already has a valid cert
# and the hostname matches (aka manually load the key and cert the first time you install a 
# valid one on the iDRAC). OR disable strict below (not recommended).

#######

# stop / fail on any error
set -e

# CD working dir to script location
cd "${0%/*}"

# go racadm binary (https://github.com/gregtwallace/goracadm)
racadm_cmd=./goracadm-amd64-linux
# racadm strict mode flag ("-S " for strict, "" for insecure)
strict_mode="-S "

# temp owner/folder
cert_owner=legocerthub:legocerthub
temp_certs=/tmp/goracadm_post_temp

## Script
# Make folder if no exist
[ -d "$temp_certs" ] || mkdir "$temp_certs"
chmod 700 "$temp_certs"

# no need to compare anything -- if this file runs it is due to a new certificate

# make files for new key cert (racadm requires file)
printenv LEGO_PRIVATE_KEY_PEM > $temp_certs/$(printenv IDRAC_HOST).key.pem
printenv LEGO_CERTIFICATE_PEM > $temp_certs/$(printenv IDRAC_HOST).certchain.pem

# Install new key and cert and reset
$racadm_cmd ${strict_mode}-r "$(printenv IDRAC_HOST)" -u "$(printenv IDRAC_USER)" -p "$(printenv IDRAC_PASSWORD)" sslkeyupload -t 1 -f $temp_certs/$(printenv IDRAC_HOST).key.pem
$racadm_cmd ${strict_mode}-r "$(printenv IDRAC_HOST)" -u "$(printenv IDRAC_USER)" -p "$(printenv IDRAC_PASSWORD)" sslcertupload -t 1 -f $temp_certs/$(printenv IDRAC_HOST).certchain.pem
$racadm_cmd ${strict_mode}-r "$(printenv IDRAC_HOST)" -u "$(printenv IDRAC_USER)" -p "$(printenv IDRAC_PASSWORD)" racreset

# remove files
rm -f $temp_certs/$(printenv IDRAC_HOST).key.pem
rm -f $temp_certs/$(printenv IDRAC_HOST).certchain.pem
