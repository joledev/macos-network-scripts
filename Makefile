SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

NETKIT := ./bin/netkit

.PHONY: help install install-brew doctor discover topology quality diagnose inventory report clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install: install-brew ## Install all optional dependencies
	@echo "Done. Run 'make doctor' to verify."

install-brew: ## Install optional Homebrew packages from requirements/brew.txt
	@if ! command -v brew >/dev/null 2>&1; then \
		echo "Homebrew not found. Install from https://brew.sh first."; \
		exit 1; \
	fi
	@pkgs=$$(grep -v '^[[:space:]]*#' requirements/brew.txt | grep -v '^[[:space:]]*$$' | awk '{print $$1}'); \
	echo "Installing: $$pkgs"; \
	brew install $$pkgs

doctor: ## Verify environment, tools and permissions
	@$(NETKIT) doctor

discover: ## Run safe LAN discovery
	@$(NETKIT) discover

topology: ## Map local network topology
	@$(NETKIT) topology

quality: ## Measure network quality (latency, jitter, packet loss)
	@$(NETKIT) quality

diagnose: ## Diagnostics for dev workflow (GitHub, DNS, Docker, VPN)
	@$(NETKIT) diagnose

inventory: ## Local system + tool inventory
	@$(NETKIT) inventory

report: ## Generate full report (md + json + mermaid)
	@$(NETKIT) report

clean: ## Remove generated reports (keeps .gitkeep)
	@find output -type f ! -name '.gitkeep' -delete
	@echo "Cleared output/"
