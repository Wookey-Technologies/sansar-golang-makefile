THIS_DIR := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))

LINDEN_RCS := github.com
LINDEN_MODULES := $(LINDEN_RCS)/Wookey-Technologies
MODULE_NAME := $(LINDEN_MODULES)/$(APP_NAME)
MODULE_SRC := src/$(MODULE_NAME)
DOCKER_REGISTRY ?= 375179474613.dkr.ecr.us-west-2.amazonaws.com

DEFAULT_GOPATH = /tmp/gobuild-$(APP_NAME)-$(USER)
export GOPATH ?= $(DEFAULT_GOPATH)

GODEP ?= true
ifeq (,$(filter $(GODEP), 1 true))
GODEP_CMD =
else
GODEP_CMD = godep
endif

GO ?= go

.PHONY: all
all: gotest gobuild

define MODULE_OVERRIDE
GO_OVERRIDES := $$(GO_OVERRIDES) $(GOPATH)/src/$($(1)_MODULE)
$(GOPATH)/src/$($(1)_MODULE): | $(GOPATH)/$(MODULE_SRC)
	mkdir -p $$(dir $$@)
	git clone --branch=$($(1)_BRANCH) $($(1)_REPO) $$@
endef

$(foreach module,$(MODULE_OVERRIDES),$(eval $(call MODULE_OVERRIDE,$(module))))

GOLANG_MINOR_VERSION ?= 1.10

ifneq (,$(WRAPPER_VERSION))

BUILD_IMAGE_BASE ?= gobuild:1.10.4
WRAPPER_BRANCH ?= Backend   # By default, pull latest from this branch.
WRAPPER_IMAGE ?= sansar/golang-cpp
WRAPPER_MODULE ?= backend-golang-cpp
WRAPPER_COMPILER ?= gcc
WRAPPER_CONFIGURATION ?= debug
WRAPPER_TAG := $(WRAPPER_CONFIGURATION)_$(WRAPPER_COMPILER)_golang$(GOLANG_MINOR_VERSION)_$(WRAPPER_VERSION)_$(WRAPPER_BRANCH)

BACKEND_MODULE = $(LINDEN_MODULES)/$(WRAPPER_MODULE)
WRAPPERS = $(GOPATH)/src/$(BACKEND_MODULE)
WORKSPACE=$(THIS_DIR)/vendor
GODEP_WRAPPERS = $(WORKSPACE)/pkg/linux_amd64/$(BACKEND_MODULE)
define GET_WRAPPERS
$(1): $(GOPATH)/$(MODULE_SRC)
	docker pull $(DOCKER_REGISTRY)/$(WRAPPER_IMAGE):$(WRAPPER_TAG)
	cd "$(2)" && docker save $(DOCKER_REGISTRY)/$(WRAPPER_IMAGE):$(WRAPPER_TAG) | tar -xv --wildcards --to-stdout */layer.tar | tar --strip-components=1 -xv
endef
$(eval $(call GET_WRAPPERS,$(WRAPPERS),$(GOPATH)))
$(eval $(call GET_WRAPPERS,$(GODEP_WRAPPERS),$(WORKSPACE)))

.PHONY: wrappers gowrappers
gowrappers: wrappers
wrappers:
	rm -rf $(WRAPPERS)
	$(MAKE) $(WRAPPERS)

gosave_wrappers:
	REV=$$(cd $(WRAPPERS) && git rev-parse HEAD) && \
		sed -i "s/$$REV/$(WRAPPER_VERSION)/" Godeps/Godeps.json

GO_OVERRIDES := $(GO_OVERRIDES) $(WRAPPERS)
WRAPPER_GOSAVE := gosave_wrappers
ifneq (,$(filter $(GODEP), 1 true))
GODEP_OVERRIDES = $(GODEP_WRAPPERS)
endif

else
BUILD_IMAGE_BASE ?= gobuild:1.10.4
endif

DOCKER ?= true
ifeq (,$(filter $(DOCKER), 1 true))

BUILD := cd $(GOPATH)/$(MODULE_SRC) &&

