.PHONY: help setup build install package test check plugins
help:
	@echo 'make setup   Prepare the local playback and input runtimes'
	@echo 'make build   Build dist/MacTV.app'
	@echo 'make install Install MacTV, preserving the previous app'
	@echo 'make package Create a versioned MacTV installer'
	@echo 'make test    Run Swift and plugin tests'
	@echo 'make check   Check types, source hygiene, and public documentation'
setup:
	bash tools/build/setup-rime-engine.sh
	ruby tools/build/package-native-mpv.rb
	bash tools/build/setup-subtitle-tool.sh
build:
	bash tools/build/build-app.sh
install:
	bash tools/build/install-preview.sh
package:
	bash tools/build/package-preview.sh
test:
	bash tools/check/test.sh
	npm --prefix tools run test:integrations
check:
	npm --prefix tools run check:integrations
	ruby tools/check/test-native-runtime-materials.rb
	ruby tools/check/test-preview-artifacts.rb
	ruby tools/check/test-source-release.rb
	ruby tools/check/test-release-version.rb
	ruby tools/check/check-source-release.rb
plugins:
	npm --prefix tools run build:plugins
	npm --prefix tools run test:plugins

.PHONY: test-ui
test-ui:
	ruby tools/check/run-interactive-test.rb $(ARGS)
