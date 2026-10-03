.PHONY: build test release publish
build:
	bash scripts/native/build-island.sh
test:
	bash scripts/native/test-island.sh
release:
	bash scripts/release/build-macos-release.sh
publish:
	bash scripts/release/publish-github-release.sh
