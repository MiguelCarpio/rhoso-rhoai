
PULL_SECRET ?= ~/pull-secret

EDPM_CPUS ?= 28
EDPM_RAM ?= 100
# We need a lot of space because models are not quantized
EDPM_DISK ?= 640

# NVIDIA PCI Vendor ID
GPU_VENDOR_ID ?= 10de
GPU_PRODUCT_ID ?=

TIMEOUT_OPERATORS ?= 600s
TIMEOUT_CTRL ?= 30m
TIMEOUT_EDPM ?= 40m

##@ PREPARATIONS
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