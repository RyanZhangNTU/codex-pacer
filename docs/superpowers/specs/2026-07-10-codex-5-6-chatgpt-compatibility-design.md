# Codex 5.6 and ChatGPT app compatibility design

## Problem

Codex Pacer still imports the current session format, but two parts of the integration have fallen behind the July 2026 Codex release.

First, the macOS build only looks for a standalone `codex` executable in Homebrew, `/usr/local/bin`, or `~/.cargo/bin`. The current ChatGPT desktop app ships its own executable at `/Applications/ChatGPT.app/Contents/Resources/codex`. A machine with the ChatGPT app but no standalone CLI cannot load live quota data.

Second, the pricing catalog stops at GPT-5.5. A real GPT-5.6 Sol session imported 1,963,678 tokens into the local database with an API-equivalent value of zero. The official pricing page also added a cache-write price between cached input and output for GPT-5.6 rows. The existing parser reads the third number as output, so a pricing refresh can store the cache-write price as the output price.

The current GPT-5.6 session files still live under `~/.codex/sessions` and retain the `session_meta`, `turn_context`, and `event_msg/token_count` records used by the importer. The live `account/rateLimits/read` request also succeeds against the executable bundled with ChatGPT 26.707.30751. No session-path or JSONL schema migration is needed for this release.

## Chosen approach

The compatibility work has three focused parts:

1. Discover the Codex executable inside the ChatGPT app before trying legacy app and standalone CLI locations on macOS. `CODEX_BIN` remains the first choice so explicit configuration still wins.
2. Add exact catalog, display, color, and prefix-resolution support for `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` using the official Standard API prices. Treat the official `gpt-5.6` alias as Sol.
3. Parse each official pricing row within its own boundary. The first value is input, the second is cached input, and the last value is output. Any optional middle value, including cache-write pricing, does not affect Pacer because local usage records do not contain cache-write token counts.

This approach avoids guessing a price for unknown future models. Unknown model IDs remain visible but keep a zero API-equivalent value until OpenAI publishes a matching price.

## Executable discovery

On macOS, automatic discovery uses this order:

1. An existing path from `CODEX_BIN`.
2. `/Applications/ChatGPT.app/Contents/Resources/codex`.
3. `~/Applications/ChatGPT.app/Contents/Resources/codex`.
4. The equivalent system and user paths for the legacy `Codex.app` name.
5. Homebrew, `/usr/local/bin`, and `~/.cargo/bin` locations.
6. The command name `codex`, which lets the operating system search `PATH`.

Windows behavior stays unchanged. Linux keeps its existing standalone CLI lookup. The app-server transport and quota method stay the same. After `initialize` succeeds, Pacer now sends the standard `initialized` notification before reading live quota data.

## Pricing and data repair

The bundled Standard prices per million tokens are:

| Model | Input | Cached input | Output |
| --- | ---: | ---: | ---: |
| GPT-5.6 / GPT-5.6 Sol | $5.00 | $0.50 | $30.00 |
| GPT-5.6 Terra | $2.50 | $0.25 | $15.00 |
| GPT-5.6 Luna | $1.00 | $0.10 | $6.00 |

The seed catalog adds these rows at startup. Historical values are recalculated when price-bearing catalog fields change or when the durable `pricing_value_resolution_v2` repair has not completed. The catalog update, recalculation, and repair marker share one transaction, so a failed upgrade can be retried without leaving mixed values behind.

There is one repair case for users who clicked "Refresh pricing" after OpenAI added the new cache-write column but before this fix. Those databases can contain official GPT-5.6 rows whose output price is 1.25 times the input price: 6.25 for Sol, 3.125 for Terra, or 1.25 for Luna. Seeding may replace only that known malformed pattern. Correct official rows remain untouched. A later successful online refresh marks the corrected rows official again.

Official-page parsing accepts both the older three-price rows and the new four-price rows. The parser still requires the supported flagship rows to be present before it replaces the catalog, which prevents a partial or structurally changed page from silently wiping valid prices.

## Session refresh safety

