# Contributing

Thanks for your interest in contributing to Codex Pacer.

## Ways to contribute

- report bugs with clear reproduction steps
- propose focused product or developer-experience improvements
- improve documentation, translations, or onboarding material
- add tests, refactors, or UI polish that stay within current product direction

## Branching model

This repository uses a simple `main` / `develop` model:

- `main` is release-ready only
- `develop` is the default integration branch for ongoing work
- create your feature or fix branch from `develop`
- open pull requests back into `develop`
- only release preparation and release promotion work should target `main`

Transition note:

- if the public repository has just been initialized and `develop` is not available yet, coordinate with the maintainer before opening the first pull request so the long-term branch model can be set up cleanly

## Before you start

Open an issue or discussion first if your change is large, changes product direction, or needs design alignment before implementation.

Keep contributions:

- focused and easy to review
- consistent with existing architecture and product intent
- verified locally before submission
- free of unrelated drive-by edits

## Local verification

Recommended verification before opening a pull request:

```bash
npm run lint
npm run build
cargo test
```

If your change affects documentation or user-facing behavior, update the relevant docs in the same pull request when they are in scope. If you touch shared copy, keep English and Chinese surfaces aligned.

## Development notes

- Frontend: React + TypeScript + Vite
- Desktop shell: Tauri 2
- Backend and data layer: Rust + SQLite

## Pull request checklist

- [ ] My branch was created from `develop`
- [ ] My pull request targets `develop` unless it is release-only work
- [ ] If `develop` does not exist yet in a newly initialized public repository, I coordinated with the maintainer before opening the first pull request
- [ ] The change is scoped and explained clearly
- [ ] I ran `npm run lint`
- [ ] I ran `npm run build`
- [ ] I ran `cargo test`
- [ ] I updated in-scope docs if behavior or setup changed
- [ ] I avoided unrelated changes

## Reporting bugs

Please use the bug report template and include:

- platform and OS version
- install method or build workflow
- app version
- minimal reproduction steps
- screenshots or logs when available

## Security issues

Do not report security vulnerabilities in public issues. See [SECURITY.md](./SECURITY.md).
