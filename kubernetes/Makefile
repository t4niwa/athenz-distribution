SED_INPLACE = sed -i
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	SED_INPLACE = sed -i ''
endif

SLEEP_SECONDS ?= 2
WAITING_THRESHOLD ?= 180

# Reusable: kubectl exec in athenz-cli
ATHENZ_CLI := kubectl -n athenz exec deployment/athenz-cli -it --
ZMS_CLI := $(ATHENZ_CLI) zms-cli \
	-z https://athenz-zms-server.athenz:4443/zms/v1 \
	-key /var/run/athenz/athenz_admin.private.pem \
	-cert /var/run/athenz/athenz_admin.cert.pem

# All kustomize directories that need certificates
CERT_DIRS := athenz-cli athenz-zms-server athenz-zts-server athenz-ui \
	athenz-identityprovider athenz-authorizer athenz-authzenvoy \
	athenz-authzwebhook athenz-authzproxy athenz-client crypki-softhsm

# ============================================================
# KinD cluster management
# ============================================================

kind-setup:
	which kind && (kind delete cluster ||:; kind create cluster --config kind.yaml)

kind-load-images:
	kind load docker-image \
		docker.io/ghostunnel/ghostunnel:latest \
		$(DOCKER_REGISTRY)crypki-softhsm:latest \
		$(DOCKER_REGISTRY)certsigner-envoy:latest \
		$(DOCKER_REGISTRY)athenz_user_cert:latest \
		$(DOCKER_REGISTRY)athenz-plugins:latest \
		$(DOCKER_REGISTRY)athenz-db:latest \
		$(DOCKER_REGISTRY)athenz-zms-server:latest \
		$(DOCKER_REGISTRY)athenz-zts-server:latest \
		$(DOCKER_REGISTRY)athenz-cli:latest \
		$(DOCKER_REGISTRY)athenz-ui:latest \
		docker.io/ealen/echo-server:latest \
		docker.io/dexidp/dex:latest \
		docker.io/envoyproxy/envoy:v1.34-latest \
		docker.io/openpolicyagent/kube-mgmt:latest \
		docker.io/openpolicyagent/opa:latest-static \
		docker.io/openpolicyagent/opa:0.66.0-static \
		docker.io/portainer/kubectl-shell:latest \
		$(DOCKER_REGISTRY)k8s-athenz-sia:latest \
		$(DOCKER_REGISTRY)docker-vegeta:latest \
		docker.io/tatyano/authorization-proxy:latest

kind-shutdown:
	kind delete cluster

# ============================================================
# Clean
# ============================================================

clean-certificates:
	@for d in $(CERT_DIRS); do rm -rf $$d/kustomize/{keys,certs}; done

clean-namespace:
	kubectl delete namespace athenz ||:
	kubectl delete namespace crypki ||:

clean: clean-namespace clean-certificates
	@grep -q "athenz.zts.cert_signer_factory_class=com.yahoo.athenz.zts.cert.impl.crypki.HttpCertSignerFactory" \
		"athenz-zts-server/kustomize/conf/zts.properties" && $(MAKE) clean-patch-athenz-zts ||:

# ============================================================
# Certificate management
# ============================================================

copy-certificates-to-kustomization:
	@grep -q "athenz.zts.cert_signer_factory_class=com.yahoo.athenz.zts.cert.impl.crypki.HttpCertSignerFactory" \
		"athenz-zts-server/kustomize/conf/zts.properties" && echo SKIPPED || \
	( for d in $(CERT_DIRS); do cp -r ../keys ../certs $$d/kustomize/; done && echo "APPLIED" )

copy-crypki-certificates-to-kustomization:
	cp -r ../keys ../certs crypki-softhsm/kustomize/

overwrite-certificates-with-crypki:
	@for d in $(filter-out crypki-softhsm,$(CERT_DIRS)); do \
		cp -r crypki-softhsm/kustomize/keys crypki-softhsm/kustomize/certs $$d/kustomize/; \
	done

# ============================================================
# Kustomize image editing (only needed for non-default registries)
# ============================================================

define kustomize-edit-image
	@if [ "$(DOCKER_REGISTRY)" != "ghcr.io/ctyano/" ]; then \
		cd $(1)/kustomize && \
		$(foreach img,$(2),kustomize edit set image ghcr.io/ctyano/$(img):latest=$(DOCKER_REGISTRY)$(img):latest &&) \
		true; \
	fi
endef

# ============================================================
# Athenz core deployment
# ============================================================

create-namespace:
	@kubectl create namespace athenz 2>/dev/null ||:

setup-athenz-db: create-namespace
	$(call kustomize-edit-image,athenz-db,athenz-db)
	kubectl apply -k athenz-db/kustomize

setup-athenz-cli: create-namespace
	$(call kustomize-edit-image,athenz-cli,athenz-cli)
	kubectl apply -k athenz-cli/kustomize

