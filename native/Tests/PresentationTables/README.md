# Shared presentation scenarios

These tables freeze the inputs and expected results formerly checked against the Mac implementation by the seven Windows-branch CompatibilityTests groups. The shared tests read the tables directly. They do not call IslandModel or a copy of its deleted logic to obtain expected results. Dates use the fixed epoch 1800000000; demo inputs use UTC. Localized text uses fixed keys and arguments through L10n.

| Original group | Current test | Inputs and expected results |
| --- | --- | --- |
| CompactBarCompatibilityTests | CompactBarScenarioTableTests | All 8 module sets × 2 budget modes × 5 ring choices × 3 layouts × 2 metrics × 3 window choices: 1,440 cases; 480 failed/stale/expired/weekly-only/legacy-ID cases; 32 live stage/attention/attachment/strip cases |
| QuotaPresentationCompatibilityTests | QuotaDashboardScenarioTableTests, QuotaHistoryScenarioTableTests, DeepSeekScenarioTableTests | 88 reading rows, 8 module sets with duplicate/reversed inputs, all 512 legacy-policy combinations, 64 legacy freshness rows, 48 history rows, all 20 dial age/amount pairs, and provider connection states |
| DeepSeekConnectionCompatibilityTests | DeepSeekScenarioTableTests.testEveryProfileSourceAndAgePairKeepsKnownBalancesAndRejectsInvalidConnections | Missing/account/API profile × automatic/web/API selection × all 6 age boundaries: 54 known-balance cases and 9 rejected-connection cases |
| DeepSeekNoticePolicyCompatibilityTests | NoticeScenarioTableTests | All 24 provider/threshold/failure rows and the full 9-step stateful notice sequence, including exact IDs, titles, details, categories and order |
| EmbeddedSessionVisibilityCompatibilityTests | VisibilityAndInteractionScenarioTableTests.testEveryOriginalProviderHostEmbeddingAndOrderPermutation | Codex/Claude × local/SSH × embedded/not embedded × both row orders: 16 rows; only root and matching child are hidden |
| TaskRowInteractionCompatibilityTests | VisibilityAndInteractionScenarioTableTests.testEveryOriginalEaseOutSampleUsesTheFixedNumericTable | All 121 curve samples at the original 0.00001 tolerance; hover 0.12 s, navigation error 30 s; finite bounds and invalid-number handling |
| DeepSeekWebScriptCompatibilityTests | PacerCoreTests.DeepSeekWebScriptContractTests + browser-scripts.json | Schema 1, fixed origin and script names. Shared tests load the bundled summary and session-fingerprint resources; the Mac driver evaluates those same resources in its isolated script world. Script hashes do not lock implementation changes. |

## Collapsed rings and values

C = Codex, L = Claude, D = DeepSeek; lists preserve outer/inner order. `none/none` always produces no rings. Each row is exercised with the gauge shown, gauge hidden and a separate price clock, with both metrics and all three window selections.

| Modules | Automatic, balance mode | Automatic, budget mode | C/L slots | D/D slots, budget mode | D/C slots, balance mode | D/C slots, budget mode |
| --- | --- | --- | --- | --- | --- | --- |
| none | [] | [] | [] | [] | [] | [] |
| C | [C] | [C] | [C] | [] | [C] | [C] |
| L | [L] | [L] | [L] | [] | [] | [] |
| C,L | [C,L] | [C,L] | [C,L] | [] | [C] | [C] |
| D | [] | [] | [] | [D] | [] | [D] |
| C,D | [C] | [C,D] | [C] | [D] | [C] | [D,C] |
| L,D | [L] | [L,D] | [L] | [D] | [] | [D] |
| C,L,D | [C,L] | [C,L] | [C,L] | [D] | [C] | [D,C] |

