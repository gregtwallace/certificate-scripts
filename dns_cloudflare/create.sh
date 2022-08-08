#!/bin/bash

# Create new
lexicon cloudflare create $1 TXT --name="$2" --content="$3"

sleep 45
#sleep 60
