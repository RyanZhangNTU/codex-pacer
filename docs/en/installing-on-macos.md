# Installing on macOS

## macOS install path

The macOS public installer for **Codex Pacer** is the signed and notarized **Apple Silicon DMG** published through GitHub Releases.

## Happy path

1. Open the latest GitHub Releases page for `codex-pacer`.
2. Download the latest Apple Silicon DMG.
3. Open the downloaded DMG.
4. Drag **Codex Pacer.app** into `Applications`.
5. Launch **Codex Pacer** from `Applications`.

## If Gatekeeper blocks the first launch

If macOS blocks the app on first launch, use this fallback once:

1. Open `Applications`.
2. Right-click **Codex Pacer.app**.
3. Choose **Open**.
4. Confirm the prompt to open the app.

After this first approved launch, future launches should open normally.

## If macOS still refuses to open the app

Use the explicit system override:

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Find the message about **Codex Pacer.app** being blocked.
4. Click **Open Anyway**.
5. Confirm the follow-up prompt and launch the app again.

## After installation

On first run:

1. Confirm the Codex home path (`~/.codex` by default) or choose a custom `CODEX_HOME`.
2. Run the first scan/import.
3. Wait for local indexing to complete.
4. Review the overview and pacing views.

## Notes

- The macOS packaged release currently targets Apple Silicon macOS.
- GitHub Releases is the official distribution channel.
- Intel macOS builds, universal macOS builds, Linux bundles, and auto-update delivery are not currently promised as public release options.
