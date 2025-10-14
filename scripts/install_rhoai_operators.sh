#!/bin/bash

set -ex

CLUSTER_NAME=$1
OPENSHIFT_CLIENT=$2
export KUBECONFIG=../clusters/${CLUSTER_NAME}/auth/kubeconfig

# Checking the cluster health
if ! ${OPENSHIFT_CLIENT} get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -E -q 'Available=True.*Progressing=False|Progressing=False.*Available=True'; then
  echo "Cluster is DEGRADED or UPDATING (Check '${OPENSHIFT_CLIENT} get clusterversion')"
  exit 1
fi

echo "Deploying the Servicemesh Operator"

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for Servicemesh Operator to be ready..."
sleep 30
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=5m deployment.apps/istio-operator -n openshift-operators

echo "Deploying the Serverless Operator"

${OPENSHIFT_CLIENT} create namespace openshift-serverless || true

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
EOF

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for OpenShift Serverless Operator to be ready..."
sleep 30
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=5m deployment/knative-openshift -n openshift-serverless

echo "Deploying the Authorino Operator"

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: authorino-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: authorino-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Deploying the Red Hat OpenShift AI Operator"

${OPENSHIFT_CLIENT} create namespace redhat-ods-operator || true

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-operators
  namespace: redhat-ods-operator
EOF

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for RHOAI Operator to be ready..."
sleep 30
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=10m deployment/rhods-operator -n redhat-ods-operator

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Managed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    feastoperator:
      managementState: Removed
    kserve:
      managementState: Managed
      nim:
        managementState: Managed
      rawDeploymentServiceConfig: Headless
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Managed
        name: knative-serving
    kueue:
      managementState: Managed
    llamastackoperator: {}
    modelmeshserving:
      managementState: Managed
    modelregistry:
      managementState: Removed
      registriesNamespace: rhoai-model-registries
    ray:
      managementState: Managed
    trainingoperator:
      managementState: Managed
    trustyai:
      managementState: Managed
    workbenches:
      managementState: Managed
      workbenchNamespace: rhods-notebooks
EOF

echo "Waiting for DataScience Cluster to be ready..."
sleep 30
${OPENSHIFT_CLIENT} wait --timeout=10m DataScienceCluster default-dsc --for jsonpath='{.status.phase}'=Ready

echo "Go to the RHOAI dashboard URL"
${OPENSHIFT_CLIENT} get route -n redhat-ods-applications
RHOAI_HOST=`${OPENSHIFT_CLIENT} get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.host}'`
echo "Access the RHOAI dashboard https://${RHOAI_HOST}"
