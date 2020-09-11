#!/bin/bash

# set NO_PROXY if needed for your environment
# NO_PROXY should cover: API server, (internal) registry, node subnet, pod subnet, services subnet (IP and DNS), plus any other local DNS domain not to be proxied
#
# export NO_PROXY=any-noproxy-domain-list,.clustername.basedomain,NODE-SUBNET-CIDR,POD-SUBNET-CIDR,SERVICE-SUBNET-CIDR,.openshift-image-registry.svc,.svc

echo "Processing ConfigMaps representing Certificate and Route creation requests"

create_err_cm() {
    oc create cm err-$1 --from-literal=err-reason="$2" --from-literal=appcmname=$APPCMNAME --from-literal=targetNamespace=$APPNS --from-literal=toolsNamespace=$TOOLSNS --from-literal=taskuuid=$APPUUID
}

remove_cm() {
    oc delete cm $1
}

for cm in $(oc get cm --no-headers -o custom-columns=NAME:.metadata.name | grep ^route-task)
do
    taskid=$(echo $cm | sed 's/route-task-//')
    echo "Processing cm " $cm
    oc get cm $cm -o json >/tmp/$cm.json
    APPCMNAME=$(jq -r '.data.appcmname' /tmp/$cm.json)
    APPNS=$(jq -r '.data.targetNamespace' /tmp/$cm.json)
    TOOLNS=$(jq -r '.data.toolNamespace' /tmp/$cm.json)
    APPUUID=$(jq -r '.data.taskuuid' /tmp/$cm.json)

    oc get cm $APPCMNAME -n $APPNS -o json >/tmp/$APPCMNAME.json
    retVal=$?
    if [ $retVal -ne 0 ]; then
        err="Error ($cm): ConfigMap $APPCMNAME in application namespace $APPNS does not exist or cannot be retrieved. Stop processing this taks."
        echo $err
        create_err_cm $cm "$err"
        continue
    fi

    APPAPPUUID=$(jq -r '.data.taskuuid' /tmp/$APPCMNAME.json)
    if [ $APPAPPUUID != $APPUUID ]; then
        err="Error ($cm): AppUUID value differs from creation request and value ConfigMap in application namespace. Suspecting fraud. Stop processing this taks."
        echo $err
        create_err_cm $cm "$err"
        remove_cm $cm
        continue
    fi

    TARGETNAMESPACE=$(jq -r '.data.targetNamespace' /tmp/$APPCMNAME.json)
    SERVICENAME=$(jq -r '.data.serviceName' /tmp/$APPCMNAME.json)
    ROUTENAME=$(jq -r '.data.routeName' /tmp/$APPCMNAME.json)
    ROUTETYPE=$(jq -r '.data.routeType' /tmp/$APPCMNAME.json)
    PORT=$(jq -r '.data.port' /tmp/$APPCMNAME.json)
    HOSTNAME=$(jq -r '.data.hostname' /tmp/$APPCMNAME.json)

    oc new-app -n $TOOLNS job-routecreation-template -p TOOL_NAMESPACE=$TOOLNS -p SERVICENAME=$SERVICENAME -p PORT=$PORT -p ROUTENAME=$ROUTENAME -p ROUTETYPE=$ROUTETYPE -p TARGET_NAMESPACE=$TARGETNAMESPACE -p HOSTNAME=$HOSTNAME -p JOBUUID=$taskid
    retVal=$?
    if [ $retVal -ne 0 ]; then
        err="Error ($cm): Cannot process template for creating CertMonger job. Stop processing this taks."
        echo $err
        create_err_cm $cm "$err"
        remove_cm $cm
        continue
    fi

    echo "Started job for creating Certificate and route for request " $cm
    remove_cm $cm
    echo "Completed processing of task cm '$cm'; removed cm."
done
