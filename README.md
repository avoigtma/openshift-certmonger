# OCP Route Creation with TLS Certificates derived from a PKI using SCEP

This document describes an approach on how to create Route objects in OpenShift which use custom certificates. We use the `certmonger` tool running in a Pod on OpenShift to request the certificates from the PKI using SCEP protocol. The pod afterwards creates a Route object in a target Namespace having the requested certificated configured.

## Overview

The approach to execute the retrieval of certificates and creation of resulting OpenShift Routes is as follows:

* The tool is installed in a  Namespace, which is owned by the platform owner team, as the tool requires to be executed with `cluster-admin` permissions.
* An arbitrary user (i.e. the owner of an application deployed in some Namespace in OpenShift) requests the creation of a Route in his Namespace which should obtain a custom certificate.
* Steps
  * The owner of an application uses a template deployed globally in `openshift` Namespace to generate a request.
  * This request is represented by a ConfigMap in the tools Namespace and a corresponding ConfigMap within the application Namespace. Data within these ConfigMaps link to each other.
  * A CronJob in the tools Namespace regularly runs and checks for new requests (i.e. ConfigMaps) being created within the tools Namespace.
  * Both ConfigMaps are read and the creation of a Job within the tools Namespace is triggered.
  * This Job (asynchronously from the Job run by the CronJob) interacts with the PKI (using `certmonger`) to obtain the TLS certificate and reates the custom Route in the application Namespace. Then it removes the task object (ConfigMap).

## Deployment

Run the steps described in the next sections for deployment.

### Create Namespace

Create a Namespace for hosting the `certmonger` tool.

A Namespace called `certificate-tool` is used which may host any kind of operation-support tools for the platform. But any other namespace can be used as well. In this case adjust the YAML files respectively.

```shell
oc create -f openshift/namespace.certTool.yaml
```

## Load Templates

Load the template to create to the requests into the public `openshift` Namespace. The template for the `certmonger job` is loaded within the tools Namespace (`certificate-tool`).

```shell
oc create -f openshift/template.cm.certmonger.yaml
oc create -f openshift/template.cm.certmonger-certonly.yaml
oc create -f openshift/template.job.certmonger.yaml
```

## Custom Role

In order to allow creation of the requests by any user, we establish a custom Role within the tool Namespace. That Role (and role mapping) will allow any authenticated user to *only create* a ConfigMap for a certificate request using the template within the tools Namespace.

```shell
oc create -f openshift/role.certmonger.yaml
oc create -f openshift/rolebinding.certmongerRole.yaml
```

### Import Base Image

Run the following as `cluster-admin`, to import into `openshift` Namespace.

```shell
oc import-image centos --from=registry.centos.org/centos:centos8 -n openshift --confirm
```

### Build Dockerfile

Build the container image from a Dockerfile. The image includes both `certmonger` and the `oc` client.

```shell
oc create -f openshift/is.certmonger.yaml
oc create -f openshift/buildcfg.certmongerDocker.yaml
```

In case the creation of the BuildConfig object did not already start a build, or in case the Dockerfile changed, run:

```shell
oc start-build certmonger
```

### Create ServiceAccount

Create a ServiceAccount to run the Job Pod for Route creation.

```shell
oc create -f openshift/sa.certMongerJob.yaml
```

### Create Role Binding for ServiceAccount

The ServiceAccount needs to get a RoleBinding to obtain the required permissions.

```shell
oc create -f openshift/crb.certmongerJob.yaml
```

> For simplicity the `cluster-admin` Role is used. It would be a better solution to create a custom Role definition having only the required permissions for the ServiceAccount. However, as the pruning Jobs anyway run in a Namespace owned by a platform team and thus `cluster-admin` enabled users, using `cluster-admin` Role is acceptable.

### Add SCC

The job needs to run with a fixed user id, hence add the ServiceAccount to `anyuid` SCC.

```shell
oc adm policy add-scc-to-user anyuid -z certmonger-job-sa -n certificate-tool
```

### Deploy Certificate Tool

#### Create ConfigMaps and Secrets

##### Secrets holding Corporate Root CA

Unless the example for self-signed certificates is used, the Job requesting the certificate requires to have the corporate root CA (public key part) to be part of the container's trust store.

A Secret is used to hold the root CA which is mounted to the Job Pod. At this point also make sure that the `trustedCA` bundle is set in the clusters proxy configuration and that the CA's `ca.crt` file is saved in the DER format.

```shell
oc create secret -n certificate-tool generic ca-secret --from-file=ca.crt=/path/to/ca.crt
```

