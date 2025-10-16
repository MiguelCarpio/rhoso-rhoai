#!/bin/bash

set -e

EDPM_CPUS="${EDPM_CPUS:-40}"
EDPM_RAM="${EDPM_RAM:-160}"
EDPM_RAM_MB=$((${EDPM_RAM} * 1024))
EDPM_DISK="${EDPM_DISK:-640}"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-public}"
OPENSTACK_FLAVOR="${OPENSTACK_FLAVOR:-master}"
OPENSTACK_WORKER_FLAVOR="${OPENSTACK_WORKER_FLAVOR:-worker}"
OPENSTACK_WORKER_GPU_FLAVOR="${OPENSTACK_WORKER_GPU_FLAVOR:-worker_gpu}"

export OS_CLOUD="${OS_CLOUD:-default}"

echo ""
echo "========================================="
echo "  OpenStack Prerequisites Setup"
echo "========================================="
echo ""

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
        echo "[1/5] Getting OpenStack credentials from CRC/RHOSO..."

        eval $(crc oc-env)
        oc login -u kubeadmin -p 12345678 https://api.crc.testing:6443

        [ ! -d ~/.config/openstack/ ] && mkdir -p ~/.config/openstack/
        oc cp -n openstack openstackclient:.config/openstack/clouds.yaml ~/.config/openstack/clouds.yaml
        oc cp -n openstack openstackclient:.config/openstack/secure.yaml ~/.config/openstack/secure.yaml

        oc get secret rootca-public -n openstack -o json | jq -r '.data."ca.crt"' | base64 -d > ~/.config/openstack/rhoso.crt
        CERT_PATH=$(realpath ~/.config/openstack/rhoso.crt)
        yq eval ".clouds.default |= ({\"cacert\": \"${CERT_PATH}\"} + .)" -i ~/.config/openstack/clouds.yaml
        echo "  ✓ OpenStack credentials configured"
        echo ""
    else
        echo "[1/5] Using provided cloud (OS_CLOUD=${OS_CLOUD})..."
        echo "  ✓ Skipping credential setup"
        echo ""
    fi
}

# Setup networks
setup_networks() {
    echo "[2/5] Setting up OpenStack networks..."

    # Setup external network based on cloud type
    if [ "${OS_CLOUD}" != "default" ]; then
        echo "Validating external network '${OPENSTACK_EXTERNAL_NETWORK}' exists..."
        openstack network show "${OPENSTACK_EXTERNAL_NETWORK}" -c id -c name -c mtu -c provider:network_type -c provider:physical_network -c router:external -c subnets || {
            echo "  ✗ External network '${OPENSTACK_EXTERNAL_NETWORK}' does not exist"
            echo "     Please create it or set OPENSTACK_EXTERNAL_NETWORK to an existing network."
            exit 1
        }
        echo "  ✓ External network validated"
        echo ""
    else
        openstack network show "${OPENSTACK_EXTERNAL_NETWORK}" -c id -c name -c mtu -c provider:network_type -c provider:physical_network -c router:external -c subnets || \
            openstack network create "${OPENSTACK_EXTERNAL_NETWORK}" \
            --external \
            --provider-network-type flat \
            --provider-physical-network datacentre \
            -c id -c name -c mtu -c provider:network_type -c provider:physical_network -c router:external -c subnets

        # Create subnet for external network
        local subnet_name="${OPENSTACK_EXTERNAL_NETWORK}_subnet"
        openstack subnet show "${subnet_name}" -c id -c name -c cidr -c allocation_pools -c gateway_ip -c network_id || \
            openstack subnet create "${subnet_name}" \
            --subnet-range 192.168.122.0/24 \
            --allocation-pool start=192.168.122.171,end=192.168.122.250 \
            --gateway 192.168.122.1 \
            --dhcp \
            --network "${OPENSTACK_EXTERNAL_NETWORK}" \
            -c id -c name -c cidr -c allocation_pools -c gateway_ip -c network_id

        echo "  ✓ External network and subnet configured"
        echo ""
    fi
}

# Setup security groups
setup_security_groups() {
    echo "[3/5] Configuring security groups..."

    openstack security group show allow-ssh -c id -c name -c description || {
        openstack security group create allow-ssh -c id -c name -c description
        openstack security group rule create allow-ssh --protocol tcp --ingress --dst-port 22
    }
    echo ""
    openstack security group rule list allow-ssh -c Direction -c Ethertype -c "IP Protocol" -c "Port Range" -c "Remote IP Prefix"
    echo "  ✓ Security group 'allow-ssh' configured"
    echo ""
}

# Setup flavors
setup_flavors() {
    echo "[4/5] Creating OpenStack flavors..."

    openstack flavor show "${OPENSTACK_FLAVOR}" -c id -c name -c vcpus -c ram -c disk -c "OS-FLV-EXT-DATA:ephemeral" -c properties || \
        openstack flavor create --vcpu 4 --ram 16384 --disk 40 --ephemeral 10 "${OPENSTACK_FLAVOR}" \
        -c id -c name -c vcpus -c ram -c disk -c "OS-FLV-EXT-DATA:ephemeral" -c properties

    openstack flavor show "${OPENSTACK_WORKER_FLAVOR}" -c id -c name -c vcpus -c ram -c disk -c "OS-FLV-EXT-DATA:ephemeral" -c properties || \
        openstack flavor create --vcpu 8 --ram 32768 --disk 40 --ephemeral 10 "${OPENSTACK_WORKER_FLAVOR}" \
        -c id -c name -c vcpus -c ram -c disk -c "OS-FLV-EXT-DATA:ephemeral" -c properties

    openstack flavor show "${OPENSTACK_WORKER_GPU_FLAVOR}" -c id -c name -c vcpus -c ram -c disk -c "OS-FLV-EXT-DATA:ephemeral" -c properties || \
        openstack flavor create --vcpu 16 --ram 65536 --disk 100 --ephemeral 10 "${OPENSTACK_WORKER_GPU_FLAVOR}" \
            --property "pci_passthrough:alias"="nvidia:1" \
            --property "hw:pci_numa_affinity_policy=preferred" \
            --property "hw:hide_hypervisor_id"=true \
        -c id -c name -c vcpus -c ram -c disk -c "OS-FLV-EXT-DATA:ephemeral" -c properties
    echo "  ✓ Flavors created: ${OPENSTACK_FLAVOR}, ${OPENSTACK_WORKER_FLAVOR}, ${OPENSTACK_WORKER_GPU_FLAVOR}"
    echo ""
}

# Setup quotas
setup_quotas() {
    echo "[5/5] Setting project quotas..."

    openstack quota set --cores "${EDPM_CPUS}" || true
    openstack quota set --ram "${EDPM_RAM_MB}" || true
    openstack quota set --gigabytes "${EDPM_DISK}" || true
    echo "  ✓ Quotas configured (CPUs: ${EDPM_CPUS}, RAM: ${EDPM_RAM}GB, Disk: ${EDPM_DISK}GB)"
    echo ""
}

install_openstack_cli
setup_credentials
setup_networks
setup_security_groups
setup_flavors
setup_quotas

echo "========================================="
echo "  OpenStack Prerequisites Complete"
echo "========================================="
echo ""
