#!/bin/bash

TOOL_NAMESPACE=certificate-tool

log()
{
  echo $(date +%F--%H-%M-%S.%N) ": " $1
}

check_cert_expiration()
{
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

  openssl s_client -servername $fqdn -connect $fqdn:$port </dev/null 2>/dev/null | openssl x509 -noout -checkend $(( 24*3600*$daterange )) 2>&1 >/dev/null
}

create_result_cm()
{
  # arg-1: target file
  # arg-2: days
  # arg-3: config map name

  targetfile=$1
  days=$2
  cmname=$3

  if [ -f $targetfile ]
  then
    # delete old CM and create new one from file content of identified routes
    log "Creating ConfigMap for list of routes covering expired certificates for $days days."
    oc delete -n $TOOL_NAMESPACE configmap $cmname --ignore-not-found && oc create -n $TOOL_NAMESPACE configmap $cmname --from-file=expiring=$targetfile
    if [ $? -gt 0 ]
    then
      log "Error - ConfigMap for list of routes covering expired certificates for $days days not (re-) created. See previous log entries for discovered expiring route certificates."
    fi
  else
    # attempt to delete CM only (if it exists) as we do not have new routes for reporting
    oc delete -n $TOOL_NAMESPACE configmap $cmname --ignore-not-found
  fi

}

check_expiration()
{
  # arg-1: namespace
  # arg-2: route
  # arg-3: url
  # arg-4: target file
  # arg-5: days

  ns=$1
  route=$2
  url=$3
  targetfile=$4
  days=$5

  check_cert_expiration $url 443 $days
  result=$?
  if [ $result -gt 0 ]
  then
    log "Route with $days d certificcate expiration: Namespace: $ns , Route: $route , URL: $url"
    echo "Namespace: " $ns ", Route: " $route ", URL: " $url >>$targetfile
  fi

}

FILE30=/tmp/routes-30.txt
FILE90=/tmp/routes-90.txt
rm -f $FILE30
rm -f $FILE90

# get namespaces and skip 'openshift' namespaces
for ns in $(oc get project -o custom-columns=name:metadata.name --no-headers | grep -v openshift)
do
  # get routes in namespace
  for route in $(oc -n $ns get route -o custom-columns=name:metadata.name --no-headers)
  do
    url=$(oc -n $ns get route $route -o custom-columns=url:spec.host --no-headers)

    # check 90 days
    check_expiration $ns $route $url $FILE90 90

    # check 30 days
    check_expiration $ns $route $url $FILE30 30
  done
done

create_result_cm $FILE30 30 cert-exp-30d
create_result_cm $FILE90 90 cert-exp-90d
