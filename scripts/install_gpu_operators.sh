#!/bin/bash

set -ex

CLUSTER_NAME=$1
export KUBECONFIG=../clusters/${CLUSTER_NAME}/auth/kubeconfig

# Checking the cluster health
if ! oc get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -E -q 'Available=True.*Progressing=False|Progressing=False.*Available=True'; then
  echo "Cluster is DEGRADED or UPDATING (Check 'oc get clusterversion')"
  exit 1
fi

echo "Deploying the NFD Operator"

oc create namespace openshift-nfd || true

tee nfd-operatorgroup.yaml << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operatorgroup
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
EOF

oc apply -f nfd-operatorgroup.yaml

tee nfd-subscription.yaml << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd-operator-subscription
  namespace: openshift-nfd
spec:
  channel: "stable"
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f nfd-subscription.yaml

oc wait --for=condition=Available --timeout=5m deployment/nfd-controller-manager -n openshift-nfd

tee nfd-instance.yaml << EOF
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec: {}
EOF

oc apply -f nfd-instance.yaml

sleep 10

oc wait pod --all --for=condition=Ready -n openshift-nfd --timeout=5m

oc rollout status daemonset/nfd-worker -n openshift-nfd --watch --timeout=5m

echo "Deploying the NVIDIA Operator"

oc create namespace nvidia-gpu-operator || true

tee gpu-operator-group.yaml << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

oc apply -f gpu-operator-group.yaml

NVIDIA_CHANNEL=`oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'`

NVIDIA_STARTINGCSV=`oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.channels[?(@.name=="'"${NVIDIA_CHANNEL}"'")].currentCSV}{"\n"}'`

tee nvidia-gpu-operator.yaml << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: ${NVIDIA_CHANNEL}
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ${NVIDIA_STARTINGCSV}
EOF

oc apply -f nvidia-gpu-operator.yaml

sleep 10

echo "Waiting for GPU operator deployment to be available..."
oc wait --for=condition=Available --timeout=5m deployment/gpu-operator -n nvidia-gpu-operator

echo "Waiting for GPU operator CSV to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m csv -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator -n nvidia-gpu-operator

tee gpu-clusterpolicy.yaml << EOF
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  daemonsets: {}
  dcgm: {}
  dcgmExporter: {}
  devicePlugin: {}
  driver: {}
  gfd: {}
  nodeStatusExporter: {}
  operator: {}
  toolkit: {}
EOF

oc apply -f gpu-clusterpolicy.yaml

oc wait ClusterPolicy gpu-cluster-policy  -n nvidia-gpu-operator --for condition=Ready=True --timeout=30m

echo "Verifying the GPU operator labelled the worker node"
oc get node -l nvidia.com/gpu.present -oname

echo "Creating a GPU operator verification job"

tee verify-cuda-vectoradd.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: verify-cuda-vectoradd
  namespace: nvidia-gpu-operator
spec:
  completionMode: NonIndexed
  template:
    metadata:
      labels:
        app: cuda-vectoradd
    spec:
      restartPolicy: OnFailure
      containers:
      - name: cuda-vectoradd
        image: "nvidia/samples:vectoradd-cuda11.2.1"
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

oc apply -f verify-cuda-vectoradd.yaml

oc wait --for=condition=complete job/verify-cuda-vectoradd -n nvidia-gpu-operator --timeout=5m

oc logs job/verify-cuda-vectoradd -n nvidia-gpu-operator
