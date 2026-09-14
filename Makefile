.DEFAULT_GOAL := help
SHELL := /bin/bash

TOOL    := herald
SKILL   := skills/herald/SKILL.md
VERSION := $(shell cat version.txt)

.PHONY: help syntax lint test skill-sync sync-skill private-scan ci version clean

help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

syntax: ## parse-check the shell sources
	@bash -n $(TOOL) && bash -n install.sh && echo "syntax: ok"

lint: ## shellcheck (skipped if not installed)
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning $(TOOL) install.sh && echo "lint: clean"; \
	else echo "lint: shellcheck not installed — skipped"; fi

test: ## run the test suite
	@./test/run-tests.sh

skill-sync: ## FAIL if the embedded skill has drifted from $(SKILL)
	@./$(TOOL) skill show | diff -u - $(SKILL) >/dev/null \
	  && echo "skill-sync: embedded copy matches $(SKILL)" \
	  || { echo "skill-sync: DRIFT — embedded skill differs from $(SKILL)"; \
	       echo "  run 'make sync-skill' and commit the result"; \
	       ./$(TOOL) skill show | diff -u - $(SKILL) | head -40; exit 1; }

sync-skill: ## re-embed $(SKILL) into $(TOOL) (run after editing the skill)
	@python3 tools/embed-skill.py && echo "sync-skill: re-embedded $(SKILL) into $(TOOL)"

version: ## print the version, and check the script agrees with version.txt
	@echo "version.txt: $(VERSION)"
	@./$(TOOL) --version
	@./$(TOOL) --version | grep -qx "herald $(VERSION)" \
	  || { echo "MISMATCH: HERALD_VERSION in $(TOOL) != version.txt"; exit 1; }

private-scan: ## FAIL if a private/internal name has crept into this public repo
	@./tools/private-scan.sh

ci: syntax lint private-scan skill-sync version test ## everything CI runs

clean: ## remove build/test leftovers
	@rm -rf dist .orig *.tmp && echo "clean: done"
