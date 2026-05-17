# PSUnplugged Agent Infrastructure Plan

## Framing

PSUnplugged should be evaluated less as another AI chat UI and more as a PowerShell-native control plane for agent work.

The core shift:

```text
Old model:
human <-> chat window <-> model

Emerging model:
human
  -> task/session/work item
  -> agent runtime
  -> tools/files/git/tests/apis
  -> events/state/artifacts
```

In this model, the durable session is not just a transcript. It is operational state:

- history
- approvals
- retries
- branches
- worktrees
- artifacts
- logs
- checkpoints

The UI becomes a visibility, steering, approval, and observability layer. The deeper value is the programmable substrate underneath.

## Thesis

PSUnplugged may be closer to "kubectl for agents" than to "another chat app", but the better long-term framing is:

> PowerShell-native agent operations.

That means task objects, event streams, artifacts, approvals, workspaces, policies, and adapters over one or more agent runtimes.

The winning abstraction is likely `Task`, not `Chat`.

## What Is Real

Agent work has meaningful state outside the chat text:

- input intent
- repo, working directory, branch, or worktree
- runtime and model configuration
- tool calls
- approvals
- generated diffs
- failures and retries
- logs and events
- artifacts
- final disposition

Once users can do this, PSUnplugged has crossed from conversational UX into operations:

```powershell
Get-AgentTask | Where-Object NeedsApproval
```

PowerShell is a natural fit because it treats operational resources as inspectable objects that can be filtered, grouped, piped, formatted, exported, and automated.

## What Is Hand-Wavy

The Kubernetes, Jenkins, GitHub Actions, and Airflow analogies are useful, but should not be copied too literally.

Traditional job systems work with relatively crisp lifecycle boundaries. Agent work is fuzzier:

- an agent can "succeed" with a poor patch
- an agent can "fail" after discovering valuable context
- a task may need steering without being failed
- a retry may need a new strategy, not just a rerun
- a model swap is not equivalent to retrying a deterministic job
- logs may not fully explain why the agent made a decision

A single flat `Status` field will become leaky quickly. PSUnplugged should separate execution state from attention, artifact, repo, and review state.

## Natural Architecture

Use a resource-oriented model.

Core resources:

- `AgentTask`: durable user or work-item intent
- `AgentRun`: one execution attempt for a task
- `AgentSession`: conversation/runtime thread backing a run
- `AgentWorkspace`: filesystem, repo, branch, and worktree context
- `AgentEvent`: append-only operational event
- `AgentApproval`: pending or completed human authorization
- `AgentArtifact`: produced files, patches, summaries, screenshots, logs, test output, or PRs
- `AgentCheckpoint`: resumable state marker
- `AgentRuntime`: backend runtime such as Codex or a future adapter

Important distinction:

- retries should create new `AgentRun` records
- previous runs should remain inspectable
- the transcript should be one artifact, not the database model

## Candidate Lifecycle

Possible execution states:

```text
Created
Queued
Running
WaitingForApproval
WaitingForInput
ToolBlocked
PatchReady
Reviewing
NeedsRepair
Succeeded
Failed
Abandoned
Superseded
```

Likely separate state dimensions:

- `ExecutionStatus`
- `UserAttentionStatus`
- `ArtifactStatus`
- `RepoStatus`
- `ReviewStatus`

This allows queries like:

```powershell
Get-AgentTask | Where-Object NeedsApproval
Get-AgentTask | Where-Object { $_.Duration -gt [TimeSpan]::FromMinutes(30) }
Get-AgentTask | Group-Object Repo
```

## Command Surface

Early command candidates:

```powershell
Start-AgentTask
Get-AgentTask
Wait-AgentTask
Watch-AgentTask
Stop-AgentTask
Restart-AgentTask
Approve-AgentTask
Deny-AgentTask
Receive-AgentEvent
Get-AgentArtifact
Get-AgentPatch
Invoke-AgentReview
Publish-AgentResult
Publish-DraftPR
```

Example object flow:

```powershell
$task = Start-AgentTask -Issue 142 -Repo api-server

$task.Status
$task.Events
$task.Branch
$task.Worktree
$task.Artifacts
$task.PendingApprovals
```

Composable workflow examples:

```powershell
Get-GitHubIssue -Label bug |
    Start-AgentTask |
    Wait-AgentTask |
    Invoke-AgentReview |
    Publish-DraftPR
```

```powershell
Get-AgentTask |
    Where-Object NeedsApproval |
    Approve-AgentTask
```

