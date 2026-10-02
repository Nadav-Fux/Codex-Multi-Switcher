SHELL := /bin/bash

BUILD_OUT ?= /tmp/codex-multi-switcher-build-check
APP_IDENTITY ?= -
CLI_INSTALL_PATH ?= $(HOME)/.local/bin/codex-profile

.PHONY: build check test test-unit test-integration test-claude test-usage format install-cli

# Installs the CLI with an ad-hoc signature by default. A loose CLI is
# file-vault-only: it lacks the packaged helper's Keychain Sharing entitlement
# and cannot access the packaged app's Keychain vault.
install-cli:
	swift build -c release --product codex-profile
	cp "$$(swift build -c release --show-bin-path)/codex-profile" "$(CLI_INSTALL_PATH)"
	codesign --force --options runtime --identifier codex-profile \
		--sign "$(APP_IDENTITY)" "$(CLI_INSTALL_PATH)"
	codesign --verify "$(CLI_INSTALL_PATH)"

# Requires swiftformat (brew install swiftformat). Config lives in .swiftformat.
format:
	swiftformat .

build:
	./build.sh "$(BUILD_OUT)"

test: test-unit test-integration test-claude test-usage

test-unit:
	./Tests/run-swift-tests.sh

test-integration:
	./Tests/run-integration-tests.sh

test-claude:
	./Tests/run-claude-tests.sh
	python3 Tests/ClaudeStatuslineBridgeTests.py

test-usage:
	./Tests/run-usage-normalization-tests.sh
	./Tests/run-active-usage-tests.sh

check: test build
