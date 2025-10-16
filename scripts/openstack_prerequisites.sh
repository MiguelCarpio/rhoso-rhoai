#!/bin/bash

set -ex

EDPM_CPUS="${EDPM_CPUS:-40}"
EDPM_RAM="${EDPM_RAM:-160}"
EDPM_RAM_MB=$((${EDPM_RAM} * 1024))
EDPM_DISK="${EDPM_DISK:-640}"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-public}"
OPENSTACK_FLAVOR="${OPENSTACK_FLAVOR:-master}"
OPENSTACK_WORKER_FLAVOR="${OPENSTACK_WORKER_FLAVOR:-worker}"
OPENSTACK_WORKER_GPU_FLAVOR="${OPENSTACK_WORKER_GPU_FLAVOR:-worker_gpu}"

export OS_CLOUD="${OS_CLOUD:-default}"

# Install OpenStack CLI if not present
install_openstack_cli() {
    if ! which openstack > /dev/null 2>&1; then
        echo "openstack command not found, installing python-openstackclient..."
        sudo dnf -y install python3-pip
        pip3 install python-openstackclient
    fi
}

# Setup OpenStack credentials from CRC/RHOSO
setup_credentials() {
    if [ "${OS_CLOUD}" = "default" ]; then
        echo "Getting the OpenStack Credentials from the CRC OCP OpenStack namespace"

        eval $(crc oc-env)
        oc login -u kubeadmin -p 12345678 https://api.crc.testing:6443

        [ ! -d ~/.config/openstack/ ] && mkdir -p ~/.config/openstack/
        oc cp -n openstack openstackclient:.config/openstack/clouds.yaml ~/.config/openstack/clouds.yaml
        oc cp -n openstack openstackclient:.config/openstack/secure.yaml ~/.config/openstack/secure.yaml

        oc get secret rootca-public -n openstack -o json | jq -r '.data."ca.crt"' | base64 -d > ~/.config/openstack/rhoso.crt
        CERT_PATH=$(realpath ~/.config/openstack/rhoso.crt)
        yq eval ".clouds.default |= ({\"cacert\": \"${CERT_PATH}\"} + .)" -i ~/.config/openstack/clouds.yaml
    else
        echo "Using provided cloud (OS_CLOUD=${OS_CLOUD}) - skipping credential setup"
    fi
}

# Setup networks
setup_networks() {
    echo "Creating the Networks and Security Groups"

    # Setup external network based on cloud type
    if [ "${OS_CLOUD}" != "default" ]; then
        echo "Using provided cloud (OS_CLOUD=${OS_CLOUD}) - validating external network exists..."
        openstack network show "${OPENSTACK_EXTERNAL_NETWORK}" || {
            echo "ERROR: External network '${OPENSTACK_EXTERNAL_NETWORK}' does not exist in provided cloud."
            echo "Please create it or set OPENSTACK_EXTERNAL_NETWORK to an existing network."
            exit 1
        }
    else
        echo "Setting up external network for CRC/RHOSO deployment..."
        openstack network show "${OPENSTACK_EXTERNAL_NETWORK}" || \
            openstack network create "${OPENSTACK_EXTERNAL_NETWORK}" \
            --external \
            --provider-network-type flat \
            --provider-physical-network datacentre

        # Create subnet for external network
        local subnet_name="${OPENSTACK_EXTERNAL_NETWORK}_subnet"
        openstack subnet show "${subnet_name}" || \
            openstack subnet create "${subnet_name}" \
            --subnet-range 192.168.122.0/24 \
            --allocation-pool start=192.168.122.171,end=192.168.122.250 \
            --gateway 192.168.122.1 \
            --dhcp \
            --network "${OPENSTACK_EXTERNAL_NETWORK}"
    fi
}

# Setup security groups
setup_security_groups() {
    echo "Creating security groups"

    openstack security group show allow-ssh || {
        openstack security group create allow-ssh
        openstack security group rule create allow-ssh --protocol tcp --ingress --dst-port 22
    }
}

# Setup flavors
setup_flavors() {
    echo "Creating the Master and GPU Worker flavors"

    openstack flavor show "${OPENSTACK_FLAVOR}" || \
        openstack flavor create --vcpu 4 --ram 16384 --disk 40 --ephemeral 10 "${OPENSTACK_FLAVOR}"

    openstack flavor show "${OPENSTACK_WORKER_FLAVOR}" || \
        openstack flavor create --vcpu 8 --ram 32768 --disk 40 --ephemeral 10 "${OPENSTACK_WORKER_FLAVOR}"

    openstack flavor show "${OPENSTACK_WORKER_GPU_FLAVOR}" || \
        openstack flavor create --vcpu 16 --ram 65536 --disk 100 --ephemeral 10 "${OPENSTACK_WORKER_GPU_FLAVOR}" \
            --property "pci_passthrough:alias"="nvidia:1" \
            --property "hw:pci_numa_affinity_policy=preferred" \
            --property "hw:hide_hypervisor_id"=true
}

# Setup quotas
setup_quotas() {
    echo "Setting the Project Quotas"

    openstack quota set --cores "${EDPM_CPUS}" || true
    openstack quota set --ram "${EDPM_RAM_MB}" || true
    openstack quota set --gigabytes "${EDPM_DISK}" || true
}

install_openstack_cli
setup_credentials
setup_networks
setup_security_groups
setup_flavors
setup_quotas
echo "OpenStack prerequisites setup completed successfully!"
