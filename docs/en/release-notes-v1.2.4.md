# Codex Pacer v1.2.4

This development version adds GPT-6.1 Sol, GPT-6 Sol, and GPT-6 Luna support. It has not been published as a GitHub Release.

## Model pricing

The bundled prices below were checked against [OpenAI's Standard API pricing](https://developers.openai.com/api/docs/pricing) on October 1, 2026. Prices are in USD per million tokens.

| Model | Input | Cached input | Output |
| --- | ---: | ---: | ---: |
| GPT-6 Astra | $10.00 | $1.00 | $50.00 |
| GPT-6.1 Sol | $2.00 | $0.10 | $10.00 |
| GPT-6 Sol | $2.00 | $0.20 | $10.00 |
| GPT-6 Luna | $0.10 | $0.01 | $0.50 |
| GPT-5.6 Sol | $4.00 | $0.40 | $20.00 |
| GPT-5.6 Terra | $2.00 | $0.20 | $12.00 |
| GPT-5.6 Luna | $0.20 | $0.02 | $1.20 |

The new models have readable labels and distinct chart colors. Canonical IDs and valid dated IDs resolve to the same model price. GPT-5.6's bundled prices now match the current official table; its bare alias continues to use Sol pricing.

API-equivalent value uses Standard short-context prices. It excludes cache-write pricing, long-context rates, and speed-tier charges. This estimate is not an API invoice or a measure of subscription credit consumption.

## Upgrading

At the first launch after upgrading, Codex Pacer recalculates existing usage values. This includes dated GPT-6 models that were previously unpriced even when the online catalog already contained their canonical model. Existing token counts, conversations, quota history, and settings remain in place. Later launches skip the repair unless catalog prices change.

Online pricing refresh still takes precedence over bundled fallback prices. Known rows that incorrectly used a long-context output price are repaired. Other stored official prices are retained until the next online pricing refresh.

## Other fixes included

- macOS 27 menu bar clicks open the usage popup and context menu correctly
- Windows tray popups select the monitor using physical click coordinates at any display scale
- reopening a resized tray popup resets its initial size before displaying it

The app name, bundle identifier, and local data location are unchanged.
