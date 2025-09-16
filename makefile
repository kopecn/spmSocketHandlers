.PHONY: help clean build test format tag version checkGitClean mermaid bump-patch bump-minor bump-major

.DEFAULT_GOAL := help

APP_NAME = spmSocketHandlers
BUILD_DIR = .build
CONFIG=./.swift-format.json

help:  ## Show available make commands with descriptions
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z0-9_-]+:.*?## / {printf "%-20s -> %s\n", $$1, $$2}' $(MAKEFILE_LIST)

clean:  ## Clean all build artifacts
	swift package clean
	rm -rf $(BUILD_DIR)

build:  ## Build the project in release mode
	swift build -c release

test:  ## Run tests
	swift test

format:  ## Format code using swift-format with explicit config
	swift-format --configuration $(CONFIG) format --in-place --recursive spm/Sources
	swift-format --configuration $(CONFIG) format --in-place --recursive spm/Tests

bump-patch:  ## Bump patch version (e.g., 1.2.3 → 1.2.4)
	@CURRENT=$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0"); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	PATCH=$$(echo $$CURRENT | cut -d. -f3); \
	NEW_VERSION="v$$MAJOR.$$MINOR.$$((PATCH + 1))"; \
	echo "Bumping to $$NEW_VERSION"; \
	git tag -a $$NEW_VERSION -m "Version $$NEW_VERSION"; \
	git push origin $$NEW_VERSION
	
bump-minor:  ## Bump minor version (e.g., 1.2.3 → 1.3.0)
	@CURRENT=$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0"); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	# PATCH is not used here but you can still get it if needed: PATCH=$$(echo $$CURRENT | cut -d. -f3); \
	NEW_VERSION="v$$MAJOR.$$((MINOR + 1)).0"; \
	echo "Bumping to $$NEW_VERSION"; \
	git tag -a $$NEW_VERSION -m "Version $$NEW_VERSION"; \
	git push origin $$NEW_VERSION

bump-major:  ## Bump major version (e.g., 1.2.3 → 2.0.0)
	@CURRENT=$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0"); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	# MINOR and PATCH are not used here but you can get them if needed: \
	# MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	# PATCH=$$(echo $$CURRENT | cut -d. -f3); \
	NEW_VERSION="v$$((MAJOR + 1)).0.0"; \
	echo "Bumping to $$NEW_VERSION"; \
	git tag -a $$NEW_VERSION -m "Version $$NEW_VERSION"; \
	git push origin $$NEW_VERSION

version:  ## Show current version from Git tag
	@echo "Current version: $$(git describe --tags --abbrev=0)"

tag: checkGitClean version  ## Tag the current version in git
	@echo "Tagging version $$(make version)"
	git tag -a v$$(make version) -m "Release v$$(make version)"
	git push origin v$$(make version)

mermaid: ## Create the mermaid layout for this project
	swift package plugin depermaid --direction TD --test --executable --product

release: clean build test  ## Full release process

checkGitClean:
	@git diff-index --quiet HEAD -- || (echo "Git working directory not clean" && exit 1)

