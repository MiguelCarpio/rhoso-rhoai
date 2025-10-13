
PULL_SECRET ?= $(HOME)/pull-secret
SSH_PUB_KEY ?= $(HOME)/.ssh/id_rsa.pub

EDPM_CPUS ?= 40
EDPM_RAM ?= 160
EDPM_DISK ?= 640

PROXY_USER ?= rhoai
PROXY_PASSWORD ?= 12345678

OPENSHIFT_RELEASE ?= stable-4.18
OPENSHIFT_INSTALL ?= $(shell which openshift-install 2>/dev/null || echo $(HOME)/bin/openshift-install)
OPENSHIFT_CLIENT ?= $(shell which oc 2>/dev/null || echo $(HOME)/bin/oc)
OPENSHIFT_INSTALLCONFIG ?=
CLUSTER_NAME ?= rhoai

##@ PREREQUISITES
.PHONY: ensure_rhoso_rhelai
ensure_rhoso_rhelai:
ifeq (,$(wildcard rhoso-rhelai))
	@git clone https://github.com/rhos-vaf/rhoso-rhelai.git
	@make -C rhoso-rhelai/nested-passthrough download_tools
else
	@cd rhoso-rhelai && git remote update && git checkout origin/main
endif

.PHONY: ensure_openshift_client
ensure_openshift_client: ## Installs OpenShift Client if it doesn't exist in $PATH
ifeq (,$(wildcard $(OPENSHIFT_CLIENT)))
	$(info Downloading the OpenShift Client $(OPENSHIFT_RELEASE))
	@wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$(OPENSHIFT_RELEASE)/openshift-client-linux.tar.gz || { \
		echo "Error: Failed to download openshift-client-linux.tar.gz" >&2; \
		echo "Be sure that you are setting a valid OPENSHIFT_RELEASE version, see the list at https://mirror.openshift.com/pub/openshift-v4/clients/ocp/" >&2; \
		exit 1; \
	}
	@tar -xzf openshift-client-linux.tar.gz -C $(HOME)/bin oc
	@rm -f openshift-client-linux.tar.gz
endif

.PHONY: ensure_openshift_install
ensure_openshift_install: ensure_openshift_client ## Installs OpenShift Installer if it doesn't exist in $PATH
ifeq (,$(wildcard $(OPENSHIFT_INSTALL)))
	$(info Downloading the OpenShift Installer $(OPENSHIFT_RELEASE))
	@RELEASE_IMAGE=$$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(OPENSHIFT_RELEASE)/release.txt | grep 'Pull From: quay.io' | awk -F ' ' '{print $$3}'); \
	if [ -z "$$RELEASE_IMAGE" ]; then \
		echo "Error: Failed to retrieve RELEASE_IMAGE from OpenShift mirror. Be sure that you are setting a valid OPENSHIFT_RELEASE version, see the list at https://mirror.openshift.com/pub/openshift-v4/clients/ocp/" >&2; \
		exit 1; \
	fi; \
	$(OPENSHIFT_CLIENT) adm release extract --registry-config "$(PULL_SECRET)" --command=openshift-install --to "$(HOME)/bin/" $$RELEASE_IMAGE
endif

.PHONY: prerequisites
prerequisites: ensure_rhoso_rhelai ## Installs basic tools & Validate GPU host
	@sudo dnf -y install gcc-c++ zip git make pciutils squid wget curl
	@make -C rhoso-rhelai/nested-passthrough validate_host

##@ DEPLOY RHOSO CONTROL PLANE
.PHONY: deploy_rhoso_controlplane
deploy_rhoso_controlplane: prerequisites ## Deploy OCP cluster using CRC, deploy OSP operators, and deploy the OpenStack Control Plane
	@make -C rhoso-rhelai/nested-passthrough DEPLOY_CINDER=true PULL_SECRET="$(PULL_SECRET)" deploy_controlplane

##@ DEPLOY RHOSO DATA PLANE
.PHONY: deploy_rhoso_dataplane
deploy_rhoso_dataplane: ensure_rhoso_rhelai ## Deploy an EDPM node with PCI passthrough
	@make -C rhoso-rhelai/nested-passthrough EDPM_CPUS=$(EDPM_CPUS) EDPM_RAM=$(EDPM_RAM) EDPM_DISK=$(EDPM_DISK) PULL_SECRET="$(PULL_SECRET)" deploy_edpm

