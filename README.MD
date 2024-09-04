This repo holds various scripts to fetch keys and certificates
from a central host.

The root contains scripts designed to work with Cert Warden
but are also generic enough to modify for other providers.

The certera path contains scripts designed to work with
Certera in particular.

dns_cloudflare contains scripts Certera can call to properly
add and remove ACME dns records on Cloudflare.

full-chain-pem.sh is the most generic script
