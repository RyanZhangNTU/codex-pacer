# Codex Desktop IPC snapshot loss

Investigation on 2026-10-19: Codex Desktop 26.1013.40934 (20770), macOS 27.0.1, Apple silicon; Pacer 3.2.1 (60), application source `274937b`.

## Field evidence

- The current chat is active and its log identifies Codex Desktop as its originator.
- IPC initialization succeeds, but a read-only `thread-owner-discovery` request for the current chat returns `no-client-found`. The observer receives following announcements, with no `thread-stream-state-changed` snapshot.
- Read-only socket inspection of the Codex main process found **five live listeners bound to the same IPC pathname**, each with `SO_ACCEPTCONN`, queue limit 128 and no connected peer. They are distinct from the accepted connections, which have connected peers and queue limit zero.
- Codex's log records an owner role for the current chat, while its IPC client logs unhandled following broadcasts. This locates the failure before Pacer's snapshot decoding and attention projection.
- The legacy temporary-directory endpoint and local app-server-control endpoint are absent. The Desktop app-server child uses its own stdio connection, with no independent listening endpoint available to this observer.

These observations do not identify which live listener holds the chat's owner. The matching startup race below explains the field symptoms. The restart comparison below confirms recovery in this run, without establishing that a restart always repairs the race.

## Restart comparison

After the user normally quit and reopened Codex, the main PID changed and Pacer remained running as the same single installed instance. The current chat's `thread-owner-discovery` changed from `no-client-found` to success. A read-only observer then received a version-11 snapshot and subsequent state changes (14 state-change frames in the observation window).

There were still **two** same-path listeners after restart. Multiple listeners therefore indicate the startup anomaly, but their count alone cannot determine whether a particular owner is reachable. Check owner discovery and an actual snapshot instead. In the isolated reproduction, an owner on a different router is unreachable; an owner on the observer's router works even while earlier listeners remain alive.

A real async question in the current chat then appeared in the native collector as one input request and in the installed Pacer UI as pending reply. The user confirmed the reminder. After the reply, a fresh live projection had zero input requests, and the installed UI returned to its running stage. This independently verifies the realtime question path after restart, alongside the local-log fallback.

The user then selected human approval for this chat. A harmless `/usr/bin/true` escalation produced a real `item/commandExecution/requestApproval` entry in the Desktop snapshot's `requests` collection. The read-only native `RealtimeActivityMonitor` observer changed from zero to one pending approval; it does not use the question-log fallback. The user confirmed seeing the Pacer approval reminder and approved the command. The command exited successfully, a fresh live projection had zero approvals, and the installed UI returned to its tool-running stage. Observer logs contain request method/shape and counts only, without command, question, reply or account content.

This is recovery of the current stream, not a vendor-side fix for the startup race. Pacer did not restart or patch Codex.

## Reproduced startup race

The installed bundle's `IpcRouterManager.getOrStartRouterEndpoint` first awaits checks of the primary and legacy endpoints. On failure it removes the existing owned socket path and calls `listen`, without sharing a startup promise between manager instances or waiting for the listening callback before returning the path.

Concurrent managers can all pass the initial checks. Each can then remove the pathname created by an earlier manager and bind a new listener. Removing a Unix socket pathname does not close the earlier listener or its established connections. Clients can consequently remain on separate routers with the same recorded pathname.

Run the synthetic reproduction, which never reads Codex data or touches an installed socket:

```sh
node scripts/diagnostics/reproduce-codex-ipc-split.cjs
```

Five concurrent startups create five routers. The owner connects to router 0 and a later observer connects to router 4. The observer is connected but the owner never receives its follow message, so no snapshot arrives. Reconnecting the synthetic owner to router 4 restores snapshot delivery. The reproduction uses message barriers and bounded waits rather than relying on an arbitrary sleep to decide whether a snapshot was lost.

A vendor-side correction should serialize router startup across manager instances, recheck availability after obtaining startup ownership, and complete listener setup before returning the endpoint. Endpoint removal must not race another live router's creation. Pacer must not patch the installed Codex bundle or terminate shared Codex processes to work around this condition.

## Approval impact

**Approval reminders can be missed under the same missing-owner condition.** Pacer reads command, file-change and permissions approvals from the Desktop snapshot's `requests` collection. Its async-question log fallback does not provide a second source for approvals.

An isolated fault injection using Pacer's actual `RealtimeActivityMonitor` and native socket collector verified:

| Input condition | Socket connected | Pending approvals observed |
| --- | --- | --- |
| Owner has a pending command approval but supplies no snapshot | Yes | 0 |
| Owner announces itself and supplies a snapshot containing that approval | Yes | 1 |
| Owner explicitly removes the request | Yes | 0 |

The approval method used was `item/commandExecution/requestApproval`. The previously checked packaged UI renders this standard event as pending approval and clears it after removal. This is a transport/projection test, not a genuine human approval prompt in the affected Desktop session.

The 3.2.1 async-question fallback remains effective: the real question was observed as `0 → 1 → 0`, and the user confirmed its reminder. Recovery of Desktop streaming and real approval delivery was checked separately after restart, as described above. The question-log fallback cannot provide approval reminders if the owner stream is lost again.

## Verified recovery and remaining limitation

Keep this distinction in PR and installation reports: question fallback, restored owner/snapshot delivery, real realtime-question appearance/cleanup, and a genuine human approval reminder/resolution are verified in this run. The startup race remains an upstream issue; this comparison does not establish a permanent repair or an approval fallback during future snapshot loss.

Per [OpenAI's Auto-review documentation](https://learn.chatgpt.com/docs/sandboxing/auto-review), eligible requests under automatic review go to the reviewer instead of pausing for a person. A successful escalated command or a `sandbox_permissions=require_escalated` tool argument alone is therefore insufficient evidence of human-approval delivery. Repeat this check with a human reviewer and verify the actual pending request before its resolution. Do not change global sandbox limits or infer a pending approval from a tool argument.

This investigation changes diagnostics and documentation only. It does not require a Pacer version bump, rebuild or reinstall.
