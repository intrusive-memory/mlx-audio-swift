# Makefile for MLXAudio Swift Package
# Uses xcodebuild exclusively (no swift build/test)

SCHEME = MLXAudio-Package
DESTINATION = 'platform=macOS'
XCODEBUILD = xcodebuild
CODE_SIGNING = CODE_SIGNING_ALLOWED=NO

BINARY = mlx-audio-swift-tts
BIN_DIR = ./bin
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
APP_GROUP_ID ?= group.intrusive-memory.models
CODESIGN_IDENTITY ?= -
CODESIGN_FLAGS ?=
CODESIGN_ENTITLEMENTS ?= cli.entitlements

# CI-safe test suites (no model downloads).
# Each suite here is verified zero-download (no fromPretrained / Acervo /
# ensureComponentReady / loadModel calls). The local-only counterpart list
# lives in bin/check-local-only-suites.sh and CLAUDE.md.
CI_TESTS = \
	-only-testing:MLXAudioTests/VocosTests \
	-only-testing:MLXAudioTests/EncodecTests \
	-only-testing:MLXAudioTests/DACVAETests \
	-only-testing:MLXAudioTests/DACVAEWatermarkerTests \
	-only-testing:MLXAudioTests/MimiLayerTests \
	-only-testing:MLXAudioTests/SNACVQTests \
	-only-testing:MLXAudioTests/ConvWeightedTests \
	-only-testing:MLXAudioTests/GLMASRModuleSetupTests \
	-only-testing:MLXAudioTests/GLMASRModelTests \
	-only-testing:MLXAudioTests/Qwen3ASRModuleSetupTests \
	-only-testing:MLXAudioTests/ForceAlignProcessorTests \
	-only-testing:MLXAudioTests/ForcedAlignResultTests \
	-only-testing:MLXAudioTests/Qwen3ASRHelperTests \
	-only-testing:MLXAudioTests/SplitAudioIntoChunksTests \
	-only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests \
	-only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests \
	-only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests \
	-only-testing:MLXAudioTests/Qwen3TTSLanguageTests \
	-only-testing:MLXAudioTests/Qwen3TTSConfigTests \
	-only-testing:MLXAudioTests/Qwen3TTSConfigDimensionTests \
	-only-testing:MLXAudioTests/Qwen3TTSRoutingTests \
	-only-testing:MLXAudioTests/Qwen3TTSPrepareBaseInputsTests \
	-only-testing:MLXAudioTests/Qwen3TTSPrepareICLInputsTests \
	-only-testing:MLXAudioTests/Qwen3TTSGenerateICLTests \
	-only-testing:MLXAudioTests/Qwen3TTSGenerateCustomVoiceTests \
	-only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderTests \
	-only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderWeightTests \
	-only-testing:MLXAudioTests/Qwen3TTSSpeakerEmbeddingTests \
	-only-testing:MLXAudioTests/LlamaTTSModuleSetupTests \
	-only-testing:MLXAudioTests/PocketTTSModuleSetupTests \
	-only-testing:MLXAudioTests/SopranoModuleSetupTests \
	-only-testing:MLXAudioTests/MLXAudioCoreDSPTests \
	-only-testing:MLXAudioTests/ModelUtilsTests \
	-only-testing:MLXAudioTests/AudioUtilsTests \
	-only-testing:MLXAudioTests/AudioIORoundTripTests \
	-only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests \
	-only-testing:MLXAudioTests/ParityFixtureLoaderSmokeTests

.PHONY: help build test test-ci clean archive format lint install release codesign-cli

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build the package
	$(XCODEBUILD) build \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		$(CODE_SIGNING)

release: ## Release build of the CLI + copy binary and Metal bundle to ./bin
	$(XCODEBUILD) build -scheme $(SCHEME) -destination $(DESTINATION) -configuration Release $(CODE_SIGNING)
	@$(MAKE) --no-print-directory _copy-cli CONFIG=Release

install: ## Debug build of the CLI + copy binary and Metal bundle to ./bin
	$(XCODEBUILD) build -scheme $(SCHEME) -destination $(DESTINATION) $(CODE_SIGNING)
	@$(MAKE) --no-print-directory _copy-cli CONFIG=Debug

