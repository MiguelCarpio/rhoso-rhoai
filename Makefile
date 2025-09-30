
PULL_SECRET ?= ~/pull-secret

EDPM_CPUS ?= 36
EDPM_RAM ?= 144
EDPM_DISK ?= 640

PROXY_USER ?= rhoai
PROXY_PASSWORD ?= 12345678

OPENSHIFT_RELEASE ?= 4.18
OPENSHIFT_INSTALLER ?= 
OPENSHIFT_INSTALLCONFIG ?=
CLUSTER_NAME ?= rhoai

##@ PREREQUISITES
.PHONY: prerequisites
prerequisites: ## Installs basic tools
	@sudo dnf -y install gcc-c++ zip git make pciutils squid 
ifeq (,$(wildcard rhoso-rhelai))
	@git clone https://github.com/rhos-vaf/rhoso-rhelai.git
else
	@cd rhoso-rhelai && git remote update && git checkout origin/main
endif
	@make -C rhoso-rhelai/nested-passthrough download_tools validate_host

##@ DEPLOY RHOSO CONTROL PLANE
.PHONY: deploy_rhoso_controlplane
deploy_rhoso_controlplane: ## Deploy OCP cluster using CRC, deploy OSP operators, and deploy the OpenStack Control Plane
ifeq (,$(wildcard rhoso-rhelai))
	@git clone https://github.com/rhos-vaf/rhoso-rhelai.git
else
	@cd rhoso-rhelai && git remote update && git checkout origin/main
endif
	@make -C rhoso-rhelai/nested-passthrough DEPLOY_CINDER=true PULL_SECRET=$(PULL_SECRET) deploy_controlplane

##@ DEPLOY RHOSO DATA PLANE
.PHONY: deploy_rhoso_dataplane
deploy_rhoso_dataplane: ## Deploy an EDPM node with PCI passthrough
ifeq (,$(wildcard rhoso-rhelai))
	@git clone https://github.com/rhos-vaf/rhoso-rhelai.git
else
	@cd rhoso-rhelai && git remote update && git checkout origin/main
endif
	@make -C rhoso-rhelai/nested-passthrough EDPM_CPUS=$(EDPM_CPUS) EDPM_RAM=$(EDPM_RAM) EDPM_DISK=$(EDPM_DISK) PULL_SECRET=$(PULL_SECRET) deploy_edpm

##@ DEPLOY SHIFTSTACK
.PHONY: deploy_shiftstack
deploy_shiftstack: ## Deploy OpenShift on OpenStack
	$(info Creating OpenStack Networks, Flavors and Quotas)
	@scripts/openstack_prerequisites.sh $(EDPM_CPUS) $(EDPM_RAM) $(EDPM_DISK)
	$(info Setting firewall permissions)
	@scripts/firewall_permissions.sh
	$(info Deploying proxy server)
	@scripts/proxy_setup.sh $(PROXY_USER) $(PROXY_PASSWORD)
	$(info Making the OpenShift installation directory at clusters/$(CLUSTER_NAME))
	@mkdir -p clusters/$(CLUSTER_NAME)
ifeq (,$(wildcard $(OPENSHIFT_INSTALLER)))
	$(error Please go to https://amd64.ocp.releases.ci.openshift.org/ and download the openshift installer)
endif
ifeq (,$(wildcard $(OPENSHIFT_INSTALLCONFIG)))
	$(info Making the OpenShift Cluster Install Configuration at clusters/$(CLUSTER_NAME)/install-config.yaml)
	@cd scripts && ./build_installconfig.sh ../$(OPENSHIFT_INSTALLER) $(PULL_SECRET) $(CLUSTER_NAME) $(PROXY_USER) $(PROXY_PASSWORD)
else
	@cp $(OPENSHIFT_INSTALLCONFIG) clusters/$(CLUSTER_NAME)/
endif
	$(info Installing OpenShift $(OPENSHIFT_RELEASE))
	@$(OPENSHIFT_INSTALLER) --log-level debug --dir clusters/$(CLUSTER_NAME) create cluster
