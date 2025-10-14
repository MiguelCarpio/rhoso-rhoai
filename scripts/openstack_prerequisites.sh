#!/bin/bash

set -ex

EDPM_CPUS="${EDPM_CPUS:-40}"
EDPM_RAM="${EDPM_RAM:-160}"
EDPM_RAM_MB=$((${EDPM_RAM} * 1024))
EDPM_DISK=${EDPM_DISK:-640}

if ! which openstack > /dev/null 2>&1; then
    echo "openstack command not found, installing python-openstackclient..."
    sudo dnf -y install pip
    pip install python-openstackclient
fi

echo "Getting the OpenStack Credentials"

eval $(crc oc-env)
oc login -u kubeadmin -p 12345678 https://api.crc.testing:6443

[ ! -d ~/.config/openstack/ ] && mkdir -p ~/.config/openstack/
oc cp -n openstack openstackclient:.config/openstack/clouds.yaml ~/.config/openstack/clouds.yaml
oc cp -n openstack openstackclient:.config/openstack/secure.yaml ~/.config/openstack/secure.yaml

oc get secret rootca-public -n openstack -o json | jq -r '.data."ca.crt"' | base64 -d > ~/.config/openstack/rhoso.crt
CERT_PATH=$(realpath ~/.config/openstack/rhoso.crt)
yq eval ".clouds.default |= ({\"cacert\": \"${CERT_PATH}\"} + .)" -i ~/.config/openstack/clouds.yaml

export OS_CLOUD=default

echo "Listing the OpenStack Endpoints"
openstack endpoint list

echo "Creating the Networks and Security Groups"
openstack network show private || openstack network create private --share
openstack subnet show priv_sub || openstack subnet create priv_sub --subnet-range 192.168.0.0/24 --network private
openstack network show public || openstack network create public --external --provider-network-type flat --provider-physical-network datacentre
openstack subnet show public_subnet || openstack subnet create public_subnet --subnet-range 192.168.122.0/24 --allocation-pool start=192.168.122.171,end=192.168.122.250 --gateway 192.168.122.1 --dhcp --network public
openstack router show priv_router || {
    openstack router create priv_router
    openstack router add subnet priv_router priv_sub
    openstack router set priv_router --external-gateway public
}
openstack security group show allow-ssh || {
    openstack security group create allow-ssh 
    openstack security group rule create allow-ssh  --protocol tcp --ingress --dst-port 22

    openstack security group rule create allow-ssh  --protocol tcp --remote-ip 0.0.0.0/0
}

echo "Creating the Master and GPU Worker flavors"
openstack flavor show master || openstack flavor create --vcpu 4 --ram 16384 --disk 40 --ephemeral 10 master 
openstack flavor show worker || openstack flavor create --vcpu 4 --ram 16384 --disk 40 --ephemeral 10 worker
openstack flavor show worker_gpu || openstack flavor create --vcpu 16 --ram 65536 --disk 100 --ephemeral 10 worker_gpu \
      --property "pci_passthrough:alias"="nvidia:1" \
      --property "hw:pci_numa_affinity_policy=preferred" \
      --property "hw:hide_hypervisor_id"=true

echo "Setting the Project Quotas"
openstack quota set --cores ${EDPM_CPUS}
openstack quota set --ram ${EDPM_RAM_MB}
openstack quota set --gigabytes ${EDPM_DISK}
