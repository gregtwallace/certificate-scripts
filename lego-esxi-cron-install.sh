#!/bin/sh

# Helper script for cron on ESXi hosts

/bin/kill $(cat /var/run/crond.pid)
/bin/echo -e '5 4 * * 0 /store/lego/lego.sh\n' >> /var/spool/cron/crontabs/root
crond