| Readout input | Remaining | Pace | Time | Ring remaining |
| --- | --- | --- | --- | --- |
| Codex, any saved window | 43% | 139% | 31% | 43 |
| Claude, auto/7d | 64% | 207% | 31% | 64 |
| Claude, 5h | 81% | 152% | 53% | 81 |
| DeepSeek balance / hidden gauge | ¥86 | ¥86 | unavailable | no automatic solo ring |
| DeepSeek selected budget ring | ¥14 | ¥14 | unavailable | 72.7 |
| Fresh cache, failed read | cached remaining; pace unavailable | unavailable | measured clock retained | value absent; dimmed remains false |
| Aged cache or expired selected window | cached remaining; pace unavailable | unavailable | expired clock is 0% | aged/expired ring is dimmed |

Failure alone does not dim the collapsed ring in the reviewed Mac behavior. This corrects that boolean expectation in the former Windows comparison; cached values remain covered separately for expanded readings. The literal state rows also check providers omitted from alternation, all-dash fallback, legacy `five`/`week` IDs, expiry itself and one second after expiry.

Live TPS values are 102, 83, 102 and 42 for thinking/tool/responding/completed. The fixture settles 665 tokens over 16 seconds and 850 over 14 seconds; tool rows retain their measured speed. Attached English attention hides TPS unless status is hidden in the strip.

## Availability and legacy policy

| Snapshot | 5h availability | 7d availability |
| --- | --- | --- |
| unread | unavailable | unavailable |
| own bucket, no windows | missingPeriod | missingPeriod |
| fresh 5h + 7d | available | available |
| fresh own 7d, known usage and future reset | proOnly | available |
| scoped 7d | missingPeriod | available |
| unknown 5h usage/reset | available | missingPeriod |
| expired 7d | missingPeriod | stale |
| aged 5h + 7d | stale | stale |
| own 7d plus untyped window | missingPeriod | available |
| own 7d with unknown usage or reset | missingPeriod | available |

A failed read makes an existing bucket stale; unread data remains unavailable. Reading rows specify numeric values, countdown, freshness, verdict, forecast, pressing state, help order and accessibility results.

Legacy window-mask bits are 1 = 5h, 2 = 7d, 4 = custom 8h, 8 = untyped. For Codex alone and the primary Codex bucket, Classic is true for masks 2,4,6,8,10,12,14; Split is true for 4,8,12. All other provider/bucket combinations are false. The original 256 combinations remain, with another 256 covering the four module sets that include DeepSeek. All 512 results are explicit in quota-layout.json. Legacy freshness follows the selected weekly fallback when present, even if the custom 8h window expired.

## DeepSeek, history and notices

| Input | Expected result |
| --- | --- |
| Dial ages 0,30,301,601,3600 s × balances 0,2,86.4,1250 | All 20 pairs; freshness just-updated/30 seconds/5 minutes/10 minutes/60 minutes; amounts ¥0.00/¥2.00/¥86.40/¥1.2k; age >600 dims the face and uses stale tones |
| Connection ages 0,9,10,59,60,601 s | Just-updated through 9 s, seconds through 59 s, minutes from 60 s; a cached balance wins over a transient read failure; invalid key never claims connected |
| History unread/demo/expired-5h-plus-live-7d | Empty/31-point/single-point projection; empty buckets preserved; only eligible fresh windows have pace; failed reads keep chart values; Codex keeps account details |
| 5h remaining 20,19.9,0 | No warning / outlined low mark / solid exhausted mark; stale, expired or failed reads replace the live warning with quotaDelay |
| Balance sequence 20,9,8,0,5(stale),20,5,5,5 | Notice suffixes [],[low],[],[exhausted],[],[],[low],[],[] |
| Spend sequence 2,9,10.1,11,2,2,9,2,6 | [],[day-near],[day-over],[],[],[],[spike,day-near],[],[spike]; the first three spike crossings are snoozed |

The JSON files contain the complete inputs and expected fields. Existing shared and native regression tests remain in place.