setup-athenz-zms-server: setup-athenz-db
	$(call kustomize-edit-image,athenz-zms-server,athenz-plugins athenz-zms-server)
	kubectl apply -k athenz-zms-server/kustomize

setup-athenz-zts-server: setup-athenz-db setup-athenz-zms-server
	$(call kustomize-edit-image,athenz-zts-server,athenz-plugins athenz-cli athenz-zts-server)
	kubectl apply -k athenz-zts-server/kustomize

setup-athenz-ui: setup-athenz-zms-server
	$(call kustomize-edit-image,athenz-ui,athenz-ui)
	kubectl apply -k athenz-ui/kustomize

setup-athenz: setup-athenz-db setup-athenz-cli setup-athenz-zms-server setup-athenz-zts-server setup-athenz-ui

deploy-athenz: copy-certificates-to-kustomization setup-athenz

# ============================================================
# Health check
# ============================================================

check-athenz:
	@i=0; \
	while [ $$(kubectl -n athenz get all 2>/dev/null | grep -cE "0/1") -ne 0 ]; do \
		printf "\n***** Waiting for athenz ($$(( $$i * $(SLEEP_SECONDS) ))s/$(WAITING_THRESHOLD)s) *****\n"; \
		sleep $(SLEEP_SECONDS); \
		i=$$(( i + 1 )); \
		if [ $$i -ge $$(( $(WAITING_THRESHOLD) / $(SLEEP_SECONDS) )) ]; then \
			printf "\n** Athenz: timeout after $(WAITING_THRESHOLD)s **\n"; \
			kubectl -n athenz get all | grep -E "0/1" | awk '{print $$1}' | \
				xargs -I%% sh -c 'kubectl -n athenz logs %% --all-containers=true 2>/dev/null; kubectl -n athenz describe %% 2>/dev/null' ||:; \
			kubectl -n athenz get all; \
			exit 1; \
		fi; \
	done
	kubectl -n athenz get all
	@printf "\n*** Athenz Deployed Successfully ***\n\n"

# ============================================================
# Cert signer switching
# ============================================================

replace-system-properties:
	@if [ -z "$(KEY)" ] || [ -z "$(VALUE)" ] || [ -z "$(FILE)" ]; then echo "Error: KEY, VALUE, FILE required"; exit 1; fi
	@if grep -q "$(KEY)" "$(FILE)"; then $(SED_INPLACE) 's|$(KEY)|$(VALUE)|g' "$(FILE)"; else echo "'$(KEY)' not found in $(FILE)"; fi

clean-patch-athenz-zts:
	@$(MAKE) replace-system-properties \
		KEY="athenz.zts.cert_signer_factory_class=com.yahoo.athenz.zts.cert.impl.crypki.HttpCertSignerFactory" \
		VALUE="athenz.zts.cert_signer_factory_class=com.yahoo.athenz.zts.cert.impl.KeyStoreCertSignerFactory" \
		FILE="athenz-zts-server/kustomize/conf/zts.properties"

patch-athenz-zts:
	@$(MAKE) replace-system-properties \
		KEY="athenz.zts.cert_signer_factory_class=com.yahoo.athenz.zts.cert.impl.KeyStoreCertSignerFactory" \
		VALUE="athenz.zts.cert_signer_factory_class=com.yahoo.athenz.zts.cert.impl.crypki.HttpCertSignerFactory" \
		FILE="athenz-zts-server/kustomize/conf/zts.properties"

switch-athenz-zts-cert-signer: patch-athenz-zts
	@$(MAKE) -C crypki-softhsm generate-certificates
	@$(MAKE) overwrite-certificates-with-crypki

# ============================================================
# Crypki / OAuth2
# ============================================================

setup-crypki-softhsm:
	@$(MAKE) -C crypki-softhsm setup-crypki-softhsm

deploy-crypki-softhsm: copy-crypki-certificates-to-kustomization setup-crypki-softhsm
	@$(MAKE) -C crypki-softhsm deploy-crypki-softhsm

test-crypki-softhsm:
	@$(MAKE) -C crypki-softhsm test-crypki-softhsm

setup-athenz-oauth2:
	@$(MAKE) -C athenz-oauth2 setup-athenz-oauth2

deploy-athenz-oauth2: setup-athenz-oauth2
	@$(MAKE) -C athenz-oauth2 deploy-athenz-oauth2

test-athenz-oauth2:
	@$(MAKE) -C athenz-oauth2 test-athenz-oauth2

# ============================================================
# Identity provider
# ============================================================

setup-athenz-identityprovider: check-athenz test-athenz-servers
	@$(MAKE) -C athenz-identityprovider register-athenz-identityprovider check-register-athenz-identityprovider setup-athenz-identityprovider

