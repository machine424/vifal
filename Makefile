BINARY             = vifal
GOLANGCI_LINT_VERSION = v2.12.1
GO_LICENSES_VERSION   = v2.0.1
GO_BUILD_FLAGS     ?=
GO_LDFLAGS         ?= -s -w
TIMEOUT_CMD        = timeout --foreground
.PHONY: build build-debug build-race clean test unit-test e2e-test e2e-test-go e2e-test-shell e2e-test-shell-debug e2e-test-shell-nocache lint shellcheck licenses-check

build:
	go build $(GO_BUILD_FLAGS) -ldflags="$(GO_LDFLAGS)" -o $(BINARY) .

build-debug:
	$(MAKE) --no-print-directory build GO_LDFLAGS=

build-race:
	$(MAKE) --no-print-directory build GO_BUILD_FLAGS=-race GO_LDFLAGS=

test: unit-test e2e-test

unit-test:
	go test -race -v -count=1 -timeout 1m ./...

e2e-test: e2e-test-go e2e-test-shell

e2e-test-go:
	go test -tags e2e -race -v -count=1 -timeout 3m ./...

e2e-test-shell:
	$(TIMEOUT_CMD) 15m bash e2e/run.sh $(E2E_TESTS)

e2e-test-shell-debug:
	VIFAL_E2E_DEBUG=1 $(MAKE) --no-print-directory e2e-test-shell

e2e-test-shell-nocache:
	CACHE_TTL=0s CACHE_WAIT=0 $(MAKE) --no-print-directory e2e-test-shell

lint:
	gofmt -w .
	@golangci-lint version >/dev/null 2>&1 || \
		go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	golangci-lint run
	$(MAKE) --no-print-directory shellcheck

shellcheck:
	shellcheck --shell=bash --external-sources --severity=warning e2e/*.sh e2e/tests/*.sh

# If this fails, run: go-licenses save ./... --save_path=LICENSES --ignore github.com/machine424/vifal
licenses-check:
	go install github.com/google/go-licenses/v2@$(GO_LICENSES_VERSION)
	go-licenses check ./...
	rm -rf LICENSES.tmp
	go-licenses save ./... --save_path=LICENSES.tmp --ignore github.com/machine424/vifal
	diff -rq LICENSES LICENSES.tmp
	rm -rf LICENSES.tmp
