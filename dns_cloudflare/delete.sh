#!/bin/bash

sleep 270

lexicon cloudflare delete $1 TXT --name="$2"