ifeq (,$(wildcard $(GOPATH)/$(MODULE_SRC)/*))
$(shell rmdir $(GOPATH)/$(MODULE_SRC) || rm -f $(GOPATH)/$(MODULE_SRC))
endif

$(GOPATH)/$(MODULE_SRC):
	mkdir -p $(dir $@)
	ln -s $(THIS_DIR) $@

GODEP_BIN := $(GOPATH)/bin/godep
DEPS := $(GODEP_BIN)

$(GODEP_BIN):
	$(GO) get -v github.com/tools/godep

else

UID := $(shell id -u)
GID := $(shell id -g)
USERNAME := $(shell getent passwd $(UID) | cut -d: -f1)
GROUPNAME := $(shell getent group $(GID) | cut -d: -f1)

ifneq (,$(SSH_AUTH_SOCK))
SSH_PARAMS := -v "$(SSH_AUTH_SOCK)":"$(SSH_AUTH_SOCK)" \
        --env SSH_AGENT_PID="$(SSH_AGENT_PID)" \
        --env SSH_AUTH_SOCK="$(SSH_AUTH_SOCK)" \
        --env SSH_CLIENT="$(SSH_CLIENT)" \
        --env SSH_CONNECTION="$(SSH_CONNECTION)" \
        --env SSH_TTY="$(SSH_TTY)"
SSH_BUILD := RUN ssh-keyscan github.com > /home/$(USERNAME)/.ssh/known_hosts && \
    git config --global url."git@github.com:".insteadOf "https://github.com/"
endif

define DOCKERFILE
FROM $(DOCKER_REGISTRY)/$(BUILD_IMAGE_BASE)
RUN ( groupadd --gid $(GID) $(GROUPNAME) || true ) && \
    ( useradd --uid $(UID) --home-dir /home/$(USERNAME) $(USERNAME) -g $(GROUPNAME) || true ) && \
    mkdir -p /home/$(USERNAME)/.ssh "/go/$(MODULE_SRC)" && \
    chmod 700 /home/$(USERNAME)/.ssh && \
    chown -R $(USERNAME):$(GROUPNAME) /go /home/$(USERNAME)
USER $(USERNAME):$(GROUPNAME)
WORKDIR /go/$(MODULE_SRC)
RUN go get -v github.com/tools/godep
USER root
RUN cp "/go/bin/godep" /usr/bin
USER $(USERNAME):$(GROUPNAME)
$(SSH_BUILD)
endef

DOCKER_MD5 := $(shell echo '$(DOCKERFILE)' | md5sum | cut -d' ' -f1)
DEV_IMAGE := gobuild-$(APP_NAME)-$(USER):$(DOCKER_MD5)

DOCKER_STAMP := $(DOCKER_MD5).stamp
DEPS := $(DOCKER_STAMP)

export DOCKERFILE
$(DOCKER_STAMP): $(GOPATH)/$(MODULE_SRC)
	echo "$$DOCKERFILE" | docker build -t $(DEV_IMAGE) -
	touch $@

BUILD := docker run -i --rm -v "$(GOPATH)":/go $(SSH_PARAMS) \
        -v "$(THIS_DIR)":"/go/$(MODULE_SRC)" $(DEV_IMAGE)

$(shell test -L $(GOPATH)/$(MODULE_SRC) && rm -f $(GOPATH)/$(MODULE_SRC))

$(GOPATH)/$(MODULE_SRC):
	mkdir -p $@
endif

DEPS := $(DEPS) $(GOPATH)/$(MODULE_SRC)

.PHONY: gosave godep_gosave
godep_gosave: PATH:=$(GOPATH)/bin:$(PATH)
godep_gosave: | $(DEPS)
	$(BUILD) godep save ./...

gosave: godep_gosave $(WRAPPER_GOSAVE) | $(DEPS)

.PHONY: goupdate
goupdate: PATH:=$(GOPATH)/bin:$(PATH)
goupdate: GODEPURI:=$(patsubst %/...,%,$(URI))
goupdate: EMPTY:=
goupdate: SPACE:=$(EMPTY) $(EMPTY)
goupdate: PIPE:=$(EMPTY)\\\|$(EMPTY)
goupdate: | $(DEPS)
	test -e $(DEFAULT_GOPATH)/src/$(GODEPURI) && \
		mkdir -p Godeps/vendor/src/$(GODEPURI) && \
		cp -r $(DEFAULT_GOPATH)/src/$(GODEPURI)/*.go Godeps/vendor/src/$(GODEPURI) && \
		OLDREV=$$( cd $(DEFAULT_GOPATH)/src/$(GODEPURI) && git rev-parse HEAD^^ ) && \
		REV=$$( cd $(DEFAULT_GOPATH)/src/$(GODEPURI) && git rev-parse HEAD ) && \
		REVHIST=\($$( cd $(DEFAULT_GOPATH)/src/$(GODEPURI) && git log --pretty="%H" -10 | xargs echo -n  | sed -e "s/$(SPACE)/$(PIPE)/g" )\) && \
		echo "HEAD is $$REV" && \
		echo "HEAD^^ is $$OLDREV" && \
		echo "Revision history is $$REVHIST" && \
		sed -i.bak "s/$$REVHIST/$$REV/g" Godeps/Godeps.json

.PHONY: gorestore
gorestore: PATH:=$(GOPATH)/bin:$(PATH)
gorestore: $(GO_OVERRIDES) | $(DEPS)
	$(BUILD) godep restore

.PHONY: goget
goget: $(GO_OVERRIDES) | $(DEPS)
	$(BUILD) $(GO) get -v -t

.PHONY: gobuild
gobuild: PATH:=$(GOPATH)/bin:$(PATH)
gobuild: $(GODEP_OVERRIDES) | $(DEPS)
	$(BUILD) $(GODEP_CMD) $(GO) install -v
	cp $(GOPATH)/bin/$(APP_NAME) .

.PHONY: gotest
gotest: PATH:=$(GOPATH)/bin:$(PATH)
gotest: $(GODEP_OVERRIDES) | $(DEPS)
	$(BUILD) $(GODEP_CMD) $(GO) test -v ./...

.PHONY: clean
clean:
	rm -f $(APP_NAME) *.stamp $(GOPATH)/$(MODULE_SRC)/*.stamp
	rm -rf $(DEFAULT_GOPATH) $(CLEAN_DEPS)

