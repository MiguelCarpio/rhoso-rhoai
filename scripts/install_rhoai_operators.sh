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

tee servicemesh-operator.yaml << EOF
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

${OPENSHIFT_CLIENT} apply -f servicemesh-operator.yaml

echo "Waiting for Servicemesh Operator to be ready..."
sleep 10
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=5m deployment.apps/istio-operator -n openshift-operators

echo "Deploying the Serverless Operator"

${OPENSHIFT_CLIENT} create namespace openshift-serverless || true

tee serverless-operator-group.yaml << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
EOF

${OPENSHIFT_CLIENT} apply -f serverless-operator-group.yaml

tee serverless-operator.yaml << EOF
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

${OPENSHIFT_CLIENT} apply -f serverless-operator.yaml

echo "Waiting for OpenShift Serverless Operator to be ready..."
sleep 10
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=5m deployment/knative-openshift -n openshift-serverless

echo "Deploying the Red Hat OpenShift AI Operator"

${OPENSHIFT_CLIENT} create namespace redhat-ods-operator || true

tee rhods-operator-group.yaml << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-operators
  namespace: redhat-ods-operator
EOF

${OPENSHIFT_CLIENT} apply -f rhods-operator-group.yaml

tee rhods-operator.yaml << EOF
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

${OPENSHIFT_CLIENT} apply -f rhods-operator.yaml

echo "Waiting for RHOAI Operator to be ready..."
sleep 10
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=10m deployment/rhods-operator -n redhat-ods-operator

tee default-dsc.yaml << EOF
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

${OPENSHIFT_CLIENT} apply -f default-dsc.yaml

echo "Waiting for DataScience Cluster to be ready..."
sleep 10
${OPENSHIFT_CLIENT} wait --timeout=10m DataScienceCluster default-dsc --for jsonpath='{.status.phase}'=Ready

echo "Go to the RHOAI dashboard URL"
${OPENSHIFT_CLIENT} get route -n redhat-ods-applications
RHOAI_HOST=`${OPENSHIFT_CLIENT} get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.host}'`
RHOAI_PORT=`${OPENSHIFT_CLIENT} get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.port.targetPort}'`
echo "Access the RHOAI dashboard https://${RHOAI_HOST}:${RHOAI_PORT}"
