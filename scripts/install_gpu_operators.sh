#!/bin/bash

set -e

CLUSTER_NAME="${CLUSTER_NAME:-rhoai}"
OPENSHIFT_CLIENT="${OPENSHIFT_CLIENT:-$(which oc)}"

export KUBECONFIG=../clusters/${CLUSTER_NAME}/auth/kubeconfig

echo ""
echo "========================================="
echo "  GPU Operators Installation"
echo "========================================="
echo ""

# Checking the cluster health
echo "[1/8] Checking cluster health..."
if ! ${OPENSHIFT_CLIENT} get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -E -q 'Available=True.*Progressing=False|Progressing=False.*Available=True'; then
  echo "  ✗ Cluster is DEGRADED or UPDATING (Check 'oc get clusterversion')"
  exit 1
fi
echo "  ✓ Cluster is healthy"
echo ""

echo "[2/8] Deploying NFD (Node Feature Discovery) Operator..."

${OPENSHIFT_CLIENT} create namespace openshift-nfd || true

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operatorgroup
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
EOF

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
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

echo ""

echo "[3/8] Waiting for NFD Operator deployment (timeout: 5m)..."
sleep 120
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=5m deployment/nfd-controller-manager -n openshift-nfd
echo ""

echo "[4/8] Creating NFD instance..."
cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec: {}
EOF

echo ""

echo "[5/8] Waiting for NFD pods to be ready (timeout: 5m)..."
sleep 30
${OPENSHIFT_CLIENT} wait pod --all --for=condition=Ready -n openshift-nfd --timeout=5m
${OPENSHIFT_CLIENT} rollout status daemonset/nfd-worker -n openshift-nfd --watch --timeout=5m
echo ""

echo "[6/8] Deploying NVIDIA GPU Operator..."

${OPENSHIFT_CLIENT} create namespace nvidia-gpu-operator || true

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

NVIDIA_CHANNEL=`${OPENSHIFT_CLIENT} get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'`

NVIDIA_STARTINGCSV=`${OPENSHIFT_CLIENT} get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.channels[?(@.name=="'"${NVIDIA_CHANNEL}"'")].currentCSV}{"\n"}'`

cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
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

echo "  ✓ NVIDIA GPU Operator subscription created (channel: ${NVIDIA_CHANNEL})"
echo ""

echo "[7/8] Waiting for NVIDIA GPU Operator to be ready (timeout: 5m)..."
sleep 30
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=5m deployment/gpu-operator -n nvidia-gpu-operator
${OPENSHIFT_CLIENT} wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m csv -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator -n nvidia-gpu-operator
echo ""

echo "[8/8] Configuring GPU ClusterPolicy and verifying installation..."
cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
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

echo ""
echo "  ⏳ Waiting for ClusterPolicy to be ready (timeout: 30m, this may take a while)..."
${OPENSHIFT_CLIENT} wait ClusterPolicy gpu-cluster-policy  -n nvidia-gpu-operator --for condition=Ready=True --timeout=30m
echo "  ✓ GPU ClusterPolicy is ready"
echo ""

echo "Verifying the GPU operator labelled the worker node"
${OPENSHIFT_CLIENT} get node -l nvidia.com/gpu.present -oname
GPU_NODE=$(${OPENSHIFT_CLIENT} get node -l nvidia.com/gpu.present -o jsonpath='{.items[0].metadata.name}')
if [ -z "$GPU_NODE" ]; then
  echo "  ✗ No GPU-labeled nodes found"
  exit 1
fi
echo "  ✓ GPU node labeled: ${GPU_NODE}"
echo ""

echo "Creating a GPU operator verification job"
cat << EOF | ${OPENSHIFT_CLIENT} apply -f -
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

${OPENSHIFT_CLIENT} wait --for=condition=complete job/verify-cuda-vectoradd -n nvidia-gpu-operator --timeout=15m

echo "CUDA verification job output:"
CUDA_OUTPUT=$(${OPENSHIFT_CLIENT} logs job/verify-cuda-vectoradd -n nvidia-gpu-operator)
echo ""
if echo "$CUDA_OUTPUT" | grep -q "Test PASSED"; then
  echo "  ✓ CUDA verification test PASSED"
else
  echo "  ✗ CUDA verification test FAILED"
  exit 1
fi

${OPENSHIFT_CLIENT} delete job/verify-cuda-vectoradd -n nvidia-gpu-operator
echo ""

echo "========================================="
echo "  GPU Operators Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  • NFD Operator: Installed and operational"
echo "  • NVIDIA GPU Operator: Installed (${NVIDIA_CHANNEL})"
echo "  • GPU Worker Node: ${GPU_NODE}"
echo "  • CUDA Verification: Passed"
echo ""
