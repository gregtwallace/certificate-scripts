#!/bin/bash

# Script runs on a machine, NOT on idracs
# script fetches key/cert pairs for each idrac and then calls
# racadm to install them into their respective idracs

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# idrac 6/7 do NOT support ECDSA keys

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

## Set VARs in accord with environment
# Make a set of all of these values for each idrac
# idrac to install on
idrac_list[0]=idrac1.local
# API keys
cert_apikey[0]=<cert API key>
key_apikey[0]=<key API key>
# idrac login credentials
idrac_user[0]=<user>
idrac_password[0]=<password>

# additional idracs, etc. incremending [i] each time
idrac_list[1]=idrac2.local
cert_apikey[1]=<cert API key>
key_apikey[1]=<key API key>
idrac_user[1]=<user>
idrac_password[1]=<password>

idrac_list[2]=idrac3.local
cert_apikey[2]=<cert API key>
key_apikey[2]=<key API key>
idrac_user[2]=<user>
idrac_password[2]=<password>

# server hosting key/cert
server=certdp.local:port
# URL paths
api_cert_path=legocerthub/api/v1/download/certificates
api_key_path=legocerthub/api/v1/download/privatekeys
# path to `racadm` binary (goracadm is recommended: https://github.com/gregtwallace/goracadm)
racadm_cmd=/opt/goracadm/goracadm-amd64-linux
# racadm strict mode flag ("-S " for strict, "" for insecure)
strict_mode="-S "

# path to store a timestamp to easily see when script last ran
time_stamp=/opt/goracadm/lastrun.txt
# temp owner/folder
cert_owner=root:root
temp_certs=/tmp/goracadm


## Script
# stop / fail on any error
set -e

# Make folders if don't exist
sudo [ -d "$temp_certs" ] || sudo mkdir "$temp_certs"

# Using the ! causes i to equal the index, instead of the value in the array at that index
for i in "${!idrac_list[@]}"; do

	# Purge any old temp certs
	sudo rm -rf ${temp_certs}/*

	# Fetch idrac cert (no way to fetch key, so just replace key anytime cert changes)
	# Uses -S for strict mode!
	sudo $racadm_cmd ${strict_mode}-r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" sslcertdownload -t 1 -f $temp_certs/racadm.cer
	if [[ $? != 0 ]]; then continue; fi

	# Fetch certs end this iteration of the loop if curl doesn't work properly
	# defer key fetch since can't compare it to old key
	http_statuscode=$(sudo curl -L https://$server/$api_cert_path/${idrac_list[$i]} -H "apiKey: ${cert_apikey[$i]}" --output $temp_certs/certchain.pem --write-out "%{http_code}" -G)
	if test $http_statuscode -ne 200; then continue; fi

	## ** Don't Use **
	# This is for tinkering to try and get idrac to serve intermediate cert
	# Split the pem chain to then combine the multiple files into a format drac will take
	#sudo cat $temp_certs/certchain.pem | sudo awk -v path=$temp_certs 'split_after==1{n++;split_after=0} /-----END CERTIFICATE-----/ {split_after=1} {if(length($0) > 0) print > path "/certpiece" n ".pem"}'

	# Convert format because idrac won't just take certchain combined in a pem
	#sudo openssl crl2pkcs7 -nocrl -certfile $temp_certs/certpiece.pem -certfile $temp_certs/certpiece1.pem -certfile $temp_certs/certpiece2.pem -out $temp_certs/certchain.p7b
	#sudo openssl pkcs7 -print_certs -in $temp_certs/certchain.p7b -out $temp_certs/certchain.cer
		
	# CA + Int
	#sudo openssl crl2pkcs7 -nocrl -certfile $temp_certs/certpiece2.pem -certfile $temp_certs/certpiece1.pem -out $temp_certs/cachain.p7b
	#sudo openssl pkcs7 -print_certs -in $temp_certs/cachain.p7b -out $temp_certs/cachain.cer
	## ** End Don't Use **

	# Convert to idrac preferred format
	sudo openssl crl2pkcs7 -nocrl -certfile $temp_certs/certchain.pem -out $temp_certs/certchain.p7b
	sudo openssl pkcs7 -print_certs -in $temp_certs/certchain.p7b -out $temp_certs/certchain.cer

	diff_status=$(sudo diff "$temp_certs/certchain.cer" "$temp_certs/racadm.cer")
	cert_diffcode=$?
	# no way to fetch key, so just replace key anytime cert changes

	# if different
	if ( test $cert_diffcode != 0 ) ; then
		# fetch key, fail out if error
		http_statuscode=$(sudo curl -L https://$server/$api_key_path/${idrac_list[$i]} -H "apiKey: ${key_apikey[$i]}" --output $temp_certs/key.pem --write-out "%{http_code}")
		if test $http_statuscode -ne 200; then continue; fi

		sudo $racadm_cmd ${strict_mode}-r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" sslkeyupload -t 1 -f $temp_certs/key.pem
		sudo $racadm_cmd ${strict_mode}-r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" sslcertupload -t 1 -f $temp_certs/certchain.cer
		sudo $racadm_cmd ${strict_mode}-r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" racreset
	fi
done

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
