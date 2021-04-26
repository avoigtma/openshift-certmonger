#!/bin/bash

# arg-1: FQDN
# arg-2: port
# arg-3: dates for expiration

if [ $# -ne 3 ];
then
  echo "$0: illegal number of parameters - 3 arguments required (fqdn, port, dates for expiration), only $# arguments were given";
  exit 1;
fi


fqdn=$1
port=$2
daterange=$3

openssl s_client -servername $fqdn -connect $fqdn:$port </dev/null 2>/dev/null | openssl x509 -noout -checkend $(( 24*3600*$daterange ))

