# PSUnplugged Agent Infrastructure Plan

## Reconciled Thesis

PSUnplugged should be treated as a PowerShell-native operations surface over the Codex App Server, not as a separate agent runtime or a greenfield durable task system.

The important shift is still real:

```text
Old model:
human <-> chat window <-> model

Current PSUnplugged model:
human
  -> Codex task/thread
  -> Codex App Server
  -> tools/files/git/tests/apis
  -> Codex sessions, events, transcripts, and local PSUnplugged views
```

The right near-term framing is:

> PSUnplugged is the PowerShell control plane for Codex-backed agent work.

The durable store is the Codex App Server and its persisted session data. PSUnplugged should not invent a competing task database unless Codex stops exposing enough state.

## Current Reality

The task-first command surface already exists:

```powershell
Start-CodexTask
Get-CodexTask
Wait-CodexTask
Receive-CodexTask
Resume-CodexTask
Remove-CodexTask
Get-CodexTranscript
```

These commands already support the most important object flow:

```powershell
$task = Start-CodexTask -Cwd . -Prompt "Summarize this repo"
$task | Get-CodexTask
$task | Wait-CodexTask
$task | Receive-CodexTask -Text
```

So the plan should not say "prototype `Start-AgentTask`, `Get-AgentTask`, and `Wait-AgentTask`". That would duplicate existing work and blur the Codex-specific value proposition.

Generic `Agent*` names can remain a possible future alias or adapter layer, but the actual module surface should stay Codex-native until there is a second real runtime to justify a provider-neutral abstraction.

## Codebase Review Findings

The current implementation already supports the central object-flow idea from the original plan.

Relevant implemented functions:

- `Start-CodexTask`: starts a managed Codex task and returns a `PSUnplugged.CodexTask` handle.
- `Get-CodexTask`: lists and refreshes task views across Codex threads, local catalog metadata, and pending worker handles.
- `Wait-CodexTask`: polls tasks until terminal status and can tail transcript output while waiting.
- `Receive-CodexTask`: returns compact latest output, full assistant text, or transcript/details.
- `Resume-CodexTask`: continues an existing task/thread with another prompt.
- `Remove-CodexTask`: archives or purges local task metadata.
- `Get-CodexTranscript`: turns Codex session state into PowerShell transcript objects.

The implementation already creates typed PowerShell objects:

- `PSUnplugged.CodexTask`
- `PSUnplugged.CodexTaskReceive`
- `PSUnplugged.CodexTaskTurn`
- `PSUnplugged.CodexTranscriptItem`
- `PSUnplugged.CodexThread`

The review confirms that the original plan's near-term prototype step was misplaced. `Start-CodexTask`, `Get-CodexTask`, and `Wait-CodexTask` are not future work. They are the current foundation.

The better near-term question is:

> What must be added so existing Codex task objects become a stronger operational surface?

## Existing Durable State

Codex already owns the primary durable store:

- `thread/start` creates durable Codex threads.
- `turn/start` runs work in a thread.
- `thread/list` returns stored threads.
- `thread/read` can return a thread with turns.
- Codex session files under `CODEX_HOME` contain durable session JSONL.
- `session_index.jsonl` and session files provide local durable history.

PSUnplugged adds useful local enrichment:

- project catalog metadata
- project names and paths
- local archive state
- tags
- pinned state
- prompt previews
- model, sandbox, and approval policy metadata
- pending worker handoff files while background tasks are starting

This means the minimum useful durable store is already present. The near-term question is not "JSON, SQLite, or PowerShell data files?" It is:

> What missing views over Codex-owned durable state would make task operations feel complete?

## Codex App Server Data Review

The Codex App Server appears to provide enough information for the current task object flow:

- `thread/start`: creates the durable thread backing a task.
- `turn/start`: starts work inside a thread.
- `thread/list`: returns stored threads for inspection and task listing.
- `thread/read`: returns detailed thread records and can include turns.
- live notifications: provide turn completion, item completion, streamed agent text, and approval request events.
- persisted session JSONL: provides durable recovery for transcript and event-derived views.

PSUnplugged currently combines those Codex-owned records with local catalog data to create the task view. That is the right architecture.

