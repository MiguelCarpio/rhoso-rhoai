#!/bin/bash

set -ex

CLUSTER_NAME=$1
GPU_MACHINESET=new-gpu-machineset.yaml
export KUBECONFIG=../clusters/${CLUSTER_NAME}/auth/kubeconfig

# Checking the cluster health
if ! oc get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -E -q 'Available=True.*Progressing=False|Progressing=False.*Available=True'; then
  echo "Cluster is DEGRADED or UPDATING (Check 'oc get clusterversion')"
  exit 1
fi

MACHINESET_NAME=$(oc get machinesets -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker -o jsonpath='{.items[0].metadata.name}')
oc get machinesets ${MACHINESET_NAME} -n openshift-machine-api -o yaml > ${GPU_MACHINESET}
sed -i "s|${MACHINESET_NAME}|${MACHINESET_NAME%0}1|g" ${GPU_MACHINESET}
sed -i "/flavor/ s/: .*/: worker_gpu/" ${GPU_MACHINESET}

oc create -f ${GPU_MACHINESET}

echo "Waiting for the worker gpu node to be ready"
oc wait machinesets/${MACHINESET_NAME%0}1 -n openshift-machine-api --for=jsonpath='{.status.availableReplicas}'=1 --timeout=40m

echo "Verifying that the GPU card is present on the worker"
WORKER_GPU_NAME=$(oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=${MACHINESET_NAME%0}1 -o jsonpath='{.items[0].metadata.name}')
echo "Checking GPU on node: ${WORKER_GPU_NAME}"
oc debug node/${WORKER_GPU_NAME} -- bash -c 'chroot /host lspci | grep NVIDIA' || { echo "The GPU card is not present on the ${WORKER_GPU_NAME} worker node"; exit 1; }
