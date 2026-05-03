# Makefile for MLXAudio Swift Package
# Uses xcodebuild exclusively (no swift build/test)

SCHEME = MLXAudio-Package
DESTINATION = 'platform=macOS'
XCODEBUILD = xcodebuild
CODE_SIGNING = CODE_SIGNING_ALLOWED=NO

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

.PHONY: help build test test-ci test-all clean archive format lint

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

test: test-ci ## Run CI-safe tests (no model downloads)

test-ci: ## Run CI-safe tests only (no model downloads)
	$(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		$(CI_TESTS) \
		$(CODE_SIGNING)

test-all: ## Run all tests (including those requiring model downloads)
	$(XCODEBUILD) test \
		-scheme $(SCHEME) \
		-destination $(DESTINATION) \
		-only-testing:MLXAudioTests/AudioModelManagerIntegrationTests \
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
