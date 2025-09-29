
PULL_SECRET ?= ~/pull-secret

EDPM_CPUS ?= 32
EDPM_RAM ?= 128
EDPM_DISK ?= 640

OPENSHIFT_RELEASE ?= 4.18
OPENSHIFT_INSTALLER ?= 
OPENSHIFT_INSTALLDIR ?= 
OPENSHIFT_INSTALLCONFIG ?= 

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
	@scripts/firewall.sh
	$(info Deploying proxy server)
	@scripts/proxy.sh
ifeq (,$(wildcard $(OPENSHIFT_INSTALLER)))
	$(info Downloading the OpenShift Installer $(OPENSHIFT_RELEASE))
	$(eval OPENSHIFT_INSTALLER := installer/bin/openshift-install)
	@git clone https://github.com/openshift/installer.git
	@cd installer && git remote update && git checkout origin/release-$(OPENSHIFT_RELEASE)
	@cd installer && hack/build.sh
	@cd installer && bin/openshift-install version
endif
ifeq (,$(wildcard $(OPENSHIFT_INSTALLDIR)))
	$(info Making the OpenShift Cluster directory at $(OPENSHIFT_INSTALLDIR))
	$(eval OPENSHIFT_INSTALLDIR := clusters/rhoai)
	@mkdir -p $(OPENSHIFT_INSTALLDIR)
endif
ifeq (,$(wildcard $(OPENSHIFT_INSTALLCONFIG)))
	$(info Making the OpenShift Cluster Install Configuration at $(OPENSHIFT_INSTALLCONFIG))
	@scripts/build_installconfig.sh $(OPENSHIFT_INSTALLDIR)
else
	@cp $(OPENSHIFT_INSTALLCONFIG) $(OPENSHIFT_INSTALLDIR)/
endif
	$(info Installing OpenShift $(OPENSHIFT_RELEASE))
	@mkdir -p $(OPENSHIFT_INSTALLDIR)
	@$(OPENSHIFT_INSTALLER) --log-level debug --dir $(OPENSHIFT_INSTALLDIR) create cluster
