#!/bin/bash

# WARNING: Edge Switch does not actually verify that the signing CA
# is valid. This introduces a risk for MITM attacks between the cert
# server and the switch.

# TODO: Maybe add connection and CA check from the server running this
# script, though this would not remove all MITM risk (no risk removed
# if script is running on the cert server).

# Script runs on a machine, NOT on edge switches
# Script downloads the private certificate (key/cert combo) and
# the matching ca root chain. It then installs both on each
# specified switch.

# File composition:
#	SSL Trusted Root Certificate PEM File = Intermediate CA Cert, CA Root Cert
#	SSL Server Certificate PEM File = Server Key, Server Cert

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# ECDSA Keys are NOT supported.

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# sudo crontab -e
# @reboot sleep 15 && /script/path/here
# 5 4 * * 2 /script/path/here

## Set VARs in accord with environment
# Make a set of all of these values for each edge switch to install on
edgesw_list[0]=sw1.example.com
edgesw_cert_name[0]=<cert name in lego>
edgesw_ssh_thumb[0]=<ssh sha256 thumbprint> # format example: SHA256:r4sOgTWodOj9Xo2QdJYhE9XyswXmQOPTY5Hjxi9Dqgk
# API keys
cert_apikey[0]=<cert API key>
key_apikey[0]=<key API key>
# edge sw login credentials
edgesw_user[0]=<user>
edgesw_password[0]=<password>

# additional edge sw, etc. incremending [i] each time
edgesw_list[1]=sw2.example.com
edgesw_cert_name[1]=<cert name in lego>
edgesw_ssh_thumb[1]=<ssh sha256 thumbprint>
cert_apikey[1]=<cert API key>
key_apikey[1]=<key API key>
edgesw_user[1]=<user>
edgesw_password[1]=<password>

edgesw_list[2]=sw3.example.com
edgesw_cert_name[2]=<cert name in lego>
edgesw_ssh_thumb[2]=<ssh sha256 thumbprint>
cert_apikey[2]=<cert API key>
key_apikey[2]=<key API key>
edgesw_user[2]=<user>
edgesw_password[2]=<password>

# server hosting key/cert; edge switch will NOT accept a port
# API must be running on port 443
server=certdp.local
# URL paths
api_privatecert_path=api/v1/download/privatecerts
api_carootchain_path=api/v1/download/certrootchains
# local user who will own certs
cert_owner=root
# path to store a timestamp to easily see when script last ran
time_stamp=/opt/edgeswitch/lego-lastrun.txt
# temp folder
temp_certs=/tmp/edgeswcerts


## Script
# Check if expect is installed
if ! command -v /usr/bin/expect &> /dev/null; then echo "This script requires expect but it's not installed.";exit 1;fi

# Make folders if don't exist
sudo [ -d "$temp_certs" ] || sudo mkdir "$temp_certs"

# Run actions for each switch
# Using the ! causes i to equal the index, instead of the value in the array at that index
for i in "${!edgesw_list[@]}"; do

	# Purge any old temp certs
	sudo rm -rf "$temp_certs"'/*'

	# Fetch private cert; end this iteration of the loop if curl doesn't work properly
	http_statuscode=$(sudo curl https://$server/$api_privatecert_path/${edgesw_cert_name[$i]} -H "apiKey: ${cert_apikey[$i]}.${key_apikey[$i]}" --output $temp_certs/privatecert.pem --write-out "%{http_code}" -G)
	if test $http_statuscode -ne 200; then continue; fi

	# Fetch top cert from the switch by connecting with SSL (don't fail out if cert isn't collected, instead assume SSL isn't configured yet and continue)
	echo | openssl s_client -connect edge-sw-1.greg.gtw86.com:443 -showcerts 2>&1 | sed '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/!d;/-END CERTIFICATE-/q' > $temp_certs/switchcert.pem

	# Save cert from api private cert
	echo | cat $temp_certs/privatecert.pem | sed '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/!d;/-END CERTIFICATE-/q' > $temp_certs/cert.pem

	# Check api cert against switch cert
	diff_status=$(sudo diff "$temp_certs/cert.pem" "$temp_certs/switchcert.pem")
	cert_diffcode=$?

	# if different
	if ( test $cert_diffcode != 0 ) ; then

		# SSH script to install cert on switch
		expect_script="
			set timeout 60

			spawn ssh \"${edgesw_user[$i]}@${edgesw_list[$i]}\" -oHostKeyAlgorithms=+ssh-rsa
			# Accept ssh fingerprint (if not already present)
			expect {
				\"*yes/no*\" {
					send \"${edgesw_ssh_thumb[$i]}\r\";
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
			send \"copy https://$server/$api_privatecert_path/${edgesw_cert_name[$i]}/${cert_apikey[$i]}.${key_apikey[$i]}/privcert.pem nvram:sslpem-server\r\"
			expect \" (y/n) \"
			send \"y\"
			expect \" #\"
			send \"copy https://$server/$api_carootchain_path/${edgesw_cert_name[$i]}/${cert_apikey[$i]}/cachain.pem nvram:sslpem-root\r\"
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

		# execute ssh script
		/usr/bin/expect -c "$expect_script"

	fi
done

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
