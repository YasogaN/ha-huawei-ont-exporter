IMAGE ?= huawei-ont-exporter
ENV_FILE ?= .env

.PHONY: build run once logs status stop shell clean lint test

## build: build the container image
build:
	podman build -t $(IMAGE) .

## lint: run shellcheck on the scripts (uses a local shellcheck if present)
lint:
	command -v shellcheck >/dev/null 2>&1 && shellcheck scripts/*.sh \
		|| podman run --rm -v $(CURDIR):/w:z -w /w docker.io/koalaman/shellcheck-alpine:latest \
			sh -c 'shellcheck /w/scripts/*.sh'

## test: run the unit tests (awk parser, overhead math, golden payload)
test:
	./scripts/test.sh

## run: start the exporter as a background container
run:
	podman run -d --name $(IMAGE) --restart unless-stopped --env-file $(ENV_FILE) \
		-v /etc/localtime:/etc/localtime:ro $(IMAGE)

## once: run a single export cycle (good for testing)
once:
	podman run --rm --env-file $(ENV_FILE) $(IMAGE) /app/main.sh

## logs: follow the container logs
logs:
	podman logs -f $(IMAGE)

## status: container + health state
status:
	podman ps --filter name=$(IMAGE) --format 'table {{.Names}}\t{{.Status}}\t{{.Health}}'

## stop: stop and remove the container
stop:
	podman rm -f $(IMAGE)

## shell: open a shell inside a fresh container
shell:
	podman run --rm -it --env-file $(ENV_FILE) $(IMAGE) /bin/sh

## clean: remove the image
clean:
	podman rmi $(IMAGE)

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