When using the self-signed example simply create a Secret with a dummy value, as the Secret is not used:

```shell
oc create secret -n certificate-tool generic ca-secret --from-literal=ca.crt=dummy
```

##### Secret for PKI access

When accessing the PKI using SCEP protocol, a passphrase must be provided. This passphrase is managed in a Secret which is loaded into the `certmonger` Pod interacting with the PKI using SCEP.

```shell
oc create secret -n certificate-tool generic pki-secret --from-literal=passphrase=supersecret
```


##### ConfigMaps holding scripts

A ConfigMap is used to hold the script code executed by the Job and the CronJob.

* Use `certmonger` to request a certificate from the PKI.
* Use `oc` to create the route object.

> *noproxy settings*
>
> The scripts - depending on environment - may need `noproxy` settings for successful communication to OpenShift API Server or PKI. Please adjust the `noproxy` settings in the script accordingly.

> *Using PKI instead of selfsigned certificates.*
>
> The `runJob.sh` script is creating self-signed certificates and acts as an example which can run in any OpenShift environment, irrespective of a specific PKI/SCEP server being used. The `podscripts` directory contains an alternate `runJob_scep-example.sh` script which provides the example of accessing a SCEP server.

```shell
oc create cm -n certificate-tool route-creation-script --from-file=runJob.sh=./podscripts/runJob.sh
oc create cm -n certificate-tool cronjob-process-script --from-file=cronProcess.sh=./podscripts/cronProcess.sh
```

#### Create CronJob

Create the CronJob to monitor the created requests and execute the Route creation jobs.

> Please adjust the schedule of the CronJob. Example runs every 2 minutes.

```shell
oc create -f openshift/cronJob.certmonger.yaml
```

# Usage

## Enable User to request Certificates

A rolebinding for a specific role already exists (see above) which allows any authenticated user to submit requests for Route creation.

In case only selected users should obtain these permissions, delete the rolebinding created before and individually add the allowed users (or Groups) to the Role in the tools Namespace:

```shell
oc adm policy add-role-to-user job-initiator-role <username> --role-namespace=certificate-tool -n certificate-tool
```

## UI

Authenticate at the console of the corresponding cluster. Then navigate through the following pages:

* Developer View
* Click on `+ Add`
* Chosse `From Catalog`
* Filter on `Other` and `Template`
* Choose `Route Creation Request Template` in case you want to create a Route with a TLS certificate (certificate is stored as well in a secret)
** Choose `Certificate Creation Request Template` in case you want to request a certificate only (stored in a secret) but not create a Route

Fill in the parameters as described. Then wait up to two minutes until the request is processed by the CronJob.
## CLI

```shell
oc new-app routecreation-request-template \
  -p TOOL_NAMESPACE=certificate-tool \
  -p SERVICENAME=<SERVICENAME> \
  -p PORT=<PORT> \
  -p ROUTE_IDENTIFIER=<ROUTE_IDENTIFIER> \
  -p ROUTETYPE=<ROUTETYPE> \
  -p TARGET_NAMESPACE=<TARGET_NAMESPACE> \
  -p FQDN=<FQDN>
```

Change the parameters to your needs. Then wait up to two minutes until the request is processed by the CronJob.

For certificate request only, use `oc new-app certcreation-request-template` with appropriate parameters.

# Technical Information

## Overview

* Custom Role to allow creation of ConfigMap in Namespace where `certmonger` job runs
    * Name pattern: route-task-uuid
    * Namespace: certmonger Namespace
        * contents: the target Namespace and a uuid
    * Namespace: target Namespace
        * parameters for the Route creation as key-value pairs
* CronJob to processs Route creation according to discovered ConfigMaps of above name pattern
    * process the certificate and Route creation
    * remove ConfigMap afterwards
* Certificates
    * The created certificates are placed in a secret in the application target namespace. The secret is called 'route-ABC-certs' (ABC = name of the route being created)


* Error handling
    * if the `certmonger` job pod fails, there is a ConfigMap called `certmonger-<job_uuid>-status` in the certificate-tool Namespace; this ConfigMap is created only in case of failure, not in case of success

## Error Information

* if the certmonger job pod fails, there is a config map called `certmonger-<job_uuid>-status` in the certificate-tool namespace; this config map is created only in case of failure, not in case of success
* if the task processing job fails, there is a config map called `err-route-task-<certmonger_task_uuid>` in the certificate-tool namespace covering error information; this config map is created only in case of failure, not in case of success

> Inspect the Yaml or JSON source of each error config map to get details about the processing errors.
