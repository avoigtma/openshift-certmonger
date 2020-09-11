# OCP Route Creation with TLS Certificates derived from a PKI using SCEP

This document describes an approach how to create Route objects in OpenShift which use custom certificates. The certificates are obtained from a PKI using SCEP API. We use the 'certmonger' tool running in a Pod on OpenShift to request the certificates from the PKI using SCEP protocol. The pod afterwards creates a Route object in a target namespace having the requested certificated configured.

> Open items:
> 
> * update of the certificates (as of now, need to delete and re-create the route)
> * replace template-based approach using an Operator
> * custom role for executing the job (instead of cluster-admin)
> * ...

## Repository Link
Base repository link for all artefacts referenced in the following description: <https://github.com/avoigtma/openshift-certmonger>

>> In the remainder of the documents, all commands are executed in the 'certmonger-job' repository directory of the source repository.

## Overview

The approach to execute the retrieval of certificates and creation of resulting OpenShift Routes is as follows:

* The tool as described in the following is installed in a defined namespace, the latter owned by the platform owner team, as the tool requires to be executed with cluster-admin permissions.
* An arbitrary user (i.e. the owner of an application deployed in some namespace in OpenShift) can request the creation of a route in his namespace which obtains a custom certificate.
* Steps
  * Application user uses a template deployed globally in 'openshift' namespace to generate a request.
    * This request is represented by a ConfigMap in the tools namespace and a corresponding ConfigMap within the application namespace.
      * Internal data within these ConfigMaps link both.
    * A CronJob in the tools namespace regularly runs
      * checks for new requests (i.e. ConfigMaps) being created within the tools namespace
      * reads these ConfigMaps and for each such Config Map
        * reads the data from the corresponding ConfigMap from application namespace
        * triggers creation of a Job within the tools namespace
          * this Job (asynchronously from the Job run by the CronJob) interacts with the PKI (using 'certmonger') to obtain the TLS certificate
          * creates the custom route in the application namespace
      * removes the task object (ConfigMap)

## Deployment

Run the steps described in the next sections for deployment.

### Create Namespace

Create a namespace for hosting the 'certmonger' tool.

We use a namespace called 'certificate-tool' which may host any kind of operation-support tools for the platform. But any other namespace can be used as well. Please note you need to adjust the Yaml files respectively.

```shell
oc new-project certificate-tool
```

or use

```shell
oc create -f openshift/namespace.certTool.yaml
```

## Load Templates

We need to load the template to create to the requests into the public 'openshift' namespace. The template for the 'certmonger job' is loaded within the tools namespace ('certificate-tool').

```shell
oc create -f openshift/template.cm.certmonger.yaml
oc create -f openshift/template.job.certmonger.yaml
```

## Custom Role

In order to allow creation of the requests by any user, we establish a custom role within the tool namespace. That role (and role mapping) will allow any authenticated user to create a ConfigMap for a certificate request using the template within the tools namespace.

> Note: The role will allow any user to create other ConfigMaps as well, but only create, not list (determine) and not get their content.

```shell
oc create -f openshift/role.certmonger.yaml
oc create -f openshift/rolebinding.certmongerRole.yaml
```

### Import Base Image

Run the following as cluster admin, as we want to import into openshift namespace.

```shell
oc import-image centos --from=registry.centos.org/centos:centos8 -n openshift --confirm
```

### Build Dockerfile

We create our own tool image from a Dockerfile. The image includes both 'certmonger' and the 'oc' client.

#### Create new build (and target image stream)

> Note: we create a new build config using 'oc new-build', delete the bc afterwards and (re-)create our own build config. This is just a simple 'workaround-style' approach to create the imagestream required as the target of the build :-)

```shell
oc create -f openshift/is.certmonger.yaml
oc create -f openshift/buildcfg.certmongerDocker.yaml
```

#### Start the build

In case the creation of the BuildConfig object did not already start a build, or in case you need to start a new build once changing the Dockerfile, do it as follows:

```shell
oc start-build certmonger
```

### Create Service Account

We create a Service Account to run the Job Pod for route creation.

```shell
oc create -f openshift/sa.certMongerJob.yaml
```

### Create Role Binding for Service Account

The Service Account needs to get a role binding to obtain the required permissions.

Import the yaml using 

```shell
oc create -f openshift/crb.certmongerJob.yaml
```

