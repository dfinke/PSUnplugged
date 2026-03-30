# Changelog

All notable changes to this project will be documented in this file.

## v0.1.1 - 2026-03-30

### Added

- Project-aware thread management commands and supporting format data in `Threads/`.
- Thread and project usage documentation in `Threads/README.md`.
- Generated `.codex-app-schema/` snapshots for Codex App Server request, response, and notification payloads.
- A root `AGENTS.md` guide for contributors and coding agents working in this repository.

### Changed

- Updated `Examples/Start-AgentChat.ps1` and core module wiring to support the new thread and project workflow.
- Refreshed `README.md` with current positioning, project-aware thread details, social badges, and AI Agent Forge messaging.
- Bumped the module version to `0.1.1` across the manifest and session defaults.

### Removed

- Obsolete schema snapshots for `TurnSteerParams`, `TurnSteerResponse`, `WindowsSandboxSetupCompletedNotification`, `WindowsSandboxSetupStartParams`, `WindowsSandboxSetupStartResponse`, and `WindowsWorldWritableWarningNotification`.
