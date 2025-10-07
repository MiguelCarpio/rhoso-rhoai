# Testing RHOAI on a single machine using nested virtualization

This repository is meant to help deploying a toy RHOSO + RHOAI system on a
single machine.

To deploy on a single machine the OpenStack control plane will run as a single
node OpenStack inside a VM (using CRC) and the EDPM node will also run as a VM
using PCI passthrough to pass the NVIDIA GPU/GPUs to the nova compute service.

Finally RHOAI will be run as OpenShift on OpenStack cluster executing in the EDPM
node.

This is going to have considerable performance issues because of the double
nesting virtualization, qcow2 disks, and PCI passthrough, so this is clearly
not meant for any real usage, just to help confirm that everything works as
intended.

# QuickStart

## Prerequisites

You'll need at least one [NVIDIA GPU supported by RHOAI](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux_ai/1.5/html/hardware_requirements/hardware_requirements_rhelai) and some tools
need to be installed as well the `install_yamls` and this repository. There is
a helper make target for this, although there are some things that you still
need to do:

```bash
sudo dnf -y install git make pciutils pip
git clone https://github.com/rhos-vaf/rhoso-rhoai.git
cd rhoso-rhoai && make prerequisites
```

The `prerequisites` target may fail if you don't have an NVIDIA GPU, if the GPU
is being held by the graphics driver, if IOMMU is not properly configured, etc.

### Setting up the host

We have to enable IOMMU and reserve the PCI devices. These operations change
the booting command line and require generating the new GRUB configuration file
and rebooting the machine, so we recommend following modifying the grub args
for IOMMU and PCI reservation, and the recreate GRUB configuration and finally
rebooting.  That is the order we show below.

#### IOMMU

If we are using an Intel machine, we can enable IOMMU with:

```
sudo grubby --update-kernel ALL --args 'intel_iommu=on iommu=pt'
```

#### Reserve PCI devices

We don't want the nvidia driver to hold our PCI devices, or they won't be
available for PCI passthrough.

There are a couple of ways to do this:

- Blacklist the driver
- Reserve the PCI devices for vfio

We can do one of them or even both  ;-)

##### Blacklist the driver

We need to write `blacklist <driver name>` in file
`/etc/modprobe.d/blacklist.conf`.

Depending on the card it will be a different driver name:

For NVIDIA GPUs:

```
echo -e "blacklist nouveau\nblacklist nvidia*" | sudo tee -a /etc/modprobe.d/blacklist.conf
```

