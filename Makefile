SHELL := /usr/bin/env bash

.PHONY: app image unpack-image run-container clean

app:
	@./scripts/make.sh app

image:
	@./scripts/make.sh image

unpack-image:
	@./scripts/make.sh unpack-image

run-container:
	@./scripts/make.sh run-container

clean:
	@./scripts/make.sh clean