```powershell
Get-AgentTask |
    Where-Object Failed |
    Restart-AgentTask -Model claude-opus
```

## Most Important Primitive: Events

An append-only event stream should be treated as a foundational primitive.

Candidate event types:

- `TaskStarted`
- `RunStarted`
- `WorkspaceCreated`
- `ModelSelected`
- `ToolCallStarted`
- `ToolCallFinished`
- `ApprovalRequested`
- `ApprovalGranted`
- `ApprovalDenied`
- `FileChanged`
- `TestsRun`
- `RunFailed`
- `RunRetried`
- `ArtifactPublished`
- `PullRequestCreated`

With durable events, PSUnplugged can build multiple views without losing provenance.

Example:

```powershell
Start-AgentTask -Issue 142 | Receive-AgentEvent -Follow
```

## Other Critical Primitives

- Stable IDs for tasks, runs, sessions, artifacts, approvals, and events.
- Workspace binding to repo, cwd, branch, and worktree.
- Lifecycle operations: start, wait, cancel, resume, retry.
- Attention model: needs approval, needs input, needs review.
- Artifact model: patches, files, logs, screenshots, summaries, test results, PR URLs.
- Policy model: what can be auto-approved and what requires a person.
- Routing model: model, runtime, task type, repo, priority, profile.
- Checkpoint model: resumable state, not just append-only logs.
- Provenance model: what changed, why, by which run, from which prompt and runtime config.

## Collision Zones

Codex may want to own:

- agent runtime
- model and tool orchestration
- approvals
- session history
- workspace mutation
- task continuation

GitHub may want to own:

- issue-to-branch-to-PR workflows
- code review
- CI state
- merge gates
- project metadata

VSCode may want to own:

- developer attention
- inline edits
- workspace context
- debugging
- extension-driven agent UX

PSUnplugged should avoid competing directly with the best chat UI, IDE UX, or PR interface. Its stronger position is as an operational control plane and scripting surface over agent runtimes.

## Design Guidance

Prefer adapter-friendly abstractions:

```text
CodexSession
GitHubIssue
LocalWorktree
AgentTask
AgentRun
AgentArtifact
```

Avoid hard-coding the entire model around one backend's current session shape.

Make PSUnplugged excellent at:

- orchestration
- inspection
- batch operations
- shell pipelines
- cross-repo workflows
- durable local views
- automation glue
- exporting and reporting state

## PowerShell Fit

PowerShell is unusually well suited because the object pipeline is already an operations model.

Useful native affordances:

```powershell
$task | Format-List *
$task.Events | Format-Table Time, Type, Message
$task.Artifacts | Out-GridView
```

PowerShell strengths to lean into:

- object pipelines
- filtering and grouping
- formatting views
- remoting
- credential handling
- long-running administrative workflows
- module discoverability
- `Get-Command`
- `Get-Help`
- tab completion

The design should make agent work feel like native infrastructure administration.

## Risks

- Overfitting to the current Codex session API.
- Creating lifecycle states that cannot survive real agent ambiguity.
- Treating chat transcripts as the source of truth.
- Making bulk approval too easy without policy and provenance.
- Building a scheduler before the task and event model are solid.
- Copying Kubernetes concepts instead of learning from them.
- Blurring local state, runtime state, and GitHub state.

## Near-Term Plan

1. Define the first durable `AgentTask` object shape.
2. Define `AgentRun` separately from `AgentTask`.
3. Define a minimal append-only `AgentEvent` schema.
4. Add read-only query commands before broad mutation commands.
5. Prototype `Start-AgentTask`, `Get-AgentTask`, `Wait-AgentTask`, and `Receive-AgentEvent`.
6. Model approvals as first-class objects.
7. Model artifacts as first-class objects.
8. Add formatting views for tasks, events, approvals, and artifacts.
9. Keep the implementation adapter-friendly around Codex.
10. Document the difference between chat sessions and operational tasks.

## Open Questions

- What is the minimum useful durable store: JSON files, SQLite, PowerShell data files, or Codex-owned state?
- Should `AgentTask` be local-only, or should it map to GitHub issues/projects when available?
- Should worktrees be mandatory for repo-mutating tasks?
- What approval operations are safe to automate?
- How much of the event stream can come from Codex today?
- What should be considered an artifact versus an event?
- Should task retry preserve the same branch or create a new branch/worktree?
- How should PSUnplugged represent multiple runtimes without diluting the core UX?