deploy-athenz-identityprovider:
	@$(MAKE) -C athenz-identityprovider deploy-athenz-identityprovider

test-athenz-identityprovider:
	@$(MAKE) -C athenz-identityprovider test-athenz-identityprovider

test-athenz-identityprovider-openpolicyagent:
	@$(MAKE) -C athenz-identityprovider test-athenz-identityprovider-openpolicyagent

test-athenz-identityprovider-openpolicyagent-coverage:
	@$(MAKE) -C athenz-identityprovider test-athenz-identityprovider-openpolicyagent-coverage

# ============================================================
# Workloads (authorizer, envoy, webhook, proxy, client)
# ============================================================

# Setup targets
define setup-workload
setup-$(1): test-athenz-servers test-athenz-identityprovider
	@$$(MAKE) -C $(1) register-$(1) check-register-$(1)
endef

$(foreach w,athenz-authorizer athenz-authzenvoy athenz-authzwebhook athenz-authzproxy athenz-client,$(eval $(call setup-workload,$(w))))

# Deploy targets
define deploy-workload
deploy-$(1): test-athenz-identityprovider
	@$$(MAKE) -C $(1) deploy-$(1)
endef

$(foreach w,athenz-authorizer athenz-authzenvoy athenz-authzwebhook athenz-authzproxy athenz-client,$(eval $(call deploy-workload,$(w))))

# Test targets
define test-workload
test-$(1):
	@$$(MAKE) -C $(1) test-$(1)
endef

$(foreach w,athenz-authorizer athenz-authzenvoy athenz-authzwebhook athenz-authzproxy athenz-client,$(eval $(call test-workload,$(w))))

WORKLOADS := athenz-authorizer athenz-authzenvoy athenz-authzwebhook athenz-authzproxy athenz-client

setup-athenz-workloads:
	@for w in $(WORKLOADS); do $(MAKE) -C $$w register-$$w; done
	@for w in $(WORKLOADS); do $(MAKE) -C $$w check-register-$$w; done

deploy-athenz-workloads: test-athenz-identityprovider
	@for w in $(WORKLOADS); do $(MAKE) -C $$w deploy-$$w; done

test-athenz-workloads:
	@for w in $(WORKLOADS); do $(MAKE) -C $$w test-$$w; done

# ============================================================
# Tests
# ============================================================

test-athenz-zms-server:
	$(ATHENZ_CLI) curl -sf \
		-H"Content-type: application/json" \
		-H"X-Auth-Request-Preferred-Username: user.athenz_admin" \
		https://athenz-zms-server.athenz:4443/zms/v1/domain
	@echo

test-athenz-zts-server:
	$(ATHENZ_CLI) curl -sf \
		-H"Content-type: application/json" \
		-H"X-Auth-Request-Preferred-Username: user.athenz_admin" \
		https://athenz-zts-server.athenz:4443/zts/v1/domain/sys.auth/service
	@echo

test-zms-cli:
	$(ZMS_CLI) show-domain sys.auth

test-athenz-ui:
	$(ATHENZ_CLI) curl -sf \
		-H"X-Auth-Request-Preferred-Username: athenz_admin" \
		-H"X-Auth-Request-Email: athenz_admin@www.athenz.io" \
		https://athenz-ui.athenz:443/ \
	| grep -E "<title>Athenz</title>" >/dev/null \
	&& echo "Athenz UI successfully displayed"

test-zts-roletoken:
	$(ATHENZ_CLI) zts-roletoken \
		-zts https://athenz-zts-server.athenz:4443/zts/v1 \
		-svc-key-file /var/run/athenz/athenz_admin.private.pem \
		-svc-cert-file /var/run/athenz/athenz_admin.cert.pem \
		-domain sys.auth -role admin \
	| rev | cut -d';' -f2- | rev | tr ';' '\n'

test-zts-accesstoken:
	$(ATHENZ_CLI) zts-accesstoken \
		-zts https://athenz-zts-server.athenz:4443/zts/v1 \
		-svc-key-file /var/run/athenz/athenz_admin.private.pem \
		-svc-cert-file /var/run/athenz/athenz_admin.cert.pem \
		-domain sys.auth -roles admin \
	| jq -r .access_token | jq -Rr 'split(".") | .[0,1] | @base64d' | jq -r .

test-jwks:
	$(ATHENZ_CLI) curl -sf \
		-H"Content-type: application/json" \
		--key /var/run/athenz/athenz_admin.private.pem \
		--cert /var/run/athenz/athenz_admin.cert.pem \
		"https://athenz-zts-server.athenz:4443/zts/v1/oauth2/keys?rfc=true" \
	| tee ./jwks.json | jq -r .