##@ DEPLOY SHIFTSTACK
.PHONY: deploy_shiftstack
deploy_shiftstack: ensure_openshift_install ## Deploy OpenShift on OpenStack
	$(info Creating OpenStack Networks, Flavors and Quotas)
	@cd scripts && EDPM_CPUS=$(EDPM_CPUS) EDPM_RAM=$(EDPM_RAM) EDPM_DISK=$(EDPM_DISK) ./openstack_prerequisites.sh
	$(info Setting firewall permissions)
	@cd scripts && ./firewall_permissions.sh
	$(info Deploying proxy server)
	@cd scripts && PROXY_USER="$(PROXY_USER)" PROXY_PASSWORD="$(PROXY_PASSWORD)" ./proxy_setup.sh
	$(info Making the OpenShift installation directory at clusters/$(CLUSTER_NAME))
	@mkdir -p clusters/$(CLUSTER_NAME)
ifeq (,$(wildcard $(OPENSHIFT_INSTALLCONFIG)))
	$(info Making the OpenShift Cluster Install Configuration at clusters/$(CLUSTER_NAME)/install-config.yaml)
	@cd scripts && PULL_SECRET="$(PULL_SECRET)" CLUSTER_NAME="$(CLUSTER_NAME)" PROXY_USER="$(PROXY_USER)" PROXY_PASSWORD="$(PROXY_PASSWORD)" SSH_PUB_KEY="$(SSH_PUB_KEY)" ./build_installconfig.sh
else
	@cp "$(OPENSHIFT_INSTALLCONFIG)" clusters/$(CLUSTER_NAME)/
endif
	@$(OPENSHIFT_INSTALL) --log-level debug --dir clusters/$(CLUSTER_NAME) create cluster

##@ DEPLOY GPU WORKER NODES
.PHONY: deploy_worker_gpu
deploy_worker_gpu: ensure_openshift_client ## Create a new MachineSet for the GPU workers
	$(info Creating a new MachineSet for the GPU workers)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)/auth/kubeconfig))
	$(error The kubeconfig is missing, it should be at clusters/$(CLUSTER_NAME)/auth/kubeconfig)
endif
	@cd scripts && CLUSTER_NAME="$(CLUSTER_NAME)" OPENSHIFT_CLIENT="$(OPENSHIFT_CLIENT)" ./create_worker_gpu.sh 
	@cd scripts && CLUSTER_NAME="$(CLUSTER_NAME)" OPENSHIFT_CLIENT="$(OPENSHIFT_CLIENT)" ./install_gpu_operators.sh

##@ DEPLOY OPENSHIFT AI
.PHONY: deploy_rhoai
deploy_rhoai: ensure_openshift_client ## Deploy OpenShift AI
	$(info Installing OpenShift AI Operators)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)/auth/kubeconfig))
	$(error The kubeconfig is missing, it should be at clusters/$(CLUSTER_NAME)/auth/kubeconfig)
endif
	@cd scripts && CLUSTER_NAME="$(CLUSTER_NAME)" OPENSHIFT_CLIENT="$(OPENSHIFT_CLIENT)" ./install_rhoai_operators.sh

##@ CLEAN SHIFTSTACK
.PHONY: clean_shiftstack
clean_shiftstack: ensure_openshift_install ## Clean OpenShift on RHOSO cluster
	$(info Destroying the OpenShift cluster)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)))
	$(error Cluster directory clusters/$(CLUSTER_NAME) not found)
endif
	@$(OPENSHIFT_INSTALL) --log-level debug --dir clusters/$(CLUSTER_NAME) destroy cluster

##@ CLEAN RHOSO DATA PLANE
.PHONY: clean_rhoso_dataplane
clean_rhoso_dataplane: ensure_rhoso_rhelai ## Delete the RHOSO EDPM node
	$(info Deleting the EDPM node)
	@make -C rhoso-rhelai/nested-passthrough cleanup_edpm

##@ CLEAN RHOSO CONTROL PLANE
.PHONY: clean_rhoso_controlplane
clean_rhoso_controlplane: ensure_rhoso_rhelai ## Delete the RHOSO workload and the OCP host cluster
	$(info Deleting the OCP cluster)
	@make -C rhoso-rhelai/nested-passthrough cleanup_controlplane
