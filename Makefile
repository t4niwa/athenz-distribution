ifeq ($(wildcard athenz),)
SUBMODULE := $(shell git submodule add --force https://github.com/AthenZ/athenz.git athenz)
else
SUBMODULE := $(shell git submodule update --recursive)
endif

ifeq ($(DOCKER_REGISTRY_OWNER),)
DOCKER_REGISTRY_OWNER=ctyano
endif
ifeq ($(DOCKER_REGISTRY),)
DOCKER_REGISTRY=ghcr.io/$(DOCKER_REGISTRY_OWNER)/
endif

# Parallel make for kubernetes (db+cli parallel, then zms, then zts+ui parallel)
KMAKE_J = DOCKER_REGISTRY=$(DOCKER_REGISTRY) $(MAKE) -j4 -C kubernetes
# Sequential make for kubernetes (setup must precede deploy)
KMAKE = DOCKER_REGISTRY=$(DOCKER_REGISTRY) $(MAKE) -C kubernetes

# Internal images (Athenz core)
INTERNAL_IMAGES := athenz-db athenz-zms-server athenz-zts-server athenz-cli athenz-ui
# External images (plugins, tools, workloads)
EXTERNAL_IMAGES := athenz-plugins athenz_user_cert certsigner-envoy crypki-softhsm docker-vegeta k8s-athenz-sia
THIRD_PARTY_IMAGES := docker.io/dexidp/dex:latest docker.io/ealen/echo-server:latest \
	docker.io/envoyproxy/envoy:v1.34-latest docker.io/ghostunnel/ghostunnel:latest \
	docker.io/openpolicyagent/kube-mgmt:latest docker.io/openpolicyagent/opa:latest-static \
	docker.io/openpolicyagent/opa:0.66.0-static docker.io/portainer/kubectl-shell:latest \
	docker.io/tatyano/authorization-proxy:latest

.PHONY: up down pull test version

# ============================================================
# Quick start
# ============================================================

# Phase 1: kind + pull + certs in parallel
up: phase1 load-images deploy-athenz deploy-identityprovider deploy-workloads
	@printf "\n*** Athenz deployed. UI: kubectl -n athenz port-forward deployment/athenz-ui 3000:3000 ***\n\n"

# Run kind setup, image pull, and cert generation in parallel
phase1:
	@$(MAKE) -j3 deploy-kind pull generate-certificates

down: clean-athenz
	kind delete cluster ||:

# ============================================================
# Docker image pull (fully parallelized)
# ============================================================

pull:
	@printf "Pulling all images in parallel...\n"
	@(echo $(INTERNAL_IMAGES) $(EXTERNAL_IMAGES) | tr ' ' '\n' | sed 's|^|$(DOCKER_REGISTRY)|;s|$$|:latest|'; \
	  echo $(THIRD_PARTY_IMAGES) | tr ' ' '\n') | xargs -P10 -I{} docker pull {}

# ============================================================
# KinD management
# ============================================================

deploy-kind:
	@$(KMAKE) kind-setup

load-images: install-kustomize
	@$(KMAKE) kind-load-images

# ============================================================
# Athenz core (parallel deploy via -j4)
# ============================================================

deploy-athenz:
	@$(KMAKE_J) deploy-athenz

check-athenz: install-parsers
	@$(KMAKE) check-athenz

clean-athenz: clean-certificates
	@$(KMAKE) clean

# ============================================================
# Identity provider & workloads
# ============================================================

deploy-identityprovider: install-parsers
	@$(KMAKE) setup-athenz-identityprovider deploy-athenz-identityprovider

deploy-workloads:
	@$(KMAKE) setup-athenz-workloads deploy-athenz-workloads

# ============================================================
# Crypki (optional)
# ============================================================

deploy-crypki:
	@$(KMAKE) setup-crypki-softhsm deploy-crypki-softhsm

use-crypki: test-crypki deploy-oauth2
	@$(KMAKE) switch-athenz-zts-cert-signer test-athenz-oauth2

test-crypki:
	@$(KMAKE) test-crypki-softhsm

deploy-oauth2:
	@$(KMAKE) setup-athenz-oauth2 deploy-athenz-oauth2

# ============================================================
# Tests
# ============================================================

test: install-parsers
	@$(KMAKE) test-athenz

test-showcases:
	@$(KMAKE) test-athenz-showcases

test-loadtest:
	@$(KMAKE) deploy-athenz-loadtest

# ============================================================
# Certificates (2048-bit for faster generation in dev)
# ============================================================

KEY_BITS ?= 2048

clean-certificates:
	rm -rf keys certs

generate-ca:
	@mkdir -p keys certs
	openssl genrsa -out keys/ca.private.pem $(KEY_BITS)
	openssl rsa -pubout -in keys/ca.private.pem -out keys/ca.public.pem
	openssl req -new -x509 -days 99999 -config openssl/ca.openssl.config -extensions ext_req -key keys/ca.private.pem -out certs/ca.cert.pem
	cp certs/ca.cert.pem certs/selfsign.ca.cert.pem

# All leaf certs depend only on CA; generate in parallel with make -j
define gen-cert
generate-$(1): generate-ca
	openssl genrsa -out keys/$(1).private.pem $$(KEY_BITS)
	openssl rsa -pubout -in keys/$(1).private.pem -out keys/$(1).public.pem
	$(if $(2),openssl req -config openssl/$(1).openssl.config -new -key keys/$(1).private.pem -out certs/$(1).csr.pem -extensions ext_req)
	$(if $(2),openssl x509 -req -in certs/$(1).csr.pem -CA certs/ca.cert.pem -CAkey keys/ca.private.pem -CAcreateserial -out certs/$(1).cert.pem -days 99999 -extfile openssl/$(1).openssl.config -extensions ext_req)
endef

$(eval $(call gen-cert,zms,cert))
$(eval $(call gen-cert,zts,cert))
$(eval $(call gen-cert,athenz_admin,cert))
$(eval $(call gen-cert,ui,cert))
$(eval $(call gen-cert,identityprovider,))
$(eval $(call gen-cert,crypki,cert))

# ZTS needs ZMS cert for chain (sequential)
generate-zts: generate-zms

# All leaf certs can generate in parallel (except zts→zms dependency)
generate-certificates: generate-ca generate-zms generate-zts generate-athenz_admin generate-ui generate-identityprovider generate-crypki

# ============================================================
# Tool installation
# ============================================================

install-pathman:
	@test -x "$$HOME/.local/bin/pathman" || curl -fsSL https://webi.sh/pathman | sh
	@printf '%s\n' ":$$PATH:" | grep -q "$$HOME/.local/bin" || export PATH="$$PATH:$$HOME/.local/bin"

install-jq: install-pathman
	@which jq || (curl -sf https://webi.sh/jq | sh && ~/.local/bin/pathman add ~/.local/bin)

install-yq: install-pathman
	@which yq || (curl -sf https://webi.sh/yq | sh && ~/.local/bin/pathman add ~/.local/bin)

install-step: install-pathman
	@which step || (STEP_VERSION=$$(curl -sf https://api.github.com/repos/smallstep/cli/releases | jq -r .[].tag_name | grep -E '^v[0-9]*.[0-9]*.[0-9]*$$' | head -n1 | sed -e 's/.*v\([0-9]*.[0-9]*.[0-9]*\).*/\1/g'); \
	GOOS=$$(go env GOOS | tr -d "'"); GOARCH=$$(go env GOARCH | tr -d "'"); \
	curl -fL "https://github.com/smallstep/cli/releases/download/v$${STEP_VERSION}/step_$${GOOS}_$${STEP_VERSION}_$${GOARCH}.tar.gz" | tar -xz -C ~/.local/bin/ && \
	ln -sf ~/.local/bin/step_$${STEP_VERSION}/bin/step ~/.local/bin/step)

install-parsers: install-jq install-yq install-step

install-kustomize: install-pathman
	@which kustomize || (cd ~/.local/bin && curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash)

.SILENT: version
version:
	@echo "Docker Registry: $(DOCKER_REGISTRY)"
