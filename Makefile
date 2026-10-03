.PHONY: build test release publish release-unsigned publish-unsigned
build:
	bash scripts/native/build-island.sh
test:
	bash scripts/native/test-island.sh
release:
	bash scripts/release/build-macos-release.sh
publish:
	bash scripts/release/publish-github-release.sh
release-unsigned:
	bash scripts/release/build-macos-release.sh --unsigned
publish-unsigned:
	bash scripts/release/publish-github-release.sh --unsigned
