# Best Photo Picker — macOS app build/run helpers.
# Usage (from macos/):  make run   |  make rebuild  |  make build  |  make clean

PROJECT := BestPhotoPicker.xcodeproj
SCHEME  := BestPhotoPicker
DEST    := platform=macOS

# Resolve the built .app path from the build settings (DerivedData location varies).
APP = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$$2} / FULL_PRODUCT_NAME /{n=$$2} END{print d"/"n}')

.DEFAULT_GOAL := run
.PHONY: run rebuild build open kill clean help

## run: build, kill any running instance, relaunch the fresh build (default)
run: build kill open

## rebuild: clean build, then relaunch
rebuild: clean build kill open

## build: incremental build
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' build \
	  | grep -E 'error:|warning:|BUILD SUCCEEDED|BUILD FAILED' || true

## open: launch the built .app
open:
	@app="$(APP)"; echo "opening $$app"; open "$$app"

## kill: quit any running instance
kill:
	-@pkill -f $(SCHEME).app 2>/dev/null; sleep 1; true

## clean: remove build products
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean | tail -1

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
