<a id="readme-top"></a>

<div align="center">

<img src="native/Resources/Pacer.png" width="120" alt="Codex Pacer app icon">

<h1>Codex Pacer</h1>

<h3>A progress bar for your AI coding agents.</h3>

See how far every task has got, when it needs you and how much quota is left,<br>
without leaving what you're doing. On Mac and Windows.

<br>

<img src="native/Sources/PacerCore/Resources/provider-codex.png" width="22" align="middle" alt="">&nbsp;<b>Codex</b>
&emsp;<img src="native/Sources/PacerCore/Resources/provider-claude.png" width="22" align="middle" alt="">&nbsp;<b>Claude Code</b>
&emsp;<img src="native/Sources/PacerCore/Resources/provider-deepseek.png" width="22" align="middle" alt="">&nbsp;<b>DeepSeek Harness</b>
&emsp;<img src="native/Sources/PacerCore/Resources/provider-workbuddy.png" width="22" align="middle" alt="">&nbsp;<b>WorkBuddy</b>

<br>

<a href="https://github.com/RyanZhangNTU/codex-pacer/releases/latest"><img src="docs/assets/download-mac.png" height="56" alt="Download for macOS"></a>
&nbsp;
<a href="https://github.com/RyanZhangNTU/codex-pacer/releases/latest"><img src="docs/assets/download-windows.png" height="56" alt="Download for Windows"></a>

