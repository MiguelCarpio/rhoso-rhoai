
PULL_SECRET ?= ~/pull-secret

EDPM_CPUS ?= 32
EDPM_RAM ?= 128
EDPM_DISK ?= 640

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

