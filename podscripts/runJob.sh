#!/bin/bash
echo "Executing certificate request"
#
# The following environment variables are set from the pod executing this script snippet:
# $HOSTNAME
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
selfsign-getcert request -w -f /tmp/cert.crt -k /tmp/cert.key -N "CN=$HOSTNAME,OU=example.com,O=myorg" -D "$HOSTNAME" -U id-kp-serverAuth
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
echo "Creating route in namespace $TARGET_NAMESPACE"
oc create cm -n $TARGET_NAMESPACE route-$ROUTENAME-certs --from-file=cert.cer=$CERTFILE --from-file=cert.key=$KEYFILE --from-file=ca.cer=$CAFILE
oc create $ROUTETYPE $ROUTENAME -n $TARGET_NAMESPACE --service=$SERVICENAME --cert=$CERTFILE --key=$KEYFILE --ca-cert=$CAFILE --hostname=$HOSTNAME --port=$PORT
echo "Route created"
#