> Note: For simplicity, we use the 'ClusterAdmin' role. It would be a better solution to create a custom role definition having only the required permissions for the Service Account. However, as the pruning jobs anyway run in a namespace owned by a platform team and thus 'ClusterAdmin' enabled users, using 'cluster-admin' role is acceptable.
>
> TODO: use a separate role which only has cluster-wide access to Routes and other required artefacts in the application namespaces.

### Add SCC

The job needs to run with a fixed user id, hence add the service account to 'anyuid' SCC.

```shell
oc adm policy add-scc-to-user anyuid -z certmonger-job-sa -n certificate-tool
```

### Deploy Certificate Tool

#### Create ConfigMaps

##### ConfigMaps holding Corporate Root CA

Unless the example for self-signed certificates is used, the Job requesting the certificate requires to have 
the corporate root CA (public key part) to be part of the container's trust store.

We use a Secret to hold the root CA and mount this Secret into the Job pod.

```shell
oc create secret generic ca-secret --from-file=ca.crt=/path/to/ca.crt
```

When using the self-signed example simply create a secret with a dummy value, as the secret is not used, for example:

```shell
oc create secret generic ca-secret --from-literal=ca.crt=dummy
```


##### ConfigMaps holding scripts

We use a ConfigMap to hold the script code executed by the Job and the CronJob.

* Use CertMonger to request a certificate from the PKI.
* Use 'oc' to create the route object.

> Note: *noproxy settings*
>
> The scripts - depending on environment - may need 'noproxy' settings for successful communication to OpenShift API Server or PKI. Please adjust the 'noproxy' settings in the script accordingly.

> Note: *Using PKI instead of selfsigned certificates.*
>
> The 'runJob.sh' script is creating self-signed certificates and acts as an example which can run in any OpenShift environment, irrespective of a specific PKI/SCEP server being used. The 'podscripts' directory contains an alternate 'runJob_scep-example.sh' script which provides the example of accessing a SCEP server.

```shell
oc create cm route-creation-script --from-file=runJob.sh=./podscripts/runJob.sh
oc create cm cronjob-process-script --from-file=cronProcess.sh=./podscripts/cronProcess.sh
```

#### Create CronJob

Create the CronJob to monitor the created requests and execute the certificate/route creation jobs.

> Please adjust the schedule of the CronJob. Example runs every 2 minutes.

```shell
oc create -f openshift/cronJob.certmonger.yaml
```

#### (optional/debug) Instantiate Job using template

The provided template runs a Job which

* accesses the PKI using 'certmonger' tool to retrieve a certificate
* creates a route using the certificate in a target namespace

See the template definition for the mandatory and optional parameters.

Sample execution:

```shell
oc process -f openshift/template.job.certmonger.yaml -p TOOL_NAMESPACE=certificate-tool -p SERVICENAME=httpd-example -p PORT=8080 -p ROUTENAME=myhttp -p ROUTETYPE=edge -p TARGET_NAMESPACE=example-ns -p HOSTNAME=bla.example.com | oc create -f -
```

or using 'oc new-app' respectively.
You however will not have to run this manually, as the CronJob processing the requests will take over this task to instantiate the required Job for processing the request.

# Usage by Application

## Allow user to use 

Add the user 'exampleusername' to the role in tool namespace:

```shell
oc adm policy add-role-to-user job-initiator-role exampleusername --role-namespace=certificate-tool -n certificate-tool
```

## Usage

Use the WebUI "Developer Perspective >> Add >> From Catalog", filter on "Other" and "Template" and choose the template 'Route Creation Request Template'.

Fill in the parameters as described.

Or use the following command line:
* example given for a Http Server
  * in namespace 'example-ns'
  * service name 'httpd'
  * and port '8080'
* route and certificate to be created for
  * hostname myhttpd.example.com

```shell
oc new-app routecreation-request-template -p TOOL_NAMESPACE=certificate-tool -p SERVICENAME=httpd -p PORT=8080 -p ROUTENAME=myhttp -p ROUTETYPE=edge -p TARGET_NAMESPACE=example-ns -p HOSTNAME=myhttpd.example.com
```
# TODO

* load template into OCP
* role to access the tools-namespace by all-authenticated-users to allow execution of the template (but only list tempalte and instantiate it)

# Technical Information

* Custom role to allow creation of ConfigMap in namespace where certmonger job runs
    * Name pattern: route-task-uuid
    * namespace: Certmonger-NS
        * contents: the target namespace and a uuid
    * namespace: target-NS
        * parameters for the route creation as key-value pairs
* CronJob to processs route creation according to discovered ConfigMaps of above name pattern
    * process the certificate and route creation
    * remove config map afterwards

