#!/bin/sh

## IMPORTANT: 
#	wget to https addresses are BLOCKED by the esxi firewall by default
#	you must disable the firewall (probably not recommended): esxcli network firewall set --enabled false
#	or enable a rule:  esxcli network firewall ruleset set --enabled="true" --ruleset-id="httpClient"

# Script updates an ESXi certificate and key. It also restarts
# the necessary services. If the host is connected to vCenter,
# vCenter should have Certificate Mode set to Full Custom.

# This script should be securely placed with limited access
# (e.g. owned by root with permissions of 700) to avoid
# compromising the API Keys

# I don't believe ECDSA Keys are supported and RSA may be limited to 2048 bit.

## Recommended cron -- run at boot (in case system was powered off
# during a renewal, and run weekly)
# Pick any time you like. This time was arbitrarily selected.

# To persist in cron, make helper script (cron seems to wipe every reboot):
	#!/bin/sh

	#/bin/kill $(cat /var/run/crond.pid)
	#/bin/echo -e '5 4 * * 0 /store/lego/lego.sh\n' >> /var/spool/cron/crontabs/root
	#crond

# then add run of helper script to /etc/rc.local.d/local.sh
## NOTE: If LeGo server is running on a VM, add sleep 300-600 to wait 5-10 minutes for the VM to come up
	# line for run once at boot
#	nohup /store/lego/lego.sh 300 &
	# line to install cron job on boot
#	/store/lego/cron-install.sh


## Set VARs in accord with environment
cert_apikey=<cert API key>
key_apikey=<key API key>
# server hosting key/cert
server=certdp.local:port
# name of the key/cert (as it is on server)
cert_name=esxi.example.com

# URL paths
api_cert_path=legocerthub/api/v1/download/certificates/$cert_name
api_key_path=legocerthub/api/v1/download/privatekeys/$cert_name

# other
esxi_certs=/etc/vmware/ssl
cert_owner=root:root
# temp folder
temp_certs=/tmp/tempcerts
# path to store a timestamp to easily see when script last ran
time_stamp=/store/lego/timestamp.txt

### Allow for a sleep (used, in combo with nohup, when run from local.sh so the local.sh step doesn't hang during the sleep)
if [ ! -z $1 ]; then sleep "$1"; fi

####
mkdir $temp_certs
# Fetch LeGo
http_statuscode=$(wget https://$server/$api_cert_path --header="apiKey: $cert_apikey" -O $temp_certs/rui.crt --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if test $http_statuscode -ne 200; then exit 1; fi
http_statuscode=$(wget https://$server/$api_key_path --header="apiKey: $key_apikey" -O $temp_certs/rui.key --server-response 2>&1 | tee /dev/tty | awk '/^  HTTP/{print $2}')
if test $http_statuscode -ne 200; then exit 1; fi

diff_status=$(diff "$temp_certs/rui.crt" "$esxi_certs/rui.crt")
cert_diffcode=$?
diff_status=$(diff "$temp_certs/rui.key" "$esxi_certs/rui.key")
key_diffcode=$?

if ( test $cert_diffcode != 0 ) || ( test $key_diffcode != 0 ) ; then

	#no need to stop anything

	cp -rf $temp_certs/* $esxi_certs/

	chown $cert_owner $esxi_certs/rui.crt
	chown $cert_owner $esxi_certs/rui.key

	chmod 644 $esxi_certs/rui.crt
	chmod 400 $esxi_certs/rui.key

	#restart webui, sleep in between just a touch
	/etc/init.d/hostd restart
	sleep 5
	/etc/init.d/vpxa restart

fi

rm -rf $temp_certs
echo "Last Run: $(date)" > $time_stamp