test-policies:
	$(ATHENZ_CLI) curl -sfXPOST \
		-H "Content-type: application/json" \
		-d'{"policyVersions":{"":""}}' \
		--key /var/run/athenz/athenz_admin.private.pem \
		--cert /var/run/athenz/athenz_admin.cert.pem \
		"https://athenz-zts-server.athenz:4443/zts/v1/domain/sys.auth/policy/signed" \
	| jq -r '[.protected,.payload,.signature] | join(".")' \
	| jq -Rr 'split(".") | .[0,1] | @base64d' | jq -r .

test-verify: test-jwks
	$(ATHENZ_CLI) zts-accesstoken \
		-zts https://athenz-zts-server.athenz:4443/zts/v1 \
		-svc-key-file /var/run/athenz/athenz_admin.private.pem \
		-svc-cert-file /var/run/athenz/athenz_admin.cert.pem \
		-domain sys.auth -roles admin \
	| jq -r .access_token \
	| step crypto jws verify --jwks=jwks.json \
	&& printf "\nValid Access Token\n" || printf "\nInvalid Access Token\n"
	@echo ""
	$(ATHENZ_CLI) curl -sfXPOST \
		-H "Content-type: application/json" \
		-d'{"policyVersions":{"":""}}' \
		--key /var/run/athenz/athenz_admin.private.pem \
		--cert /var/run/athenz/athenz_admin.cert.pem \
		"https://athenz-zts-server.athenz:4443/zts/v1/domain/sys.auth/policy/signed" \
	| jq -r '[.protected,.payload,.signature] | join(".")' \
	| step crypto jws verify --jwks=jwks.json \
	&& printf "\nValid Policy\n" || printf "\nInvalid Policy\n"

test-athenz-servers: check-athenz test-athenz-zms-server test-athenz-zts-server
	@printf "\n*** Athenz APIs are functioning ***\n\n"

test-athenz: test-athenz-servers test-zms-cli test-athenz-ui test-zts-accesstoken test-policies test-verify

# ============================================================
# Envoy showcase tests
# ============================================================

define envoy-test
	$(ATHENZ_CLI) /bin/sh -c "curl -s https://client.athenz.svc.cluster.local/$(1)" | jq -r .request \
		|| (kubectl -n athenz logs deployment/$(2) --all-containers=true && false)
endef

test-athenz-envoy2echoserver:
	$(call envoy-test,client2echoserver,client-deployment)
	@printf "\n*** Envoy Showcase is functioning ***\n\n"

test-athenz-envoy2envoyextauthz:
	$(call envoy-test,client2extauthz,authorizer-deployment)
	$(call envoy-test,client2extauthzmtls,authorizer-deployment)
	@printf "\n*** Envoy Showcase is functioning ***\n\n"

test-athenz-envoy2envoyfilter:
	$(call envoy-test,client2filterauthzmtls,authzenvoy-deployment)
	$(call envoy-test,client2filterauthzjwt,authzenvoy-deployment)
	$(call envoy-test,client2filterauthzmtlsjwt,authzenvoy-deployment)

test-athenz-envoy2envoywebhook:
	$(call envoy-test,client2webhookauthzmtls,authzwebhook-deployment)
	$(call envoy-test,client2webhookauthzjwt,authzwebhook-deployment)
	$(call envoy-test,client2webhookauthzmtlsjwt,authzwebhook-deployment)
	@printf "\n*** Envoy Showcase is functioning ***\n\n"

test-athenz-envoy2authzproxy:
	$(call envoy-test,client2authzproxy,authzproxy-deployment)
	@printf "\n*** Envoy Showcase is functioning ***\n\n"

test-athenz-showcases: test-athenz-workloads test-athenz-envoy2echoserver test-athenz-envoy2envoyextauthz test-athenz-envoy2envoyfilter test-athenz-envoy2authzproxy

# ============================================================
# Load test
# ============================================================

deploy-athenz-loadtest:
	@$(MAKE) -C loadtest deploy-athenz-loadtest test-athenz-loadtest

test-athenz-envoy-loadtest:
	@$(MAKE) -C loadtest run-athenz-envoy-loadtest

test-athenz-loadtest:
	@$(MAKE) -C loadtest run-athenz-envoy-loadtest run-athenz-sidecar-loadtest run-athenz-envoyfilter-loadtest run-athenz-envoywebhook-loadtest run-athenz-authzproxy-loadtest run-athenz-echoserver-loadtest run-athenz-loadtest

report-athenz-loadtest:
	@$(MAKE) -C loadtest report-athenz-envoy-loadtest report-athenz-sidecar-loadtest report-athenz-envoyfilter-loadtest report-athenz-envoywebhook-loadtest report-athenz-authzproxy-loadtest report-athenz-echoserver-loadtest report-athenz-loadtest

# ============================================================
# Utility
# ============================================================

install-kustomize:
	which kustomize || (curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash && chmod a+x kustomize && mv kustomize ~/.local/bin/)
