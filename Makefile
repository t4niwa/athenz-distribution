ifeq ($(wildcard athenz),)
SUBMODULE := $(shell git submodule add --force https://github.com/AthenZ/athenz.git athenz)
endif

ifeq ($(VERSION),)
VERSION := $(shell git submodule status | sed 's/^.* athenz (.*v\([0-9]*\.[0-9]*\.[0-9]*\).*)/\1/g')
endif

ifeq ($(PATCH),)
PATCH := true
endif

ifeq ($(PUSH),)
PUSH := true
endif
ifeq ($(PUSH),true)
PUSH_OPTION := --push
endif

# GID and UID of the default athenz:athenz user inside the container
GID=$(DOCKER_GID)
UID=$(DOCKER_UID)
GID_ARG := $(if $(GID),--build-arg GID=$(GID),--build-arg GID)
UID_ARG := $(if $(UID),--build-arg UID=$(UID),--build-arg UID)

BUILD_DATE=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
VCS_REF=$(shell cd athenz && git rev-parse --short HEAD)
XPLATFORM_ARGS := --platform=linux/amd64,linux/arm64
BUILD_ARG := --build-arg 'BUILD_DATE=$(BUILD_DATE)' --build-arg 'VCS_REF=$(VCS_REF)' --build-arg 'VERSION=$(VERSION)' $(XPLATFORM_ARGS) $(PUSH_OPTION)

ifeq ($(DOCKER_REGISTRY),)
DOCKER_REGISTRY=ghcr.io/$${USER}/
endif

ifeq ($(DOCKER_TAG),)
ifneq ($(VERSION),)
DOCKER_TAG=:v$(VERSION)
else
DOCKER_TAG=:latest
endif
endif

ifeq ($(GOPATH),)
GOPATH=$(shell go env GOPATH | sed -e "s/'//g")
export GOPATH
endif

ifeq ($(GOCACHE),)
GOCACHE=$(shell go env GOCACHE | sed -e "s/'//g")
export GOCACHE
endif

.PHONY: build

.SILENT: version

build: athenz-db athenz-zms-server athenz-zts-server athenz-cli athenz-ui

athenz-db:
	IMAGE_NAME=$(DOCKER_REGISTRY)athenz-db$(DOCKER_TAG); \
	LATEST_IMAGE_NAME=$(DOCKER_REGISTRY)athenz-db:latest; \
	DOCKERFILE_PATH=./docker/db/Dockerfile; \
	DOCKER_BUILDKIT=1 docker buildx build $(BUILD_ARG) $(GID_ARG) $(UID_ARG) --cache-from $$IMAGE_NAME -t $$IMAGE_NAME -t $$LATEST_IMAGE_NAME -f $$DOCKERFILE_PATH .

athenz-zms-server: build-java
	IMAGE_NAME=$(DOCKER_REGISTRY)athenz-zms-server$(DOCKER_TAG); \
	LATEST_IMAGE_NAME=$(DOCKER_REGISTRY)athenz-zms-server:latest; \
	DOCKERFILE_PATH=./docker/zms/Dockerfile; \
	DOCKER_BUILDKIT=1 docker buildx build $(BUILD_ARG) $(GID_ARG) $(UID_ARG) --cache-from $$IMAGE_NAME -t $$IMAGE_NAME -t $$LATEST_IMAGE_NAME -f $$DOCKERFILE_PATH .

athenz-zts-server: build-java
	IMAGE_NAME=$(DOCKER_REGISTRY)athenz-zts-server$(DOCKER_TAG); \
	LATEST_IMAGE_NAME=$(DOCKER_REGISTRY)athenz-zts-server:latest; \
	DOCKERFILE_PATH=./docker/zts/Dockerfile; \
	DOCKER_BUILDKIT=1 docker buildx build $(BUILD_ARG) $(GID_ARG) $(UID_ARG) --cache-from $$IMAGE_NAME -t $$IMAGE_NAME -t $$LATEST_IMAGE_NAME -f $$DOCKERFILE_PATH .

athenz-ui:
	IMAGE_NAME=$(DOCKER_REGISTRY)athenz-ui$(DOCKER_TAG); \
	LATEST_IMAGE_NAME=$(DOCKER_REGISTRY)athenz-ui:latest; \
	DOCKERFILE_PATH=./docker/ui/Dockerfile; \
	DOCKER_BUILDKIT=1 docker buildx build $(BUILD_ARG) $(GID_ARG) $(UID_ARG) --cache-from $$IMAGE_NAME -t $$IMAGE_NAME -t $$LATEST_IMAGE_NAME -f $$DOCKERFILE_PATH .

athenz-cli: build-go
	IMAGE_NAME=$(DOCKER_REGISTRY)athenz-cli$(DOCKER_TAG); \
	LATEST_IMAGE_NAME=$(DOCKER_REGISTRY)athenz-cli:latest; \
	DOCKERFILE_PATH=./docker/cli/Dockerfile; \
	DOCKER_BUILDKIT=1 docker buildx build $(BUILD_ARG) $(GID_ARG) $(UID_ARG) --cache-from $$IMAGE_NAME -t $$IMAGE_NAME -t $$LATEST_IMAGE_NAME -f $$DOCKERFILE_PATH .

install-rdl-tools:
	go install github.com/ardielle/ardielle-go/...@master && \
	go install github.com/ardielle/ardielle-tools/...@master && \
	export PATH=$$PATH:$$GOPATH
	mkdir -p athenz/clients/go/zms/bin && \
	cp $$GOPATH/bin/rdl* athenz/clients/go/zms/bin/ && \
	mkdir -p athenz/clients/go/zts/bin && \
	cp $$GOPATH/bin/rdl* athenz/clients/go/zts/bin/ && \
	mkdir -p athenz/clients/go/msd/bin && \
	cp $$GOPATH/bin/rdl* athenz/clients/go/msd/bin/ && \
	chmod a+x athenz/clients/go/*/bin/*

patch:
	$(PATCH) && rsync -av --exclude=".gitkeep" patchfiles/* athenz

build-java: checkout-version install-rdl-tools patch
	mvn -B clean install \
		-f athenz/pom.xml \
		-Dproject.basedir=athenz \
		-Dproject.build.directory=athenz \
		-Dmaven.test.skip=true \
		-Djacoco.skip=true \
		-Dcheckstyle.skip \
		-pl core/zms \
		-pl core/zts \
		-pl core/msd \
		-pl rdl/rdl-gen-athenz-java-model \
		-pl rdl/rdl-gen-athenz-java-client \
		-pl clients/java/zms \
		-pl clients/java/zts \
		-pl libs/java/auth_core \
		-pl libs/java/client_common \
		-pl libs/java/server_common \
		-pl libs/java/instance_provider \
		-pl libs/java/cert_refresher \
		-pl libs/java/dynamodb_client_factory \
		-pl rdl/rdl-gen-athenz-server \
		-pl servers/zms \
		-pl servers/zts \
		-pl containers/jetty \
		-pl assembly/zms \
		-pl assembly/zts

build-go: submodule-update install-rdl-tools
	go install github.com/ardielle/ardielle-go/...@master && \
	go install github.com/ardielle/ardielle-tools/...@master && \
	mkdir -p athenz/clients/go/zms/bin && \
	cp $$GOPATH/bin/rdl* athenz/clients/go/zms/bin/ && \
	mkdir -p athenz/clients/go/zts/bin && \
	cp $$GOPATH/bin/rdl* athenz/clients/go/zts/bin/ && \
	mkdir -p athenz/clients/go/msd/bin && \
	cp $$GOPATH/bin/rdl* athenz/clients/go/msd/bin/ && \
	mvn -B install \
		-f athenz/pom.xml \
		-Dproject.basedir=athenz \
		-Dproject.build.directory=athenz \
		-Dmaven.test.skip=true \
		-Djacoco.skip=true \
		-pl core/zms \
		-pl core/zts \
		-pl core/msd \
		-pl rdl/rdl-gen-athenz-go-model \
		-pl rdl/rdl-gen-athenz-go-client \
		-pl rdl/rdl-gen-athenz-java-model \
		-pl clients/go/zms \
		-pl clients/go/zts \
		-pl clients/go/msd \
		-pl libs/go/zmscli \
		-pl libs/go/athenzutils \
		-pl libs/go/athenzconf \
		-pl utils/zms-cli \
		-pl utils/athenz-conf \
		-pl utils/zts-accesstoken \
		-pl utils/zts-rolecert \
		-pl utils/zts-svccert \
		-pl assembly/utils

clean: checkout
	mvn -B clean \
		-f athenz/pom.xml \
		-Dproject.basedir=athenz \
		-Dproject.build.directory=athenz \
		-Dmaven.test.skip=true -Djacoco.skip=true \
		-Djacoco.skip=true

diff:
	@diff athenz patchfiles

checkout:
	@cd athenz/ && git checkout .

submodule-update: checkout
	@git submodule update --init

checkout-version: submodule-update
	@cd athenz/ && git fetch --refetch --tags origin && git checkout v$(VERSION)

version:
	@echo "Version: $(VERSION)"
	@echo "Tag Version: v$(VERSION)"

install-jq:
	curl -s https://webi.sh/jq | sh

install-yq:
	curl -s https://webi.sh/yq | sh

clean-certificates:
	rm -rf keys certs
	rm -rf k8s/athenz-cli/kustomize/{keys,certs}
	rm -rf k8s/athenz-zms-server/kustomize/{keys,certs}
	rm -rf k8s/athenz-zts-server/kustomize/{keys,certs}

generate-ca:
	mkdir keys certs ||:
	openssl genrsa -out keys/ca.private.pem 4096 \
	&& openssl rsa -pubout -in keys/ca.private.pem -out keys/ca.public.pem \
	&& openssl req -new -x509 -days 99999 -config openssl/ca.openssl.config -extensions ext_req -key keys/ca.private.pem -out certs/ca.cert.pem

generate-zms: generate-ca
	mkdir keys certs ||:
	openssl genrsa -out keys/zms.private.pem 4096 \
	&& openssl rsa -pubout -in keys/zms.private.pem -out keys/zms.public.pem \
	&& openssl req -config openssl/zms.openssl.config -new -key keys/zms.private.pem -out certs/zms.csr.pem -extensions ext_req \
	&& openssl x509 -req -in certs/zms.csr.pem -CA certs/ca.cert.pem -CAkey keys/ca.private.pem -CAcreateserial -out certs/zms.cert.pem -days 99999 -extfile openssl/zms.openssl.config -extensions ext_req \
	&& openssl verify -CAfile certs/ca.cert.pem certs/zms.cert.pem \
	&& openssl pkcs12 -export -out certs/zms_keystore.pkcs12 -in certs/zms.cert.pem -inkey keys/zms.private.pem -noiter -password pass:athenz \
	&& keytool -import -noprompt -file certs/ca.cert.pem -alias ca -keystore certs/zms_truststore.jks -storepass athenz \
	&& keytool --list -keystore certs/zms_truststore.jks -storepass athenz

generate-zts: generate-zms
	mkdir keys certs ||:
	openssl genrsa -out keys/zts.private.pem 4096 \
	&& openssl rsa -pubout -in keys/zts.private.pem -out keys/zts.public.pem \
	&& openssl req -config openssl/zts.openssl.config -new -key keys/zts.private.pem -out certs/zts.csr.pem -extensions ext_req \
	&& openssl x509 -req -in certs/zts.csr.pem -CA certs/ca.cert.pem -CAkey keys/ca.private.pem -CAcreateserial -out certs/zts.cert.pem -days 99999 -extfile openssl/zts.openssl.config -extensions ext_req \
	&& openssl verify -CAfile certs/ca.cert.pem certs/zts.cert.pem \
	&& openssl pkcs12 -export -out certs/zts_keystore.pkcs12 -in certs/zts.cert.pem -inkey keys/zts.private.pem -noiter -password pass:athenz \
	&& openssl pkcs12 -export -out certs/zms_client_keystore.pkcs12 -in certs/zts.cert.pem -inkey keys/zts.private.pem -noiter -password pass:athenz \
	&& openssl pkcs12 -export -out certs/zts_signer_keystore.pkcs12 -in certs/zts.cert.pem -inkey keys/zts.private.pem -noiter -password pass:athenz \
	&& keytool -import -noprompt -file certs/ca.cert.pem -alias ca -keystore certs/zts_truststore.jks -storepass athenz \
	&& keytool -import -noprompt -file certs/ca.cert.pem -alias ca -keystore certs/zms_client_truststore.jks -storepass athenz \
	&& keytool --list -keystore certs/zts_truststore.jks -storepass athenz

generate-admin: generate-ca
	mkdir keys certs ||:
	openssl genrsa -out keys/athenz_admin.private.pem 4096 \
	&& openssl rsa -pubout -in keys/athenz_admin.private.pem -out keys/athenz_admin.public.pem \
	&& openssl req -config openssl/athenz_admin.openssl.config -new -key keys/athenz_admin.private.pem -out certs/athenz_admin.csr.pem -extensions ext_req \
	&& openssl x509 -req -in certs/athenz_admin.csr.pem -CA certs/ca.cert.pem -CAkey keys/ca.private.pem -CAcreateserial -out certs/athenz_admin.cert.pem -days 99999 -extfile openssl/athenz_admin.openssl.config -extensions ext_req \
	&& openssl verify -CAfile certs/ca.cert.pem certs/athenz_admin.cert.pem

generate-certificates: generate-ca generate-zms generate-zts generate-admin

copy-to-kustomization: generate-ca generate-zms generate-zts generate-admin
	cp -r keys certs k8s/athenz-cli/kustomize/
	cp -r keys certs k8s/athenz-zms-server/kustomize/
	cp -r keys certs k8s/athenz-zts-server/kustomize/
	cp athenz/servers/zms/schema/zms_server.sql k8s/athenz-db/kustomize/zms_server.sql
	cp athenz/servers/zts/schema/zts_server.sql k8s/athenz-db/kustomize/zts_server.sql

setup-athenz-db:
	kubectl apply -k k8s/athenz-db/kustomize

setup-athenz-cli:
	kubectl apply -k k8s/athenz-cli/kustomize

setup-athenz-zms-server: setup-athenz-db
	kubectl apply -k k8s/athenz-zms-server/kustomize

setup-athenz-zts-server: setup-athenz-db setup-athenz-zms-server
	kubectl apply -k k8s/athenz-zts-server/kustomize

clean-k8s:
	kubectl delete namespace athenz ||:

setup-athenz: setup-athenz-db setup-athenz-cli setup-athenz-zms-server setup-athenz-zts-server

clean-athenz: clean-k8s clean-certificates

deploy-athenz: generate-certificates copy-to-kustomization setup-athenz

check-athenz:
	SLEEP_SECONDS=5; \
WAITING_THRESHOLD=600; \
i=0; \
while [ $$(( $$(kubectl -n athenz get all | grep -E "0/1" | wc -l) )) -ne 0 ]; do \
	printf "\n\n***** Waiting for athenz($${SLEEP_SECONDS}s) *****\n\n"; \
	sleep $${SLEEP_SECONDS}; \
	i=$$(( i + 1 )); \
	if [ $$i -eq $$(( $${WAITING_THRESHOLD} / $${SLEEP_SECONDS} )) ]; then \
		printf "\n\n** Waiting ($${SLEEP_SECONDS}s) reached to threshold($${WAITING_THRESHOLD}s) **\n\n"; \
		kubectl -n athenz get all; \
		kubectl -n athenz logs statefulset/athenz-db --all-containers=true; \
		kubectl -n athenz logs deployment/athenz-zms-server --all-containers=true; \
		kubectl -n athenz logs deployment/athenz-zts-server --all-containers=true; \
		echo "** Waiting(5s) reached to threshold(600s) **"; \
		exit 1; \
	fi; \
done
	kubectl -n athenz get all
	@echo ""
	@echo "**********************************"
	@echo "** Athenz Deployed Successfully **"
	@echo "**********************************"
	@echo ""

test-athenz-zms-server:
	kubectl -n athenz exec deployment/athenz-cli -it -- \
curl \
	-s \
	-H"Content-type: application/json" \
	-H"X-Auth-Request-Preferred-Username: user.athenz_admin" \
	--cacert /etc/ssl/certs/ca.cert.pem \
	https://athenz-zms-server:4443/zms/v1/domain \
| cat; echo

test-athenz-zts-server:
	kubectl -n athenz exec deployment/athenz-cli -it -- \
curl \
	-s \
	-H"Content-type: application/json" \
	-H"X-Auth-Request-Preferred-Username: user.athenz_admin" \
	--cacert /etc/ssl/certs/ca.cert.pem \
	https://athenz-zts-server:4443/zts/v1/domain/sys.auth/service \
| cat; echo

test-zms-cli:
	kubectl -n athenz exec deployment/athenz-cli -it -- \
zms-cli \
	-z https://athenz-zms-server:4443/zms/v1 \
	-key /var/run/athenz/athenz_admin.private.pem \
	-cert /var/run/athenz/athenz_admin.cert.pem \
	show-domain sys.auth

test-zts-roletoken:
	kubectl -n athenz exec deployment/athenz-cli -it -- \
zts-roletoken \
	-zts https://athenz-zts-server:4443/zts/v1 \
	-svc-key-file /var/run/athenz/athenz_admin.private.pem \
	-svc-cert-file /var/run/athenz/athenz_admin.cert.pem \
	-domain sys.auth \
	-role admin \
| rev | cut -d';' -f2- | rev \
| tr ';' '\n'

test-zts-accesstoken: install-jq
	kubectl -n athenz exec deployment/athenz-cli -it -- \
zts-accesstoken \
	-zts https://athenz-zts-server:4443/zts/v1 \
	-svc-key-file /var/run/athenz/athenz_admin.private.pem \
	-svc-cert-file /var/run/athenz/athenz_admin.cert.pem \
	-domain sys.auth \
	-roles admin \
| jq -r .access_token \
| jq -Rr 'split(".") | .[0,1] | @base64d' \
| jq -r .

test-jwks-policies:
	kubectl -n athenz exec deployment/athenz-cli -it -- \
curl \
	-s \
	-H"Content-type: application/json" \
	--cacert /etc/ssl/certs/ca.cert.pem \
	--key /var/run/athenz/athenz_admin.private.pem \
	--cert /var/run/athenz/athenz_admin.cert.pem \
	"https://athenz-zts-server:4443/zts/v1/oauth2/keys?rfc=true" \
| tee ./jwks.json \
| jq -r .
	@echo ""
	kubectl -n athenz exec deployment/athenz-cli -it -- \
curl \
	-sXPOST \
	-H "Content-type: application/json" \
	-d"{\"policyVersions\":{\"\":\"\"}}" \
	--cacert /etc/ssl/certs/ca.cert.pem \
	--key /var/run/athenz/athenz_admin.private.pem \
	--cert /var/run/athenz/athenz_admin.cert.pem \
	"https://athenz-zts-server:4443/zts/v1/domain/sys.auth/policy/signed" \
| jq -r '[.protected,.payload,.signature] | join(".")' \
| jq -Rr 'split(".") | .[0,1] | @base64d' \
| jq -r .

#| step crypto jws verify --jwks=jwks.json \
#&& printf "\nValid Policy\n" || printf "\nInvalid Policy\n"

test-athenz: test-athenz-zms-server test-athenz-zts-server
	@echo ""
	@echo "**********************************"
	@echo "** Athenz APIs are functioning  **"
	@echo "**********************************"
	@echo ""
