#!/bin/bash

# INSECURE! - This script should be considered for lab/testing only as tftp is inherently insecure.
# Additionally, there is no user authentication for tftp so anyone could download the key/cert while
# it is being served.
# TL;DR - Transmitting keys through this script risks them being compromised. Use at your own risk!!!

# Script for updating key/cert on edge switches

# Required: expect, python3, and tftpd-hpa must be installed to run this script.

# To get the edge switch to properly send the full cert chain, the files uploaded should be (in order of appearance in concatenated file)
##	SSL Trusted Root Certificate PEM File = Intermediate CA Cert, CA Root Cert
##	SSL Server Certificate PEM File = Server Key, Server Cert

# Due to limits of the console on edge switch, a server is needed to run the script (i.e. this script doesn't run on the switch)

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

# NOTE: IMPORTANT!!  curl commands below use -k flag (don't check ssl cert) because I run this script on localhost
# (the cert server itself). Remove -k flag if you are NOT using localhost.

## Set VARs in accord with environment
# server with the key/cert api running
certserver=localhost

# tftp server url (should be machine running the script)
tftp_server=certdp.local
# local path for the tftp server's root
tftp_root=/srv/tftp

# Make a set of all of these values for each switch
# to install on
edgesw_list[0]=sw1.local
cert_apikey[0]=<cert API key>
key_apikey[0]=<key API key>
edgesw_user[0]=<user>
edgesw_password[0]=<password>

# example second switch, etc. incremending [i] each time
idrac_list[1]=sw2.local
cert_apikey[1]=<cert API key>
key_apikey[1]=<key API key>
edgesw_user[1]=<user>
edgesw_password[1]=<password>

# path to store a timestamp to easily see when script last ran
time_stamp=/home/greg/certera-edgesw.txt
# local path for temp key/cert storage
temp_certs=/tmp/certera


## Script
# Check if expect is installed
if ! command -v /usr/bin/expect &> /dev/null; then echo "This script requires expect but it's not installed.";exit 1;fi

# Check if python 3 is installed (needed for web server)
if ! command -v /usr/bin/python3 &> /dev/null; then echo "This script requires python3 but it's not installed.";exit 1;fi

# Check if tftp server is installed
if ! command -v /usr/sbin/in.tftpd &> /dev/null; then echo "This script requires tftpd-hpa but it's not installed.";exit 1;fi


# Make folders if don't exist
sudo [ -d "$temp_certs" ] || sudo mkdir "$temp_certs"
sudo [ -d "$tftp_root" ] || sudo mkdir "$tftp_root"

# Using the ! causes i to equal the index, instead of the value in the array at that index
for i in "${!edgesw_list[@]}"; do

	# Purge any old temp certs
	sudo rm -rf "$temp_certs"'/*'

	# Ping the edgesw to see if it is even online
	ping -c1 ${edgesw_list[$i]} &>/dev/null
	if [[ $? != 0 ]]; then continue; fi

	# Fetch certera certs; end this iteration of the loop if curl doesn't work properly
	http_statuscode=$(sudo curl -k https://$certserver/api/certificate/${edgesw_list[$i]} -H "apiKey: ${cert_apikey[$i]}" --out $temp_certs/certchain.pem --write-out "%{http_code}" -G)
	if test $http_statuscode -ne 200; then continue; fi
	http_statuscode=$(sudo curl -k https://$certserver/api/key/${edgesw_list[$i]} -H "apiKey: ${key_apikey[$i]}" --out $temp_certs/key.pem --write-out "%{http_code}")
	if test $http_statuscode -ne 200; then continue; fi

	# Fetch cert chain from the switch by connecting with SSL (don't fail out if cert isn't collected, instead assume SSL isn't configured yet and continue)
	echo | openssl s_client -connect "${edgesw_list["$i"]}":443 -showcerts 2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > $temp_certs/edgeswchain.pem

	# Check cert dp chain against switch chain
	diff_status=$(sudo diff "$temp_certs/certchain.pem" "$temp_certs/edgeswchain.pem")
	cert_diffcode=$?

	# if different
	if ( test $cert_diffcode != 0 ) ; then

		## Convert the certs and key into the files needed for the switch upload
		# Split the certchain ( = cert, 1 = intermediate cert, 2 = More intermediate(??) 3 = CA cert)
		sudo cat $temp_certs/certchain.pem | sudo awk -v tempcerts=$temp_certs 'split_after==1{n++;split_after=0} /-----END CERTIFICATE-----/ {split_after=1} {if(length($0) > 0) print > tempcerts "/certpiece" n ".pem"}'

		# Random alphanumeric string to host the certs on https server (to add a layer of obfuscation since there is no user auth on https server)
		apikey=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

		# Create "Server Certificate" (key + cert)
		cat "$temp_certs/key.pem" "$temp_certs/certpiece.pem" > "$temp_certs/servercertificate.pem"
		
		# Create "Trusted Root Certificate" (intermediate + ca)
		cat "$temp_certs/certpiece1.pem" "$temp_certs/certpiece2.pem" "$temp_certs/certpiece3.pem" > "$temp_certs/rootcert.pem"

		# Load files into tftpd-hpa shared location
		mkdir "$tftp_root/${key_apikey[$i]}"
		cp "$temp_certs/servercertificate.pem" "$tftp_root/${key_apikey[$i]}/"
		cp "$temp_certs/rootcert.pem" "$tftp_root/${key_apikey[$i]}/"
		sleep 5

		# SSH to switch to install cert
		expect_script="
			set timeout 60

			spawn ssh \"${edgesw_user[$i]}@${edgesw_list[$i]}\"
			# Accept ssh fingerprint
			expect {
				\"*yes/no*\" {
					send \"yes\r\";
					exp_continue
				}
				\"*assword*\"
			}
			send \"${edgesw_password[$i]}\r\"
			
			expect \" >\"
			send \"enable\r\"
			expect \"*assword:\"
			send \"${edgesw_password[$i]}\r\"
			expect \" #\"
			send \"no ip http secure-server\r\"
			expect \" #\"
			send \"copy tftp://$tftp_server/${key_apikey[$i]}/servercertificate.pem nvram:sslpem-server\r\"
			expect \" (y/n) \"
			send \"y\"
			expect \" #\"
			send \"copy tftp://$tftp_server/${key_apikey[$i]}/rootcert.pem nvram:sslpem-root\r\"
			expect \" (y/n) \"
			send \"y\"
			expect \" #\"
			send \"ip http secure-server\r\"
			expect \" #\"
			send \"write memory\r\"
			expect \" (y/n) \"
			send \"y\"
			expect \" #\"
			send \"exit\r\"
			expect \" >\"
			send \"exit\r\"
		"
		
		/usr/bin/expect -c "$expect_script"

		rm -rf "$tftp_root/${key_apikey[$i]}"

	fi
done

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
