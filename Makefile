
PULL_SECRET ?= $(HOME)/pull-secret
SSH_PUB_KEY ?= $(HOME)/.ssh/id_rsa.pub

EDPM_CPUS ?= 40
EDPM_RAM ?= 160
EDPM_DISK ?= 640

PROXY_USER ?= rhoai
PROXY_PASSWORD ?= 12345678

OPENSHIFT_INSTALLER ?= $(shell which openshift-install 2>/dev/null)
OPENSHIFT_CLIENT ?= $(shell which oc 2>/dev/null)
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

.PHONY: prerequisites
prerequisites: ensure_rhoso_rhelai ## Installs basic tools & Validate GPU host
	@sudo dnf -y install gcc-c++ zip git make pciutils squid
	@make -C rhoso-rhelai/nested-passthrough validate_host

##@ DEPLOY RHOSO CONTROL PLANE
.PHONY: deploy_rhoso_controlplane
deploy_rhoso_controlplane: prerequisites ## Deploy OCP cluster using CRC, deploy OSP operators, and deploy the OpenStack Control Plane
	@make -C rhoso-rhelai/nested-passthrough DEPLOY_CINDER=true PULL_SECRET=$(PULL_SECRET) deploy_controlplane

##@ DEPLOY RHOSO DATA PLANE
.PHONY: deploy_rhoso_dataplane
deploy_rhoso_dataplane: ensure_rhoso_rhelai ## Deploy an EDPM node with PCI passthrough
	@make -C rhoso-rhelai/nested-passthrough EDPM_CPUS=$(EDPM_CPUS) EDPM_RAM=$(EDPM_RAM) EDPM_DISK=$(EDPM_DISK) PULL_SECRET=$(PULL_SECRET) deploy_edpm

##@ DEPLOY SHIFTSTACK
.PHONY: deploy_shiftstack
deploy_shiftstack: ## Deploy OpenShift on OpenStack
ifeq ($(OPENSHIFT_INSTALLER),)
	$(error openshift-install not found in PATH. Please go to https://amd64.ocp.releases.ci.openshift.org/ and download the openshift installer or set the OPENSHIFT_INSTALLER variable with its custom PATH)
endif
	$(info Creating OpenStack Networks, Flavors and Quotas)
	@scripts/openstack_prerequisites.sh "$(EDPM_CPUS)" "$(EDPM_RAM)" "$(EDPM_DISK)"
	$(info Setting firewall permissions)
	@scripts/firewall_permissions.sh
	$(info Deploying proxy server)
	@scripts/proxy_setup.sh "$(PROXY_USER)" "$(PROXY_PASSWORD)"
	$(info Making the OpenShift installation directory at clusters/$(CLUSTER_NAME))
	@mkdir -p clusters/$(CLUSTER_NAME)
ifeq (,$(wildcard $(OPENSHIFT_INSTALLCONFIG)))
	$(info Making the OpenShift Cluster Install Configuration at clusters/$(CLUSTER_NAME)/install-config.yaml)
	@cd scripts && ./build_installconfig.sh "../$(OPENSHIFT_INSTALLER)" "$(PULL_SECRET)" "$(CLUSTER_NAME)" "$(PROXY_USER)" "$(PROXY_PASSWORD)" "$(SSH_PUB_KEY)"
else
	@cp $(OPENSHIFT_INSTALLCONFIG) clusters/$(CLUSTER_NAME)/
endif
	@$(OPENSHIFT_INSTALLER) --log-level debug --dir clusters/$(CLUSTER_NAME) create cluster

##@ DEPLOY GPU WORKER NODES
.PHONY: deploy_worker_gpu
deploy_worker_gpu: ## Create a new MachineSet for the GPU workers
ifeq ($(OPENSHIFT_CLIENT),)
	$(error oc not found in PATH. Please go to https://amd64.ocp.releases.ci.openshift.org/ and download the openshift client or set OPENSHIFT_CLIENT variable with its custom PATH)
endif
	$(info Creating a new MachineSet for the GPU workers)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)/auth/kubeconfig))
	$(error The kubeconfig is missing, it should be at clusters/$(CLUSTER_NAME)/auth/kubeconfig)
endif
	@cd scripts && ./create_worker_gpu.sh "$(CLUSTER_NAME)" "$(OPENSHIFT_CLIENT)"
	@cd scripts && ./install_gpu_operators.sh "$(CLUSTER_NAME)" "$(OPENSHIFT_CLIENT)"

##@ DEPLOY OPENSHIFT AI
.PHONY: deploy_rhoai
deploy_rhoai: ## Deploy OpenShift AI
ifeq ($(OPENSHIFT_CLIENT),)
	$(error oc not found in PATH. Please go to https://amd64.ocp.releases.ci.openshift.org/ and download the openshift client or set OPENSHIFT_CLIENT variable with its custom PATH)
endif
	$(info Installing OpenShift AI Operators)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)/auth/kubeconfig))
	$(error The kubeconfig is missing, it should be at clusters/$(CLUSTER_NAME)/auth/kubeconfig)
endif
	@cd scripts && ./install_rhoai_operators.sh "$(CLUSTER_NAME)" "$(OPENSHIFT_CLIENT)"

##@ CLEAN SHIFTSTACK
.PHONY: clean_shiftstack
clean_shiftstack: ## Clean OpenShift on RHOSO cluster
ifeq ($(OPENSHIFT_INSTALLER),)
	$(error openshift-install not found in PATH. Please go to https://amd64.ocp.releases.ci.openshift.org/ and download the openshift installer or set the OPENSHIFT_INSTALLER variable with its custom PATH)
endif
	$(info Destroying the OpenShift cluster)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)))
	$(error Cluster directory clusters/$(CLUSTER_NAME) not found)
endif
	@$(OPENSHIFT_INSTALLER) --log-level debug --dir clusters/$(CLUSTER_NAME) destroy cluster

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
