#!/bin/bash

set -e

CLUSTER_NAME="${CLUSTER_NAME:-rhoai}"
OPENSHIFT_CLIENT="${OPENSHIFT_CLIENT:-$(which oc)}"
GPU_MACHINESET=new-gpu-machineset.yaml

export KUBECONFIG=../clusters/${CLUSTER_NAME}/auth/kubeconfig

echo "========================================="
echo "  GPU Worker Node Deployment"
echo "========================================="
echo ""

# Checking the cluster health
echo "[1/4] Checking cluster health..."
if ! ${OPENSHIFT_CLIENT} get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -E -q 'Available=True.*Progressing=False|Progressing=False.*Available=True'; then
  echo "  ✗ Cluster is DEGRADED or UPDATING (Check 'oc get clusterversion')"
  exit 1
fi
echo "  ✓ Cluster is healthy"
echo ""

# Create GPU MachineSet
echo "[2/4] Creating GPU worker MachineSet..."
MACHINESET_NAME=$(${OPENSHIFT_CLIENT} get machinesets -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker -o jsonpath='{.items[0].metadata.name}')
GPU_MACHINESET_NAME="${MACHINESET_NAME%0}1"

${OPENSHIFT_CLIENT} get machinesets ${MACHINESET_NAME} -n openshift-machine-api -o yaml > ${GPU_MACHINESET}
sed -i "s|${MACHINESET_NAME}|${GPU_MACHINESET_NAME}|g" "${GPU_MACHINESET}"
sed -i "/flavor/ s/: .*/: worker_gpu/" "${GPU_MACHINESET}"

${OPENSHIFT_CLIENT} apply -f "${GPU_MACHINESET}"
echo "  ✓ MachineSet '${GPU_MACHINESET_NAME}' created"
echo ""

# Wait for worker node
echo "[3/4] Waiting for GPU worker node to become ready (timeout: 40m)..."
${OPENSHIFT_CLIENT} wait machinesets/${GPU_MACHINESET_NAME} -n openshift-machine-api --for=jsonpath='{.status.availableReplicas}'=1 --timeout=40m
WORKER_GPU_NAME=$(${OPENSHIFT_CLIENT} get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=${GPU_MACHINESET_NAME} -o jsonpath='{.items[0].metadata.name}')
echo "  ✓ Worker node '${WORKER_GPU_NAME}' is ready"
echo ""

# Verify GPU
echo "[4/4] Verifying GPU hardware..."
echo "Checking GPU on node: ${WORKER_GPU_NAME}"
GPU_INFO=$(${OPENSHIFT_CLIENT} debug node/${WORKER_GPU_NAME} -- bash -c 'chroot /host lspci | grep NVIDIA' 2>&1 | tee /dev/tty | grep -v "Starting pod\|To use host\|Removing debug pod" | grep NVIDIA)
if [ -z "$GPU_INFO" ]; then
  echo "  ✗ GPU card not detected on worker node '${WORKER_GPU_NAME}'"
  exit 1
fi
echo "  ✓ GPU detected: ${GPU_INFO}"
echo ""

rm -f ${GPU_MACHINESET}

echo "========================================="
echo "  GPU Worker Node Deployment Complete"
echo "========================================="
