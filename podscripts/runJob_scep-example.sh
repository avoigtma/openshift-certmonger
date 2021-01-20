#!/bin/bash

# set NO_PROXY if needed for your environment
# NO_PROXY should cover: API server, (internal) registry, node subnet, pod subnet, services subnet (IP and DNS), plus any other local DNS domain not to be proxied
#
# export NO_PROXY=any-noproxy-domain-list,.clustername.basedomain,NODE-SUBNET-CIDR,POD-SUBNET-CIDR,SERVICE-SUBNET-CIDR,.openshift-image-registry.svc,.svc
#
#
# The following environment variables are set from the pod executing this script snippet:
# $FQDN
# $ROUTE_IDENTIFIER
# $ROUTETYPE
# $SERVICENAME
# $PORT
# $TARGET_NAMESPACE
#
CAFILE=/tools/ca/ca.crt
CERTFILE=/tmp/cert.crt
KEYFILE=/tmp/cert.key
DESTCAFILE=/tmp/reenc-ca.crt
MSGFILE=/tmp/msg.txt
ERRFILE=/tmp/err.txt
ERR=""
echo >$MSGFILE
echo >$ERRFILE
#
# BEGIN CERTIFICATE REQUEST
#
echo "Executing certificate request"
#
# copy the corporate root ca file from mounted config map to '/etc/pki/ca-trust/source/anchors' and update ca trust
cp $CAFILE /etc/pki/ca-trust/source/anchors/corp-root-ca.crt
update-ca-trust
#
timeout_budget=120
timeout_usage=0
#
echo "Add SCEP CA"
getcert add-scep-ca -c MY-SCEP-CA -u https://scep.pki.url.example.com/my/scep/pki/uri/xyz
echo "Wait until the added SCEP CA has been processed by certmonger"
until [ "$timeout_usage" -ge "$timeout_budget" ]
do 
   getcert refresh-ca -c MY-SCEP-CA | grep -q "being refreshed." && break
   timeout_usage=$((timeout_usage+1)) 
   sleep 1
done
#
echo "Retrieve certificate from SCEP CA"
# Do not use strings with whitespaces for CN, OU or O
getcert request -I ${FQDN} -c MY-SCEP-CA -N "CN=${FQDN},OU=MyOrgUnitName,O=MyOrgName" -L $PKIPASSPHRASE -w -v -f $CERTFILE -k $KEYFILE
echo "Wait until the certificate request has been processed"
until [ "$timeout_usage" -ge "$timeout_budget" ]
do
   getcert list -i ${FQDN} && break
   timeout_usage=$((timeout_usage+1)) 
   sleep 1
done
#
echo "Certificate request completed"
# Check if cert files were created
if [ -f $CERTFILE ]
then
  echo "Certificate retrieved from PKI"
else
  # create cm with error information
  ERR="No certificate retrieved from PKI"
  echo $ERR >$ERRFILE
  STATUS=failed
  oc create cm -n $TOOL_NAMESPACE $JOB-status --from-literal=status=$STATUS --from-file=errtext=$ERRFILE --from-file=message=$MSGFILE
  exit 1
fi
#
#
# END CERTIFICATE REQUEST
#
# Create the route object
# in addition we save the certificates in a ConfigMap in the target namespace
#
echo "Creating route in namespace $TARGET_NAMESPACE"
if [ $ROUTETYPE == edge ]
then
  echo "Creating edge route"
  oc create route $ROUTETYPE $ROUTE_IDENTIFIER -n $TARGET_NAMESPACE --insecure-policy=Redirect --service=$SERVICENAME --cert=$CERTFILE --key=$KEYFILE --ca-cert=$CAFILE --hostname=$FQDN --port=$PORT >$MSGFILE 2>&1
  RES=$?
elif [ $ROUTETYPE == passthrough ]
then
  echo "Creating passthrough route"
  oc create route $ROUTETYPE $ROUTE_IDENTIFIER -n $TARGET_NAMESPACE --insecure-policy=Redirect --service=$SERVICENAME  --hostname=$FQDN --port=$PORT >$MSGFILE 2>&1
  RES=$?
elif [ $ROUTETYPE == reencrypt ]
then
  echo "Creating reencrypt route"
  oc get secret $REENC_CA_SECRET -n $TARGET_NAMESPACE -o json | jq '.data."tls.crt"' | sed 's/\"//g' | base64 -d >$DESTCAFILE
  RES=$?
  if [ $RES == 0 ]
  then
    oc create route $ROUTETYPE $ROUTE_IDENTIFIER -n $TARGET_NAMESPACE --insecure-policy=Redirect --service=$SERVICENAME --cert=$CERTFILE --key=$KEYFILE --ca-cert=$CAFILE --dest-ca-cert=$DESTCAFILE --hostname=$FQDN --port=$PORT >$MSGFILE 2>&1
    RES=$?
  else
    ERR="$ROUTETYPE route: cannot get reencrypt cert $REENC_CA_SECRET in namespace $TARGET_NAMESPACE"
    RES=1
  fi
else
  ERR="unsupported route type $ROUTETYPE"
  echo $ERR
  RES=2
fi
#
if [ $RES == 0 ]
then
  # create secret for created certificates
  echo "Route $ROUTETYPE $ROUTE_IDENTIFIER created"
  STATUS=success
  if [ -f $DESTCAFILE ]
  then
    # store certificate file, associated key and destination ca for reencrypt route
    oc create secret generic route-$ROUTE_IDENTIFIER-certs -n $TARGET_NAMESPACE --from-file=cert.cer=$CERTFILE --from-file=cert.key=$KEYFILE --from-file=ca.cer=$CAFILE --from-file=destca.cer=$DESTCAFILE
  else
    # store certificate file, associated key and destination ca for edge or passthru route
    oc create secret generic route-$ROUTE_IDENTIFIER-certs -n $TARGET_NAMESPACE --from-file=cert.cer=$CERTFILE --from-file=cert.key=$KEYFILE --from-file=ca.cer=$CAFILE
  fi
  # store an additional secret as tls secret with certificate and key only
  oc create secret tls route-$ROUTE_IDENTIFIER-certs-tls  -n $TARGET_NAMESPACE --cert=$CERTFILE --key=$KEYFILE
else
  # create cm with error information
  echo "Error creating route $ROUTETYPE $ROUTE_IDENTIFIER : $ERR"
  echo $ERR >$ERRFILE
  STATUS=failed
  oc create cm -n $TOOL_NAMESPACE $JOB-status --from-literal=status=$STATUS --from-file=errtext=$ERRFILE --from-file=message=$MSGFILE
fi
#
