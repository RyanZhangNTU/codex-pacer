# Codex Desktop IPC snapshot loss

Investigation on 2026-10-19: Codex Desktop 26.1013.40934 (20770), macOS 27.0.1, Apple silicon; Pacer 3.2.1 (60), application source `274937b`.

## Field evidence

- The current chat is active and its log identifies Codex Desktop as its originator.
- IPC initialization succeeds, but a read-only `thread-owner-discovery` request for the current chat returns `no-client-found`. The observer receives following announcements, with no `thread-stream-state-changed` snapshot.
- Read-only socket inspection of the Codex main process found **five live listeners bound to the same IPC pathname**, each with `SO_ACCEPTCONN`, queue limit 128 and no connected peer. They are distinct from the accepted connections, which have connected peers and queue limit zero.
- Codex's log records an owner role for the current chat, while its IPC client logs unhandled following broadcasts. This locates the failure before Pacer's snapshot decoding and attention projection.
- The legacy temporary-directory endpoint and local app-server-control endpoint are absent. The Desktop app-server child uses its own stdio connection, with no independent listening endpoint available to this observer.

These observations do not identify which live listener holds the chat's owner. The matching startup race below explains the field symptoms; a restart/control comparison of the real Desktop has not yet been performed. Do not present an application restart as a guaranteed fix.

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

The 3.2.1 async-question fallback remains effective: the real question was observed as `0 → 1 → 0`, and the user confirmed its reminder. That fix does **not** establish that Desktop streaming or real approval delivery has recovered. A `sandbox_permissions=require_escalated` tool argument alone is not proof of a pending human approval because automatic review may resolve it without any prompt.

## Remaining acceptance

Keep this distinction in PR and installation reports: question fallback is verified, standard approval projection is verified, and real Desktop approval delivery remains dependent on recovering the owner stream. Preserve the field evidence before any user-authorized Codex restart. Then repeat owner discovery, require an actual snapshot, and test a real pending approval before claiming live approval recovery.

This investigation changes diagnostics and documentation only. It does not require a Pacer version bump, rebuild or reinstall.