A description on how to do it on some complex blacklisting scenarios can be
found in this [RH KCS article](https://access.redhat.com/solutions/41278).

##### VFIO reservation

So first we find the PCI devices, for example:

```
sudo dnf -y install pciutils
sudo lspci -nn | grep NVIDIA
# 04:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)
```

Now that we see that the device has vendor id `10de` (that's NVIDIA) and
product id `20f1` we can reserve it. Set the `PCI` variable first with the 
respective value, for this example `PCI="10de:20f1"`

```
sudo grubby --update-kernel ALL --args "rd.driver.pre=vfio_pci vfio_pci.ids=${PCI} modules-load=vfio,vfio-pci,vfio_iommu_type1,vfio_pci_vfio_virqfd"
```

Note: If we wanted to reserve multiple PCI devices that have different product
id, we can separate them with a comma: `PCI=10de:20f1,10de:2684`

#### Rebuild GRUB cfg

Now we need to rebuild GRUB configuration file and reboot.

```
sudo grub2-mkconfig -o /etc/grub2.cfg
sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg || sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo shutdown -r now
```

## Deploying RHOSO

Deploying OpenStack on OpenShift has 2 phases: Deploying the control plane and
deploying the edpm node.

To deploy the control plane you'll need a `pull-secret` from
`https://cloud.redhat.com/openshift/create/local`. This file must exist as
`~/pull-secret`, or its location set in the `PULL_SECRET` env var.

The targets for each of these phases:

```bash
make deploy_rhoso_controlplane
make deploy_rhoso_dataplane
```

## Deploying ShiftStack

To deploy OpenShift on RHOSO you'll need the `pull-secret`, the `openshift-install` and the `oc` client. The `pull-secret` file must exist as
`~/pull-secret`, the OpenShift installer and the client must be found in the `$PATH`. However, you can set the `PULL_SECRET` env var with the `pull-secret` location. Regarding the `openshift-install` and `oc`, you can get the installer and client from https://amd64.ocp.releases.ci.openshift.org/, choose a [supported OCP version](https://access.redhat.com/support/policy/updates/rhoai-sm/lifecycle), and set the `OPENSHIFT_INSTALL` and `OPENSHIFT_CLIENT` env vars with the `openshift-install` and `oc` location.

```bash
make deploy_shiftstack
```

ShiftStack deployment needs 3 masters, 1 bootstrap, and at least 1 worker. In this deploy, masters and the bootstrap share the same flavor; the worker must accomplish the [minimum requirements](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.8/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install) for supporting the OpenShift AI Operators. Besides, the worker GPU must accomplish the minimum requirement plus additional cluster resources to ensure that OpenShift AI is usable and supports the accelerated data plane components. Therefore, these are the minimum requirements for deploying RHOAI on RHOSO for development and test purposes. 

<b style="font-weight:normal;" id="docs-internal-guid-a3f90021-7fff-d9b4-408b-558d359f25ef"><div dir="ltr" style="margin-left:0pt;" align="left">
NODE | COUNT | FLAVOR | CPU | RAM
-- | -- | -- | -- | --
master | 3 | master | 12 | 48
bootstrap | 1 | master | 4 | 16
worker | 1 | worker | 8 | 32
worker GPU | 1 | worker_gpu | 16 | 64
TOTAL | | | 40 | 160
</div></b>

> [!NOTE] 
> The Red Hat OpenShift AI (RHOAI) Operators will deploy their management components (controllers, dashboard, core services) on both workers, but they will only deploy the accelerated data plane components (like the NVIDIA stack) on the node with the GPU.

## Deploying Worker GPU Node and GPU Operators

A new MachineSet for the GPU worker is needed to support the accelerated data plane components. To create a worker node with a GPU by PCI passthrough, you'll need a flavor with `pci_passthrough`, `pci_numa_affinity_policy` and `hide_hypervisor_id` properties. The `worker_gpu` flavor is already created by the `deploy_shiftstack` target.

```
make deploy_worker_gpu
```
This target also verifies that the GPU card is present on the GPU worker, deploys the GPU operators, verifies the GPU operator labelled the worker node and creates a GPU operator verification job.

```
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
```
The output of this target should be similar than:
```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

## Deploying RHOAI

OpenShift AI needs the following resources:

- Servicemesh Operator
- Serverless Operator
- Red Hat OpenShift AI Operator
- DataScience Cluster

To deploy RHOAI run the following target:

```
make deploy_rhoai
```

Finally, it shows a message to access the RHOAI dashboard URL. Like this:
`Access the RHOAI dashboard https://rhods-dashboard-redhat-ods-applications.apps.rhoai.shiftstack.test`

> [!IMPORTANT] 
> You must identify the worker where the router resource is allocated, you can use the following command line `oc get pods -n openshift-ingress -o wide`. Then, you can add a floating ip on that worker instance. Finally, update your `/etc/host` and access the OpenShift AI URL. 

# Customization

There should be reasonable defaults, but you can still configuration a number
of things via environmental variables when calling the make targets to customize
the different phases.  This is a non-exhaustive list:

- For RHOSO Control Plane:
  - PULL_SECRET

- For RHOSO Data Plane - EDPM Node:
  - PULL_SECRET
  - EDPM_CPUS
  - EDPM_RAM: In GiB
  - EDPM_DISK

- For ShiftStack
  - PULL_SECRET
  - PROXY_USER
  - PROXY_PASSWORD
  - OPENSHIFT_INSTALL
  - OPENSHIFT_INSTALLCONFIG
  - CLUSTER_NAME

For example, if we have more resources, and the pull secret is not located on the
home directory, you may use something like this:

```
EDPM_CPUS=96 EDPM_RAM=256 PULL_SECRET=~/.config/openstack/pull-secret.txt make deploy_rhoso_dataplane
```
If you want to set the `openshift-install` location and change the default ShiftStack cluster name:
```
OPENSHIFT_INSTALL=openshift-install CLUSTER_NAME=custom-ocp-name make deploy_shiftstack
```
By default, the `deploy_shiftstack` target uses the `~/.ssh/id_rsa.pub` SSH pub key, if you want to use a specific key for the OpenShift installation, you can set the custom key location with `SSH_PUB_KEY` env var. This key will be used for access to the bootstrap machine and debugging it in case of failure:
```
SSH_PUB_KEY=~/.ssh/custom_id_rsa.pub make deploy_shiftstack
ssh -i ~/.ssh/custom_id_rsa.pub core@${BOOTSTRAP_FLOATING_IP}
```
