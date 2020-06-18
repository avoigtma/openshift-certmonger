# OCP Route Creation with TLS Certificates derived from a PKI using SCEP

This document describes an approach how to create Route objects in OpenShift which use custom certificates. The certificates are obtained from a PKI using SCEP API. We use the 'certmonger' tool running in a Pod on OpenShift to request the certificates from the PKI using SCEP protocol. The pod afterwards creates a Route object in a target namespace having the requested certificated configured.

> Open items:
> 
> * update of the certificates (as of now, need to delete and re-create the route)
> * replace template-based approach using an Operator
> * custom role for executing the job (instead of cluster-admin)
> * ...
> 

Base repository link for all artefacts referenced in the following description: <https://github.com/avoigtma/openshift-certmonger>

>> In the remainder of the documents, all commands are executed in the 'certmonger-job' repository directory of the source repository.

## Create Namespace

Create a namespace for hosting the 'certmonger' tool.

We use a namespace called 'cluster-operations' which may host any kind of operation-support tools for the platform. But any other namespace can be used as well. Please note you need to adjust the Yaml files respectively.

```
oc new-project cluster-operations
```

or use

```
oc create -f openshift/namespace.clusterOps.yaml
```



## Import Base Image

Run the following as cluster admin, as we want to import into openshift namespace.

```
oc import-image centos --from=registry.centos.org/centos:centos8 -n openshift --confirm
```


## Build Dockerfile

We create our own tool image from a Dockerfile. The image includes both 'certmonger' and the 'oc' client.

### Create new build (and target image stream)

> Note: we create a new build config using 'oc new-build', delete the bc afterwards and (re-)create our own build config. This is just a simple 'workaround-style' approach to create the imagestream required as the target of the build :-)

```
oc create -f openshift/is.certmonger.yaml
oc create -f openshift/buildcfg.certmongerDocker.yaml
```

### Start the build

In case the creation of the BuildConfig object did not already start a build, or in case you need to start a new build once changing the Dockerfile, do it as follows:

```
oc start-build certmonger
```

## Create Service Account

We create a Service Account to run the Job Pod for route creation.

### using command line
```
oc create sa certmonger-job-sa
```

### using yaml

Run

```
oc create -f openshift/sa.certMongerJob.yaml
```

## Create Role Binding for Service Account

The Service Account needs to get a role binding to obtain the required permissions.

Import the yaml using 

```
oc create -f openshift/crb.certmongerJob.yaml
```


> TODO: use a separate role which only has cluster-wide access to Routes

> Note: For simplicity, we use the 'ClusterAdmin' role. It would be a better solution to create a custom role definition having only the required permissions for the Service Account. However, as the pruning jobs anyway run in a namespace owned by a platform team and thus 'ClusterAdmin' enabled users, using 'cluster-admin' role is acceptable.


## Add SCC

The job needs to run with a fixed user id, hence add the service account to 'anyuid' SCC.

```
oc adm policy add-scc-to-user anyuid -z certmonger-job-sa -n cluster-operations
```

## Deploy

### Create ConfigMap 

We use a ConfigMap to hold the script code executed by the Job.

* Use CertMonger to request a certificate from the PKI.
* Use 'oc' to create the route object.

```
oc create cm route-creation-script --from-file=runJob.sh=./podscripts/runJob.sh
```


### Instantiate Job using template

The provided template runs a Job which

* accesses the PKI using 'certmonger' tool to retrieve a certificate
* creates a route using the certificate in a target namespace

See the template definition for the mandatory and optional parameters.

Sample execution:

```
oc process -f openshift/template.job.certmonger.yaml -p TOOL_NAMESPACE=cluster-operations -p SERVICENAME=httpd-example -p PORT=8080 -p ROUTENAME=myhttp -p TARGET_NAMESPACE=example-ns -p HOSTNAME=bla.example.com | oc create -f -

```

# TODO

* load template into OCP
* role to access the tools-namespace by all-authenticated-users to allow execution of the template (but only list tempalte and instantiate it)