The Codex App Server does not appear to hand back a fully shaped "task object" with every operational field PSUnplugged wants. That is fine. PSUnplugged's role is to project Codex threads, turns, events, and local metadata into useful PowerShell objects.

The most important implication:

> Do not add a separate durable task store until there is a concrete Codex state gap that cannot be solved with Codex sessions plus local metadata.

## What The Current Implementation Can Support

The current implementation can support a credible first version of the planned command surface with Codex names:

```powershell
Start-CodexTask       # already implemented
Get-CodexTask         # already implemented
Wait-CodexTask        # already implemented
Receive-CodexTask     # already implemented
Resume-CodexTask      # already implemented
Remove-CodexTask      # already implemented
Get-CodexTranscript   # already implemented
```

It also already supports useful task object details:

- `TaskId`
- `ThreadId`
- compact `Id`
- `Name`
- `Project`
- `ProjectKey`
- `Path`
- `ProjectBranch`
- `ProjectRemoteUrl`
- `Model`
- `Status`
- `LastTurnStatus`
- `LastErrorMessage`
- `Tags`
- `CreatedAt`
- `LastActivityAt`
- `ApprovalPolicy`
- `SandboxType`
- `Source`
- `Metadata`
- `RawThread`

This is enough for basic operational queries:

```powershell
Get-CodexTask -ActiveOnly
Get-CodexTask
Get-CodexTask -LocalOnly
Get-CodexTask -All
Get-CodexTask -RecentHours 12
Get-CodexTask | Group-Object Project
Get-CodexTask | Where-Object { $_.Status -eq 'failed' }
```

It is also enough for basic task composition:

```powershell
Start-CodexTask -Cwd . -Prompt "Inspect this repo" |
    Wait-CodexTask |
    Receive-CodexTask -Text
```

And for manual retry or continuation:

```powershell
Get-CodexTask |
    Where-Object { $_.Status -eq 'failed' } |
    Resume-CodexTask -Prompt "Recover from the failure and continue."
```

## What Is Still Missing

The gaps are narrower than the original stretch plan implied.

### Event View

Codex emits events and stores session JSONL. PSUnplugged already parses some of that into transcript items, including assistant messages, reasoning, tool calls, command summaries, and terminal task states.

Implemented first piece:

```powershell
Get-CodexEvent
```

This exposes durable Codex session events as PowerShell objects instead of forcing users to infer everything from transcripts.

Still missing:

```powershell
Watch-CodexEvent
```

or a carefully named equivalent.

`Get-CodexEvent` should be an addition, not a replacement for the PowerShell-native receive pattern.

Keep:

```powershell
Get-CodexTask | Receive-CodexTask
```

as the result collection surface, analogous to `Receive-Job`.

Add:

```powershell
Get-CodexTask | Get-CodexEvent
```

as the observability surface for the task's operational history.

The conceptual split:

```text
Receive-CodexTask = what did the task produce?
Get-CodexTranscript = what did the conversation say?
Get-CodexEvent = what did the task do?
```

This keeps task output, transcript, and events as separate projections over the same Codex-backed durable state.

The review found that the current `Receive-CodexTask` telemetry switches create confusing overlap:

```powershell
Get-CodexTask | Receive-CodexTask -ShowAll
Get-CodexTask | Receive-CodexTask -ShowTelemetry
Get-CodexTask | Receive-CodexTask -ShowReasoning
Get-CodexTask | Receive-CodexTask -ShowTools
Get-CodexTask | Receive-CodexTask -ShowCommands
```

When used without `-Transcript` or `-Text`, these mostly return the same latest-output summary as plain `Receive-CodexTask`.

There is also overlap between:

```powershell
Get-CodexTask | Get-CodexTranscript
Get-CodexTask | Receive-CodexTask -Transcript -ShowCommands
```

and between:

```powershell
Get-CodexTask | Receive-CodexTask -Details
Get-CodexTask | Receive-CodexTask -Transcript -ShowReasoning
```

The cleanup direction should be:

