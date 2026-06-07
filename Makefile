# verbinal-execution -- build / test / publish helpers.
#
# Override on the command line, e.g.:
#   make push REGISTRY=images.canfar.net PROJECT=private-test TAG=0.0.2

REGISTRY ?= images.canfar.net
PROJECT  ?= private-test
NAME     ?= verbinal-execution
TAG      ?= 0.0.1
IMAGE    := $(REGISTRY)/$(PROJECT)/$(NAME):$(TAG)
DEV_IMAGE := $(NAME):dev
PLATFORM := linux/amd64
UID      ?= 4321

.PHONY: build push test checklist integration imports clean

## Build a local dev image (linux/amd64).
build:
	docker buildx build --platform $(PLATFORM) -t $(DEV_IMAGE) .

## Build a clean single-arch image and push it to the registry.
push:
	docker build --platform $(PLATFORM) --provenance=false --sbom=false -t $(IMAGE) .
	docker push $(IMAGE)

## Run all test suites inside the dev image (as a non-root uid, like Skaha).
test: checklist integration imports

checklist: build
	docker run --rm -u $(UID):$(UID) -v "$(CURDIR)":/src:ro --entrypoint bash $(DEV_IMAGE) /src/test/checklist.sh

integration: build
	docker run --rm -u $(UID):$(UID) -v "$(CURDIR)":/src:ro --entrypoint bash $(DEV_IMAGE) /src/test/integration.sh

imports: build
	docker run --rm -u $(UID):$(UID) -v "$(CURDIR)":/src:ro --entrypoint bash $(DEV_IMAGE) /src/test/imports.sh

## Remove the local dev image.
clean:
	-docker image rm $(DEV_IMAGE)
