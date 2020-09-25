#!/bin/bash
echo "Executing certificate request"
#
# The following environment variables are set from the pod executing this script snippet:
# $FQDN
# $ROUTENAME
# $ROUTETYPE
# $SERVICENAME
# $PORT
# $TARGET_NAMESPACE
#
# BEGIN CERTIFICATE REQUEST
#
# replace the commands for 'certmonger' in this section with suitable commands for accessing the PKI
# demo only using self-signed certificate; as for selfsigned certs there is no CA, we create a dummy ca.cer file
# Do not use strings with whitespaces for CN, OU or O
selfsign-getcert request -w -f /tmp/cert.crt -k /tmp/cert.key -N "CN=$FQDN,OU=example.com,O=myorg" -D "$FQDN" -U id-kp-serverAuth
ls -l /tmp
touch /tmp/ca.crt
#
echo "Certificate request completed"
# END CERTIFICATE REQUEST
#
# Create the route object
# in addition we save the certificates in a ConfigMap in the target namespace
CAFILE=/tmp/ca.crt
CERTFILE=/tmp/cert.crt
KEYFILE=/tmp/cert.key
DESTCAFILE=/tmp/reenc-ca.crt
MSGFILE=/tmp/msg.txt
ERR=""
echo "Creating route in namespace $TARGET_NAMESPACE"
if [ $ROUTETYPE == edge ]
then
  echo "Creating edge route"
  oc create route $ROUTETYPE $ROUTENAME -n $TARGET_NAMESPACE --insecure-policy=Redirect --service=$SERVICENAME --cert=$CERTFILE --key=$KEYFILE --ca-cert=$CAFILE --hostname=$FQDN --port=$PORT >$MSGFILE 2>&1
  RES=$?
elif [ $ROUTETYPE == passthrough ]
then
  echo "Creating passthrough route"
  oc create route $ROUTETYPE $ROUTENAME -n $TARGET_NAMESPACE --insecure-policy=Redirect --service=$SERVICENAME  --hostname=$FQDN --port=$PORT >$MSGFILE 2>&1
  RES=$?
elif [ $ROUTETYPE == reencrypt ]
then
  echo "Creating reencrypt route"
  oc get secret $REENC_CA_SECRET -n $TARGET_NAMESPACE -o json | jq '.data."tls.crt"' | sed 's/\"//g' | base64 -d >$DESTCAFILE
  RES=$?
  if [ $RES == 0 ]
  then
    oc create route $ROUTETYPE $ROUTENAME -n $TARGET_NAMESPACE --insecure-policy=Redirect --service=$SERVICENAME --cert=$CERTFILE --key=$KEYFILE --ca-cert=$CAFILE --dest-ca-cert=$DESTCAFILE --hostname=$FQDN --port=$PORT >$MSGFILE 2>&1
    RES=$?
  else
    ERR="$ROUTETYPE route: cannot get reencrypt cert $REENC_CA_SECRET in namespace $TARGET_NAMESPACE"
    RES=1
  fi
else
  ERR="unsupported route type $ROUTETYPE"
  echo $ERR
  RES=$?
fi
#
if [ $RES == 0 ]
then
  echo "Route $ROUTETYPE $ROUTENAME created"
  STATUS=success
  oc create secret generic route-$ROUTENAME-certs -n $TARGET_NAMESPACE --from-file=cert.cer=$CERTFILE --from-file=cert.key=$KEYFILE --from-file=ca.cer=$CAFILE --from-file=destca.cer=$DESTCAFILE
else
  echo "Error creating route $ROUTETYPE $ROUTENAME : $ERR"
  STATUS=failed
  oc create cm -n $TOOL_NAMESPACE $JOB-status --from-literal=status=$STATUS --from-literal=errtext=$ERR --from-file=message=$MSGFILE
fi
#
