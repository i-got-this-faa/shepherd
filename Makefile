SHELL := /usr/bin/env bash

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "none")
DATE    ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

MODULE := github.com/i-got-this-faa/shepherd
LDFLAGS := -X $(MODULE)/internal/version.Version=$(VERSION) \
           -X $(MODULE)/internal/version.Commit=$(COMMIT) \
           -X $(MODULE)/internal/version.Date=$(DATE)

BINARIES := shepherd shepherd-builder shepherd-node shepherd-derper shepherd-fakecp shepherd-fakenode shepherdctl

.PHONY: all build clean test lint generate check

all: build

build:
	@mkdir -p bin
	go build -ldflags "$(LDFLAGS)" -o bin/shepherd ./apps/control-plane/cmd/shepherd
	go build -ldflags "$(LDFLAGS)" -o bin/shepherd-builder ./apps/build-worker/cmd/shepherd-builder
	go build -ldflags "$(LDFLAGS)" -o bin/shepherd-node ./apps/node-daemon/cmd/shepherd-node
	go build -ldflags "$(LDFLAGS)" -o bin/shepherd-derper ./infra/networking/relays/cmd/shepherd-derper
	go build -ldflags "$(LDFLAGS)" -o bin/shepherd-fakecp ./tools/fakes/fakecp
	go build -ldflags "$(LDFLAGS)" -o bin/shepherd-fakenode ./tools/fakes/fakenode
	go build -ldflags "$(LDFLAGS)" -o bin/shepherdctl ./tools/shepherdctl

test:
	go test -v ./...

lint:
	go vet ./...

generate:
	@echo "No codegen targets configured yet."

check: lint test

clean:
	rm -rf bin/
