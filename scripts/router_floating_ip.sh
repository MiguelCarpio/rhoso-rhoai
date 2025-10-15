#!/bin/bash

set -ex

CLUSTER_NAME="${CLUSTER_NAME:-rhoai}"
OPENSHIFT_CLIENT="${OPENSHIFT_CLIENT:-$(which oc)}"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-public}"

export OS_CLOUD=${OS_CLOUD:-default}
export KUBECONFIG="../clusters/${CLUSTER_NAME}/auth/kubeconfig"

ROUTER_WORKER=$(${OPENSHIFT_CLIENT} get pods -n openshift-ingress -o jsonpath='{.items[0].spec.nodeName}')

# Get the server's port and then find the floating IP attached to it
SERVER_PORT=$(openstack port list --server "${ROUTER_WORKER}" -f value -c ID)
ROUTER_FLOATINGIP=$(openstack floating ip list --port "${SERVER_PORT}" -f value -c "Floating IP Address")

if [ -n "${ROUTER_FLOATINGIP}" ]; then
    echo "The OpenShift Ingress Router Default runs in ${ROUTER_WORKER} node which already has the floating IP ${ROUTER_FLOATINGIP}"
    exit 0
fi

echo "Creating a Floating IP for the ${ROUTER_WORKER} node that hosts the Openshift Ingress Router Default"

ROUTER_FLOATINGIP=$(openstack floating ip create "${OPENSTACK_EXTERNAL_NETWORK}" --description "${CLUSTER_NAME}-router-default" --format value --column floating_ip_address)

echo "Adding the Floating IP ${ROUTER_FLOATINGIP} to ${ROUTER_WORKER}"
openstack server add floating ip "${ROUTER_WORKER}" "${ROUTER_FLOATINGIP}"