The audit found several update paths where valid local data can remain stale or be recorded only in part. This release fixes the cases that can silently lose or mislabel data:

- A custom Codex home expands a leading `~` and must exist as a directory before a scan starts. An invalid path returns an error and does not advance the completed-scan timestamp.
- Changing the Codex home clears the old freshness timestamps and triggers a full scan after settings are saved. Existing history stays in Pacer, while the new source becomes the active refresh target.
- The resolved Codex home is stored with scan freshness. A default source change from A to B is detected even when the saved selector remains empty, and an incomplete first scan stays due for a full retry.
- An authoritative source scan marks sessions from the previous home missing and removes their import state even when the old files still exist elsewhere on disk.
- Incremental scans check whether a previously active file moved to the flat `archived_sessions` directory. This imports the final token snapshot immediately instead of waiting for daily maintenance.
- A full scan refreshes titles from `session_index.jsonl` even when the session JSONL files did not change.
- A UTF-8 read failure aborts that file before its metadata is committed. Ordinary incomplete JSON at the end of a file remains retryable on the next size or mtime change.
- A missing or inconsistent conversation link triggers topology repair even when the source file itself did not change.
- Persisted quota rows are ordered by their parsed RFC3339 instant, not by text. Primary and secondary windows are combined only when they came from the same sample time.
- Conversation-detail cache entries are retained only while the refreshed title, timestamps, model set, token totals, session composition, API-equivalent value, and source states still match.
- If a periodic refresh finds another scan in progress, the frontend waits for that scan to settle before loading the dashboard.
- Pricing refreshes and scans share one mutation lock, so a scan cannot write values from an older catalog after a refresh commits.
- A failed Codex-home change restores the previous settings and subscription profile, then rescans the restored source before reporting the error.

The database migration adds one nullable internal field, `last_scan_codex_home`, to bind freshness to the resolved source. Existing databases are upgraded automatically; users do not need to delete or rebuild them.

## User-visible behavior

Model charts and conversation details show the names GPT-5.6 Sol, GPT-5.6 Terra, and GPT-5.6 Luna. Each model gets a distinct chart color, while the text label remains the primary identifier. No workflow depends on color alone.

Codex Pacer keeps its current product name and continues to describe the imported data as Codex usage. The ChatGPT app change affects executable discovery, not the meaning of the analytics.

## Failure handling

If no executable exists, live quota reads return the existing launch error and persisted session-derived quota samples remain available as the fallback. An invalid `CODEX_BIN` does not block automatic discovery.

If the official pricing page cannot be fetched or parsed, Pacer keeps the bundled catalog. If a model has no supported catalog entry, its token totals remain correct and only its API-equivalent value stays zero.

## Verification

Tests cover these behaviors before production code changes:

- ChatGPT app discovery wins over legacy and standalone locations on macOS.
- Explicit `CODEX_BIN` still wins.
- The GPT-5.6 alias and all three variants resolve exact and dated model IDs.
- Official three-price and four-price rows use the last value as output.
- Seeding repairs the known cache-write-column corruption without overwriting correct official prices.
- Startup recalculation changes a stored GPT-5.6 event from zero to the expected value.
- A GPT-5.6 JSONL fixture imports token totals and API-equivalent value correctly.
- Invalid custom homes, moved archives, title-only changes, UTF-8 failures, and missing topology links follow the refresh rules above.
- Mixed-offset quota timestamps select the true latest sample and do not combine different sample times.
- Derived-value changes invalidate a cached conversation detail, and a busy background refresh waits before reloading.

Final verification includes the Rust test suite, frontend tests, lint, production web build, Tauri build checks, a real scan of a copied `~/.codex` data set, and a live quota request through the executable bundled with `/Applications/ChatGPT.app`.

## Sources

- [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
- [Codex pricing and GPT-5.6 model guidance](https://developers.openai.com/codex/pricing)
- [Codex app documentation](https://developers.openai.com/codex/app)
- [ChatGPT desktop app July 2026 update](https://learn.chatgpt.com/docs/whats-new#july-6-10-2026)