- preserve `Receive-CodexTask` as the canonical result collector;
- preserve `Receive-CodexTask -Details` as a useful convenience/detail view for now;
- avoid expanding the `Show*` switches further;
- consider de-emphasizing or eventually removing `ShowAll`, `ShowTelemetry`, `ShowReasoning`, `ShowTools`, and `ShowCommands` from `Receive-CodexTask`;
- move operational filtering and telemetry inspection to `Get-CodexEvent`.

`Get-CodexEvent` should make telemetry explicit and queryable:

```powershell
Get-CodexTask | Get-CodexEvent -Kind Command
Get-CodexTask | Get-CodexEvent -Kind ToolCall
Get-CodexTask | Get-CodexEvent -Kind Reasoning
Get-CodexTask | Get-CodexEvent -Kind ApprovalRequested
```

That is cleaner than asking `Receive-CodexTask` to be both `Receive-Job` and `Get-WinEvent`.

### Approval View

Codex can emit approval requests such as:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`

The current reader auto-accepts those events in the low-level notification loop. That is useful for today's defaults, but it is not enough for a real operations surface.

Implemented first piece:

```powershell
Get-CodexApproval
```

`Get-CodexApproval` is a read-only approval view over observed approval request events.

Still missing:

```powershell
Approve-CodexApproval
Deny-CodexApproval
```

Write-side approval probably requires changing approval handling so requests can be surfaced, persisted, and answered deliberately instead of always accepted by the reader.

This is the largest architectural gap found in the review. Approval is not just another display view; it affects control flow. A serious approval surface needs to answer:

- can an approval request be persisted after the live JSON-RPC notification arrives?
- can the app-server wait long enough for an external PowerShell command to answer?
- should `Read-CodexNotifications` keep auto-accept behavior behind an explicit policy?
- how should unattended task mode differ from interactive governed mode?

### Artifact View

Codex and PSUnplugged already expose transcripts and final assistant text. The repo also has examples for artifacts, but artifacts are not yet a first-class task view.

Implemented first piece:

```powershell
Get-CodexArtifact
```

Initial artifact support is deliberately modest and derived from the existing durable store:

- session JSONL
- latest assistant response
- transcript
- event log

Avoid inventing a broad artifact registry until there is concrete data to back it.

### Dashboard View

The UI path should sit on top of the existing task substrate instead of introducing a separate detail object first.

Implemented first piece:

```powershell
ConvertTo-CodexTaskDashboardData
Show-CodexTaskDashboard
```

This is an Argus-style local dashboard snapshot over:

- `Get-CodexTask`
- `Receive-CodexTask`
- `Get-CodexTranscript`
- `Get-CodexEvent`
- `Get-CodexApproval`
- `Get-CodexArtifact`

`ConvertTo-CodexTaskDashboardData` is the stable data handoff for a better frontend. `Show-CodexTaskDashboard` is the local-file renderer over that data.

The initial dashboard is read-only and local-file based. It supports focused/verbose views and an NLP-style command bar for filtering and steering the visible task set.

Live prompt sending, process control, and remote/mobile notification routing should wait for a real live channel instead of being faked in a static page.

### Retry Semantics

`Resume-CodexTask` already covers "continue this unit of work with another prompt."

That may be the practical first retry primitive:

```powershell
Get-CodexTask | Where-Object Status -eq failed | Resume-CodexTask -Prompt "Recover from the failure and continue."
```

A separate `Restart-CodexTask` should wait until the desired semantics are clear:

- same thread or new thread?
- same branch/worktree or new one?
- same model or changed model?
- preserve previous failure as context or start clean?

### Worktree And Branch Flow

The current task object can surface project git metadata such as branch and remote URL. That supports inspection.

It does not yet imply a full worktree orchestration layer. Worktree creation and branch routing should be treated as a separate, later feature, not part of the minimum task surface.

The review found enough branch metadata for visibility, not enough reason to make worktree orchestration part of the immediate plan.

## Reconciled Command Surface

Keep the near-term surface Codex-native:

```powershell
Start-CodexTask
Get-CodexTask
Wait-CodexTask
Receive-CodexTask
Resume-CodexTask
Remove-CodexTask
Get-CodexTranscript
```

Candidate additions, in priority order:

```powershell
Get-CodexEvent        # implemented
Watch-CodexTask
Get-CodexApproval     # implemented as read-only
Approve-CodexApproval
Deny-CodexApproval
Get-CodexArtifact     # implemented as read-only durable/materialized views
ConvertTo-CodexTaskDashboardData # implemented as JSON-ready UI contract
Show-CodexTaskDashboard # implemented as local read-only dashboard snapshot
```

Possible later additions:

```powershell
Restart-CodexTask
Get-CodexPatch
Publish-CodexDraftPR
Start-CodexTaskReview
```

Avoid introducing `Start-AgentTask`, `Get-AgentTask`, or `Wait-AgentTask` unless PSUnplugged becomes a multi-runtime module.

## Codex App Server Fit

The Codex App Server can provide much of the object flow:

- task identity through thread IDs
- task creation through `thread/start`
- task execution through `turn/start`
- listing through `thread/list`
- detailed reading through `thread/read`
- transcript/event recovery through persisted session JSONL
- approval request events during active notification reads
- model/account/runtime metadata through existing JSON-RPC methods

The Codex App Server does not currently appear to provide a fully shaped PowerShell task object directly. PSUnplugged's job is to compose Codex data plus local catalog metadata into useful PowerShell objects.

That is the right division of labor.

## Near-Term Plan

1. Document the existing Codex task model instead of proposing a parallel `AgentTask` model.
2. Audit `PSUnplugged.CodexTask` properties and decide which are stable public contract.
3. Add or improve formatting views for the existing task properties that matter operationally.
4. Preserve `Receive-CodexTask` as the task result collector.
5. De-emphasize `Receive-CodexTask` telemetry switches in favor of a dedicated event view.
6. Add a read-only event view over Codex session JSONL before adding new mutation commands. Done for `Get-CodexEvent`.
7. Revisit approval handling so approval requests can become inspectable objects instead of being only auto-accepted during notification reads. Partially done with read-only `Get-CodexApproval`.
8. Define a minimal artifact view based on data already available from transcripts, task output, and known files.
9. Treat retry as `Resume-CodexTask` plus documented patterns until restart semantics are concrete.
10. Defer worktree/branch orchestration until task, event, approval, and artifact views are solid.

## Deferred Stretch Ideas

These ideas remain interesting, but they should not drive the next implementation pass:

- provider-neutral `Agent*` command names
- separate task database
- full scheduler
- bulk automated approvals
- multi-runtime routing
- first-class worktree orchestration
- PR publication pipeline
- Kubernetes-like lifecycle taxonomy

They become relevant only after the Codex-backed task surface has stronger event, approval, and artifact views.

## Review Conclusion

The plan should be reduced from "build agent infrastructure" to "complete the Codex task operations surface."

The current implementation can already support:

- task creation
- task listing
- waiting
- tailing
- receiving output
- transcript inspection
- continuation
- local archive/removal
- project-scoped task views
- basic status/error reporting

The Codex App Server can already provide:

- durable thread identity
- durable session history
- turn execution
- thread listing and reading
- live events during active turns
- approval request notifications
- persisted session records

The highest-leverage next work is:

1. make events queryable as first-class PowerShell objects;
2. keep `Receive-CodexTask` focused on receiving task output;
3. move telemetry filtering toward `Get-CodexEvent` instead of `Receive-CodexTask -Show*`;
4. make approvals inspectable and governable instead of only auto-accepted;
5. make artifacts a modest derived view over data that already exists;
6. clarify which `PSUnplugged.CodexTask` fields are stable public contract.

## Open Questions

- Which `PSUnplugged.CodexTask` properties should be guaranteed as public contract?
- Should the event command be named `Get-CodexEvent`, `Receive-CodexEvent`, or something task-scoped like `Get-CodexTaskEvent`?
- Can approval requests be safely persisted when the app-server emits them live, or must the handling stay within the active JSON-RPC session?
- What artifact types can be derived reliably from Codex session data today?
- Should `Watch-CodexTask` be a new command, or should `Wait-CodexTask -Tail` remain the watch surface?
- Should branch/worktree features live in PSUnplugged or be left to Git/GitHub-specific tooling?
