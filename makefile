.PHONY: help clean build run test format lint install release tag version checkGitClean

.DEFAULT_GOAL := help

APP_NAME = cliOTG
BUILD_DIR = .build
BIN_PATH = $(BUILD_DIR)/release/$(APP_NAME)
INSTALL_PATH = /usr/local/bin/$(APP_NAME)

help:  ## Show available make commands with descriptions
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z0-9_-]+:.*?## / {printf "%-20s -> %s\n", $$1, $$2}' $(MAKEFILE_LIST)

clean:  ## Clean all build artifacts
	swift package clean
	rm -rf $(BUILD_DIR)

build:  ## Build the project in release mode
	swift build -c release

run:  ## Run the app
	swift run

test:  ## Run tests
	swift test

format:  ## Format code using swift-format
	swift-format format --in-place --recursive Sources
	swift-format format --in-place --recursive Tests

lint:  ## Lint code (uses swift-format for simplicity)
	swift-format lint --recursive Sources
	swift-format lint --recursive Tests

bump-patch:  ## Bump patch version (e.g., 1.2.3 → 1.2.4)
	@CURRENT=$$(git describe --tags --abbrev=0 | sed 's/^v//' ); \
	IFS=. read -r MAJOR MINOR PATCH <<< $$CURRENT; \
	NEW_VERSION="v$$MAJOR.$$MINOR.$$((PATCH + 1))"; \
	echo "Bumping to $$NEW_VERSION"; \
	git tag -a $$NEW_VERSION -m "Version $$NEW_VERSION"; \
	git push origin $$NEW_VERSION

bump-minor:  ## Bump minor version (e.g., 1.2.3 → 1.3.0)
	@CURRENT=$$(git describe --tags --abbrev=0 | sed 's/^v//' ); \
	IFS=. read -r MAJOR MINOR PATCH <<< $$CURRENT; \
	NEW_VERSION="v$$MAJOR.$$((MINOR + 1)).0"; \
	echo "Bumping to $$NEW_VERSION"; \
	git tag -a $$NEW_VERSION -m "Version $$NEW_VERSION"; \
	git push origin $$NEW_VERSION

bump-major:  ## Bump major version (e.g., 1.2.3 → 2.0.0)
	@CURRENT=$$(git describe --tags --abbrev=0 | sed 's/^v//' ); \
	IFS=. read -r MAJOR MINOR PATCH <<< $$CURRENT; \
	NEW_VERSION="v$$((MAJOR + 1)).0.0"; \
	echo "Bumping to $$NEW_VERSION"; \
	git tag -a $$NEW_VERSION -m "Version $$NEW_VERSION"; \
	git push origin $$NEW_VERSION


install: build  ## Install binary to /usr/local/bin
	cp -f $(BIN_PATH) $(INSTALL_PATH)
	chmod +x $(INSTALL_PATH)

uninstall:  ## Remove installed binary
	rm -f $(INSTALL_PATH)
	
version:  ## Show current version from Git tag
	@echo "Current version: $$(git describe --tags --abbrev=0)"

tag: checkGitClean version  ## Tag the current version in git
	@echo "Tagging version $$(make version)"
	git tag -a v$$(make version) -m "Release v$$(make version)"
	git push origin v$$(make version)

mermaid: ## Create the mermaid layout for this project
	swift package plugin depermaid --direction TD --test --executable --product

release: clean build test install  ## Full release process

checkGitClean:
	@git diff-index --quiet HEAD -- || (echo "Git working directory not clean" && exit 1)