# Internal: copy the CLI binary + MLX Metal bundle out of DerivedData. CONFIG=Debug|Release.
_copy-cli:
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/MLXAudio-*/Build/Products/$(CONFIG) -maxdepth 1 -name $(BINARY) -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1 | xargs dirname 2>/dev/null); \
	if [ -z "$$PRODUCT_DIR" ]; then \
		echo "Error: could not find $(BINARY) in DerivedData ($(CONFIG))"; exit 1; \
	fi; \
	cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
	if [ -d "$$PRODUCT_DIR/mlx-swift_Cmlx.bundle" ]; then \
		rm -rf $(BIN_DIR)/mlx-swift_Cmlx.bundle; \
		cp -R "$$PRODUCT_DIR/mlx-swift_Cmlx.bundle" $(BIN_DIR)/; \
		echo "Installed $(BINARY) + Metal bundle to $(BIN_DIR)/ ($(CONFIG))"; \
	else \
		echo "Installed $(BINARY) to $(BIN_DIR)/ ($(CONFIG); WARNING: no Metal bundle found)"; \
	fi

# ── App Group code-signing ────────────────────────────
# Sign the CLI with the com.apple.security.application-groups entitlement so the
# group ID is embedded in the binary and SwiftAcervo resolves the shared models
# container (~/Library/Group Containers/group.intrusive-memory.models/) WITHOUT
# requiring ACERVO_APP_GROUP_ID in the environment. Container access is plain
# POSIX (same-user, mode 700); the entitlement only supplies the group
# identifier at runtime via SecTaskCopyValueForEntitlement.
#
# Default identity is ad-hoc (-). For a distributable build, override with a
# Developer ID by certificate SHA-1 (names collide in the keychain):
#   make install codesign-cli CODESIGN_IDENTITY=<sha1>
codesign-cli: ## Sign the CLI with the App Group entitlement (run after install/release)
	@test -f "$(BIN_DIR)/$(BINARY)" || { echo "Error: $(BIN_DIR)/$(BINARY) not found — run 'make install' or 'make release' first."; exit 1; }
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements "$(CODESIGN_ENTITLEMENTS)" $(CODESIGN_FLAGS) "$(BIN_DIR)/$(BINARY)"
	@echo "Signed $(BIN_DIR)/$(BINARY) (identity: $(CODESIGN_IDENTITY), group: $(APP_GROUP_ID))"
	@codesign -d --entitlements - "$(BIN_DIR)/$(BINARY)" 2>/dev/null | grep -A1 "application-groups" || true

test: test-ci ## Run CI-safe tests (no model downloads)

test-ci: ## Run CI-safe tests only (no model downloads)
	$(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		$(CI_TESTS) \
		$(CODE_SIGNING)

clean: ## Clean build artifacts
	$(XCODEBUILD) clean \
		-scheme $(SCHEME) \
		-destination $(DESTINATION)
	rm -rf .build
	rm -rf *.xcodeproj

archive: ## Create build archive for distribution
	$(XCODEBUILD) archive \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		-archivePath ./build/MLXAudio.xcarchive \
		$(CODE_SIGNING)

build-for-testing: ## Build for testing without running tests
	$(XCODEBUILD) build-for-testing \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		$(CODE_SIGNING)

test-without-building: ## Run tests without building
	$(XCODEBUILD) test-without-building \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		$(CI_TESTS) \
		$(CODE_SIGNING)

show-build-settings: ## Show all build settings
	$(XCODEBUILD) -scheme $(SCHEME) -showBuildSettings

show-destinations: ## Show available destinations
	$(XCODEBUILD) -scheme $(SCHEME) -showdestinations

format: ## Format code with swiftformat (if installed)
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat Sources Tests; \
	else \
		echo "swiftformat not installed. Install with: brew install swiftformat"; \
	fi

lint: ## Lint code with swiftlint (if installed)
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint; \
	else \
		echo "swiftlint not installed. Install with: brew install swiftlint"; \
	fi

resolve: ## Resolve package dependencies
	$(XCODEBUILD) -resolvePackageDependencies -scheme $(SCHEME)

.DEFAULT_GOAL := help
