Pacer now uses much less power in the background. With the same real tasks and the panel collapsed, it used about 60% less CPU than 4.4.1 on Windows and MACPERCENT less on Mac. It no longer redraws or sends updates that change nothing on screen, checks unreachable hosts and failed connections less often, and stops rescanning apps it has already identified.

Sources that cost extra power now start off. Codex Dot tasks have their own switch, **Include Codex Dot Tasks**, on the Remote page; after this upgrade it stays on if Dot tasks already reported progress on this computer. Codex Remote Control monitoring, and WSL monitoring on Windows, are off unless you turn them on in **Settings → Remote**. Windows turns WSL monitoring off once after this upgrade.

A slow quota reply no longer shows an error: Pacer keeps the last reading and dims it only after 10 minutes. The collapsed bar also keeps its width while the TPS readout changes.

See the [user guide](https://github.com/RyanZhangNTU/codex-pacer/blob/main/docs/guide.md) and the [full changelog](https://github.com/RyanZhangNTU/codex-pacer/blob/main/CHANGELOG.md).
