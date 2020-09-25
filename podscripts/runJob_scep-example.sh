#!/bin/bash

# set NO_PROXY if needed for your environment
# NO_PROXY should cover: API server, (internal) registry, node subnet, pod subnet, services subnet (IP and DNS), plus any other local DNS domain not to be proxied
#
# export NO_PROXY=any-noproxy-domain-list,.clustername.basedomain,NODE-SUBNET-CIDR,POD-SUBNET-CIDR,SERVICE-SUBNET-CIDR,.openshift-image-registry.svc,.svc

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
# copy the corporate root ca file from mounted config map to '/etc/pki/ca-trust/source/anchors' and update ca trust
cp /tools/ca/ca.crt /etc/pki/ca-trust/source/anchors/corp-root-ca.crt
update-ca-trust
# add scep ca
# we sleep afterwards to allow the added scep ca to be processed by certmonger; an immediate getcert request may fail
getcert add-scep-ca -c MY-SCEP-CA -u https://scep.pki.url.example.com/my/scep/pki/uri/xyz
sleep 16
# retrieve the certificate via SCEP
# Do not use strings with whitespaces for CN, OU or O
getcert request -I ${FQDN} -c MY-SCEP-CA -N "CN=${FQDN},OU=MyOrgUnitName,O=MyOrgName" -L $PKIPASSPHRASE -w -v -f /tmp/cert.crt -k /tmp/cert.key
sleep 8
#
echo "Certificate request completed"
# Check if cert files were created
[ -f /tmp/cert.crt ] || exit 1
# END CERTIFICATE REQUEST
#
# Create the route object
# in addition we save the certificates in a ConfigMap in the target namespace
CERTFILE=/tmp/cert.crt
KEYFILE=/tmp/cert.key
echo "Creating route in namespace $TARGET_NAMESPACE"
oc create cm -n $TARGET_NAMESPACE route-$ROUTENAME-certs --from-file=cert.cer=$CERTFILE --from-file=cert.key=$KEYFILE
oc create route $ROUTETYPE $ROUTENAME -n $TARGET_NAMESPACE --service=$SERVICENAME --cert=$CERTFILE --key=$KEYFILE --hostname=$FQDN --port=$PORT
echo "Route created"
#
