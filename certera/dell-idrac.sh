#!/bin/bash

# Script runs on a machine, NOT on idracs
# script fetches key/cert pairs for each idrac and then calls
# racadm to install them into their respective idracs

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /home/greg/certera-idrac.sh
# 28 4 * * 0 /home/greg/certera-idrac.sh

## Set VARs in accord with environment
server=certdp.local

# Make a set of all of these values for each idrac
# idrac to install on
idrac_list[0]=idrac1.local
# API keys
cert_apikey[0]=<cert API key>
key_apikey[0]=<key API key>
# idrac login credentials
idrac_user[0]=<user>
idrac_password[0]=<password>

# example second idrac, etc. incremending [i] each time
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

# path to store a timestamp to easily see when script last ran
time_stamp=/home/greg/certera.txt
# cert owner (temporary)
cert_owner=root:root
# path to `racadm` binary
racadm_cmd="/opt/dell/srvadmin/sbin/racadm"
# local path for temp key/cert storage
temp_certs=/tmp/certera

## Script

# Make folders if don't exist
sudo [ -d "$temp_certs" ] || sudo mkdir "$temp_certs"

# Using the ! causes i to equal the index, instead of the value in the array at that index
for i in "${!idrac_list[@]}"; do

	# Purge any old temp certs
	sudo rm -rf "$temp_certs"'/*'

	# Ping the idrac to see if it is even online
	ping -c1 ${idrac_list[$i]} &>/dev/null
	if [[ $? != 0 ]]; then continue; fi

	# Fetch idrac cert (no way to fetch key, so just replace key anytime cert changes)
	sudo $racadm_cmd -r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" sslcertdownload -t 1 -f $temp_certs/racadm.cer
	if [[ $? != 0 ]]; then continue; fi

	# Fetch certera certs; end this iteration of the loop if curl doesn't work properly
	http_statuscode=$(sudo curl https://$server/api/certificate/${idrac_list[$i]} -H "apiKey: ${cert_apikey[$i]}" --output $temp_certs/certchain.pem --write-out "%{http_code}" -G)
	if test $http_statuscode -ne 200; then continue; fi
	http_statuscode=$(sudo curl https://$server/api/key/${idrac_list[$i]} -H "apiKey: ${key_apikey[$i]}" --output $temp_certs/key.pem --write-out "%{http_code}")
	if test $http_statuscode -ne 200; then continue; fi

	# Split the pem chain to then combine the multiple files into a format drac will take
	#sudo cat $temp_certs/certchain.pem | sudo awk -v tempcerts=$temp_certs 'split_after==1{n++;split_after=0} /-----END CERTIFICATE-----/ {split_after=1} {if(length($0) > 0) print > tempcerts "/certpiece" n ".pem"}'

	# Convert format because idrac won't just take certchain combined in a pem
	#sudo openssl crl2pkcs7 -nocrl -certfile $temp_certs/certpiece.pem -certfile $temp_certs/certpiece1.pem -certfile $temp_certs/certpiece2.pem -out $temp_certs/certchain.p7b
	sudo openssl crl2pkcs7 -nocrl -certfile $temp_certs/certchain.pem -out $temp_certs/certchain.p7b
	sudo openssl pkcs7 -print_certs -in $temp_certs/certchain.p7b -out $temp_certs/certchain.cer

	diff_status=$(sudo diff "$temp_certs/certchain.cer" "$temp_certs/racadm.cer")
	cert_diffcode=$?
	# no way to fetch key, so just replace key anytime cert changes
	#diff_status=$(sudo diff "$temp_certs/rui.key" "$esxi_certs/rui.key")
	#key_diffcode=$?

	# if different
	if ( test $cert_diffcode != 0 ) ; then

		sudo $racadm_cmd -r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" sslkeyupload -t 1 -f $temp_certs/key.pem
		sudo $racadm_cmd -r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" sslcertupload -t 1 -f $temp_certs/certchain.cer
		sudo $racadm_cmd -r "${idrac_list["$i"]}" -u "${idrac_user["$i"]}" -p "${idrac_password["$i"]}" racreset

	fi
done

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
