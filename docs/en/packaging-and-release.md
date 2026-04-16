# Packaging and Release

## Official release scope

The stable public release of **Codex Pacer** is distributed through **GitHub Releases**.

The official packaged asset is:

- signed and notarized **macOS Apple Silicon DMG**

Items that are **not currently promised** as official release assets:

- Intel macOS builds
- universal macOS builds
- Windows installers
- Linux bundles
- auto-update delivery

Keep release messaging aligned with this scope so the project does not over-promise beyond the supported stable workflow.

## Stable release workflow

The intended public release flow is:

1. Confirm public branding and documentation are ready for release.
2. Build the signed macOS Apple Silicon release artifact.
3. Publish the DMG through GitHub Releases.
4. Attach or include release notes for the tagged version.

## Local release preparation

Public release preparation should eventually be driven by the release scripts below:

```bash
./scripts/release/audit-public-branding.sh
./scripts/release/build-macos-release.sh 1.0.0
```

Those scripts are the future entry points for the stable release workflow. If they do not exist yet in your local checkout, treat them as the planned interface rather than a promise that release automation is already complete.

Until those helper scripts land, use the current fallback flow:

```bash
npm install
npm run lint
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri build
```

## Recommended validation before publishing

- confirm `package.json` and `src-tauri/tauri.conf.json` are aligned on the release version
- confirm release notes and docs point to the stable public release line
- run the branding/doc audit before publishing
- verify the generated DMG opens correctly on Apple Silicon macOS
- verify the signed app launches from `Applications`

## Publishing guidance

- Create the Git tag for the stable release version.
- Create the GitHub Release from that tag.
- Upload the signed and notarized Apple Silicon DMG.
- Add the matching release notes document for the version being published.
- Verify the download and install flow after publication.

## What users should be told

For public docs and announcements, use this message consistently:

- official distribution channel: GitHub Releases
- official release artifact: signed and notarized macOS Apple Silicon DMG
- current stable line: `v1.0.0`

## Related docs

- [Getting started](./getting-started.md)
- [Installing on macOS](./installing-on-macos.md)
- [Release notes for v1.0.0](./release-notes-v1.0.0.md)