[![Latest release](https://img.shields.io/github/v/release/RyanZhangNTU/codex-pacer?style=flat-square&label=release&color=2f9e8f)](https://github.com/RyanZhangNTU/codex-pacer/releases/latest)
[![Downloads](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FRyanZhangNTU%2Fcodex-pacer%2Fbadges%2Fdownloads.json&style=flat-square)](https://github.com/RyanZhangNTU/codex-pacer/releases)
![macOS 14 or later](https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple&logoColor=white)
![Windows 10 or later](https://img.shields.io/badge/Windows-10%2B-0078D4?style=flat-square&logo=windows&logoColor=white)
[![MIT License](https://img.shields.io/github/license/RyanZhangNTU/codex-pacer?style=flat-square&color=555555)](LICENSE)

[Features](#features) · [Supported agents](#supported-agents) · [Install](#install) · [User Guide](docs/guide.md) · [Community](#community) · [简体中文](README.zh-CN.md)

<br>

<img src="docs/assets/demo.webp" width="100%" alt="Codex Pacer with sample data: tasks from several agents report their progress as rings, a task turns amber when it needs approval, and the collapsed bar shows the average progress">

</div>

> [!TIP]
> **New in 4.7: Claude calls Codex (Beta).** Ask Claude Code to have Codex review a change or take on a task, and follow Codex's progress right under Claude's task. [See how it works](#claude-calls-codex).

## Why Pacer

| Without Pacer | With Pacer |
| --- | --- |
| You stare at *Thinking…* and guess how long is left. | The ring is at 56%. Go do something else. |
| You switch back and find it has waited ten minutes for your approval. | The island turns amber. One click takes you back. |
| You learn the quota is gone when it's gone. | You see early that you're using it too fast. |

<a id="features"></a>

## Stop watching the terminal

Codex, Claude Code, DeepSeek Harness and WorkBuddy report how much of your request is done. Each task shows it as a ring around its icon, and the collapsed bar can show the average.

<img src="docs/assets/readme-rings.png" width="100%" alt="The five task states: a comet when a task has just started, an arc while it works, a moon while it waits for background work, an amber hand when it needs you, and a check when it's done">

## It raises its hand when you're needed

A task that waits for your approval or reply turns the island amber and moves to the top. A finished task stays until you've seen it. Click any task to open its conversation in the app that runs it.

<img src="docs/assets/readme-attention.png" width="100%" alt="The expanded island with a task waiting for approval at the top, in amber, above two running tasks">

<a id="supported-agents"></a>

## Several agents at once, still in order

Tasks on this computer, on your SSH hosts, in WSL and in Claude's cloud Projects share one list, each with its stage, model, speed and turn time.

<table>
<thead>
<tr>
<th></th>
<th><img src="native/Sources/PacerCore/Resources/provider-codex.png" width="20" align="middle" alt="">&nbsp;Codex</th>
<th><img src="native/Sources/PacerCore/Resources/provider-claude.png" width="20" align="middle" alt="">&nbsp;Claude Code</th>
<th><img src="native/Sources/PacerCore/Resources/provider-deepseek.png" width="20" align="middle" alt="">&nbsp;DeepSeek Harness</th>
<th><img src="native/Sources/PacerCore/Resources/provider-workbuddy.png" width="20" align="middle" alt="">&nbsp;WorkBuddy</th>
</tr>
</thead>
<tbody>
<tr><td nowrap><b>Progress ring</b></td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td></tr>
<tr><td nowrap><b>Alert when it needs you</b></td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td></tr>
<tr><td nowrap><b>Speed and model</b></td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td></tr>
<tr><td nowrap><b>Click to jump back</b></td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td><td align="center">✅</td></tr>
<tr><td nowrap><b>Usage</b></td><td align="center">5-hour and weekly quota, pace, forecast, banked resets</td><td align="center">5-hour and weekly quota, pace, forecast</td><td align="center">Balance, today's spend by the hour, budgets</td><td align="center">Monthly and extra credits, expiry reminders</td></tr>
<tr><td nowrap><b>Cost of each turn</b></td><td align="center">—</td><td align="center">—</td><td align="center">Estimated</td><td align="center">Credits</td></tr>
<tr><td nowrap><b>Where tasks run</b></td><td align="center">App, CLI, SSH, WSL¹, Dot tasks</td><td align="center">App, CLI, SSH, WSL¹, cloud Projects</td><td align="center">App, CLI</td><td align="center">WorkBuddy and WorkBuddy AI</td></tr>
<tr><td nowrap><b>Collaboration</b></td><td align="center">Called by Claude</td><td align="center">Calls Codex</td><td align="center">—</td><td align="center">—</td></tr>
</tbody>
</table>

<sub>¹ On Windows.</sub>

<details>
<summary><b>First-time setup for each agent</b></summary>
<br>

The welcome guide walks you through these when you first open Pacer.

| | Once |
| --- | --- |
| **Codex** | Allow Pacer's hooks in Codex. Quota needs nothing else. |
| **Claude Code** | Restart running sessions once. Sign in to Claude in Pacer's window to see quota. |
| **DeepSeek Harness** | Sign in to the DeepSeek platform in Pacer's window, or paste an API key, to see the balance. |
| **WorkBuddy** | Trust Pacer's progress tool in WorkBuddy; Pacer shows each click. Sign in to see credits. |
| **SSH hosts** | SSH without a password prompt, and Python 3 on the host. |

</details>

## How much is left, and how fast it's going

Codex and Claude show their 5-hour and weekly quota on one ring, with a tick for an even pace and a forecast for the reset. DeepSeek shows your balance and today's spend hour by hour, with budgets if you want them. WorkBuddy shows this month's credits and when extra credits expire.

<img src="docs/assets/readme-quota.png" width="100%" alt="Codex and Claude quota, each with its 5-hour and weekly windows, pace and a forecast for the reset">

## Claude calls Codex <img src="https://img.shields.io/badge/Beta-8250df?style=flat-square" align="middle" alt="Beta">

Turn on **Claude calls Codex** in **Settings → Collaboration**, then just ask Claude, for example "have Codex review this change". Each Codex run shows under the Claude task that started it, with its own progress, speed and model. Hover over a running one to stop it.

<img src="docs/assets/readme-collab.png" width="100%" alt="A Claude task with two Codex runs under it, each with its own progress ring, speed and model">

## Put it anywhere, make it yours

Keep it at the top center of the screen, or drag it anywhere and let it snap to an edge. Choose black, graphite or Liquid Glass, one of four sizes, and what the collapsed bar shows. Each display remembers its own place.

<img src="docs/assets/readme-forms.png" width="100%" alt="The collapsed bar floating over a window, snapped to the side of the screen, and snapped to the bottom">

<a id="install"></a>

## Install

<table>
<tr>
<td width="50%" valign="top">

<img src="docs/assets/logo-apple.png" height="16" align="middle" alt="">&nbsp;**Mac**

1. Download the DMG from the [latest release](https://github.com/RyanZhangNTU/codex-pacer/releases/latest).
2. Open it and drag **Codex Pacer** into **Applications**.

macOS 14 or later, Apple silicon or Intel. Notarized by Apple.

</td>
<td width="50%" valign="top">

<img src="docs/assets/logo-windows.png" height="16" align="middle" alt="">&nbsp;**Windows**

1. Download the `x64` installer, or `arm64` on an ARM PC.
2. Run it. No administrator rights needed.

Windows 10 version 2004 or later, x64 or ARM64.

</td>
</tr>
</table>

> [!NOTE]
> The Windows installer isn't code signed yet. If SmartScreen appears, choose **More info → Run anyway**.

On first launch, a short guide helps you pick a layout and the agents to follow. Pacer then keeps itself up to date. You need at least one of Codex, Claude Code, DeepSeek Harness or WorkBuddy, installed and signed in. Liquid Glass needs macOS 26 or Windows 11 22H2.

<a id="community"></a>

## Community

- **Bugs and ideas:** [open an issue](https://github.com/RyanZhangNTU/codex-pacer/issues/new/choose).
- **QQ group (Chinese):** [1131553244](https://qm.qq.com/q/5AieQJsCWY)

## Privacy

- **No account, no analytics.** Pacer reads the logs your agents already write and keeps only what the island shows: task titles, stages, timing and token counts. It never keeps your prompts or replies.
- **Your sign-ins stay in Pacer.** Claude, DeepSeek and WorkBuddy sign in inside Pacer's own window. Pacer never reads other apps' passwords or browser cookies.
- **Nothing left behind.** Anything Pacer adds to your agents' settings is removed when you turn that feature off. **Hide Project Names** keeps task titles off screen when you share it.

## Star history

<div align="center">
<a href="https://star-history.com/#RyanZhangNTU/codex-pacer&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=RyanZhangNTU/codex-pacer&type=Date&theme=dark">
    <img alt="Star history of Codex Pacer" src="https://api.star-history.com/svg?repos=RyanZhangNTU/codex-pacer&type=Date" width="720">
  </picture>
</a>
</div>

## Contributing

To build from source or send a pull request, start with [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

<div align="center">
<br>

<sub>[MIT](LICENSE). Codex Pacer is an independent project and is not affiliated with OpenAI, Anthropic, DeepSeek or Tencent.<br>Codex, Claude, DeepSeek and WorkBuddy are trademarks of their respective owners. Codex Pacer includes the decompression part of [Zstandard](https://github.com/facebook/zstd) (BSD license).</sub>

<sub>[Back to top ↑](#readme-top)</sub>

</div>
