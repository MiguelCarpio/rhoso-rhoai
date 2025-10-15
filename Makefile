.DEFAULT_GOAL := help

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

.PHONY: help
help: ## Display this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@printf "\n\033[1mDeployment Workflow:\033[0m\n"
	@printf "  1. make \033[36mdeploy_rhoso_controlplane\033[0m\n"
	@printf "  2. make \033[36mdeploy_rhoso_dataplane\033[0m\n"
	@printf "  3. make \033[36mdeploy_shiftstack\033[0m\n"
	@printf "  4. make \033[36mdeploy_worker_gpu\033[0m\n"
	@printf "  5. make \033[36mdeploy_rhoai\033[0m\n"
	@printf "  6. make \033[36mdeploy_model_service\033[0m\n"
	@printf "\n  \033[33mNote:\033[0m You can skip steps 1 and 2 if you already have an RHOSO cloud with Cinder service and EDPM nodes with PCI passthrough for NVIDIA GPUs.\n"

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
	@sudo dnf -y install gcc-c++ zip git make pciutils squid wget curl python
	@make -C rhoso-rhelai/nested-passthrough validate_host

##@ DEPLOY RHOSO CONTROL PLANE
.PHONY: deploy_rhoso_controlplane
deploy_rhoso_controlplane: prerequisites ## Deploy OCP cluster using CRC, OSP operators and the OpenStack Control Plane
	@make -C rhoso-rhelai/nested-passthrough DEPLOY_CINDER=true PULL_SECRET="$(PULL_SECRET)" deploy_controlplane

##@ DEPLOY RHOSO DATA PLANE
.PHONY: deploy_rhoso_dataplane
deploy_rhoso_dataplane: ensure_rhoso_rhelai ## Deploy an EDPM node with PCI passthrough
	@make -C rhoso-rhelai/nested-passthrough EDPM_CPUS=$(EDPM_CPUS) EDPM_RAM=$(EDPM_RAM) EDPM_DISK=$(EDPM_DISK) PULL_SECRET="$(PULL_SECRET)" deploy_edpm

##@ DEPLOY SHIFTSTACK
.PHONY: deploy_shiftstack
deploy_shiftstack: ensure_openshift_install ## Deploy OpenShift on RHOSO
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

##@ DEPLOY GPU WORKER NODE
.PHONY: deploy_worker_gpu
deploy_worker_gpu: ensure_openshift_client ## Create a new MachineSet for the GPU worker and scale it to 1
	$(info Creating a new MachineSet for the GPU worker and scale it to 1)
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
	@cd scripts && CLUSTER_NAME="$(CLUSTER_NAME)" OPENSHIFT_CLIENT="$(OPENSHIFT_CLIENT)" ./router_floating_ip.sh
	@cd scripts && CLUSTER_NAME="$(CLUSTER_NAME)" OPENSHIFT_CLIENT="$(OPENSHIFT_CLIENT)" ./install_rhoai_operators.sh

##@ DEPLOY MODEL SERVICE
.PHONY: deploy_model_service
deploy_model_service: ensure_openshift_client ## Deploy and Verify Model Serving for an Inference Chat Endpoint
	$(info Deploying and verifying Model Serving for an Inference Chat Endpoint)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)/auth/kubeconfig))
	$(error The kubeconfig is missing, it should be at clusters/$(CLUSTER_NAME)/auth/kubeconfig)
endif
	@cd scripts && CLUSTER_NAME="$(CLUSTER_NAME)" OPENSHIFT_CLIENT="$(OPENSHIFT_CLIENT)" ./deploy_model_service.sh  
	@echo "Getting model service metrics"
ifeq (,$(wildcard gpu-validation)) ## Using MiguelCarpio/gpu-validation url branch until https://github.com/rhos-vaf/gpu-validation/pull/5 is merged
	@git clone https://github.com/MiguelCarpio/gpu-validation.git
else
	@cd gpu-validation && git remote update && git checkout origin/url
endif
	@cd gpu-validation/gpu-validation/files/scripts/ && URL=https://$$(${OPENSHIFT_CLIENT} get route -n vllm-llama -o jsonpath='{.items[0].spec.host}') MODEL_NAME="RedHatAI/Llama-3.2-1B-Instruct-FP8" ./model_performance_check.sh

##@ CLEAN MODEL SERVICE
.PHONY: clean_model_service
clean_model_service: ensure_openshift_client ## Delete Model Service namespace
	$(info Deleting the Model Service vllm-llama namespace)
ifeq (,$(wildcard clusters/$(CLUSTER_NAME)/auth/kubeconfig))
	$(error The kubeconfig is missing, it should be at clusters/$(CLUSTER_NAME)/auth/kubeconfig)
endif
	@export KUBECONFIG=clusters/$(CLUSTER_NAME)/auth/kubeconfig  && $(OPENSHIFT_CLIENT) delete project vllm-llama

##@ CLEAN SHIFTSTACK
.PHONY: clean_shiftstack
clean_shiftstack: ensure_openshift_install ## Delete OpenShift on RHOSO
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
