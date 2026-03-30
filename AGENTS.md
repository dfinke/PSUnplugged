# AGENTS.md

This file applies to the entire repository.

## Repo Overview

- `PSUnplugged.psm1`: main module entry point for session management, turns, and JSON-RPC calls to the Codex app server.
- `PSUnplugged.psd1`: module manifest, exported function list, Gallery metadata, and release version.
- `Threads/PSUnplugged.Threads.psm1`: higher-level project and thread helpers layered on top of the core session commands.
- `ShowMarkdown.psm1`: terminal Markdown rendering helpers.
- `Examples/`: runnable examples and smoke-test entry points.
- `.codex-app-schema/`: generated schema snapshots; treat these as generated artifacts and update them intentionally as a set.

## Working Style

- Keep changes PowerShell-native and compatible with PowerShell 7+.
- Prefer focused edits that match the current repo style over broad refactors.
- Avoid introducing IDE-specific assumptions; this project is intentionally terminal-first.
- Keep README and examples aligned with the current feature set when behavior changes.

## When Updating Public Surface Area

- If you add or remove exported commands, update `FunctionsToExport` in `PSUnplugged.psd1`.
- If you change user-facing behavior, update the relevant examples in `Examples/` and any matching docs in `README.md` or `Threads/README.md`.
- If you bump the module version, update all three version definitions:
  - `PSUnplugged.psd1`
  - `PSUnplugged.psm1`
  - `Threads/PSUnplugged.Threads.psm1`

## Validation

Use the lightest checks that fit the change:

```powershell
Import-PowerShellDataFile .\PSUnplugged.psd1 | Select-Object ModuleVersion
Import-Module .\PSUnplugged.psd1 -Force
git diff --check
```

If `.codex-app-schema/` changes, also validate the JSON files:

```powershell
Get-ChildItem -Recurse .\.codex-app-schema -Filter *.json |
    ForEach-Object { Get-Content -Raw -Path $_.FullName | ConvertFrom-Json | Out-Null }
```

If runtime session code changes and the environment is available, do a manual smoke test with the example scripts after ensuring `@openai/codex` is installed and authentication is configured.

## Notes

- There is no formal automated test suite in this repo yet.
- Prefer additive, readable docs over placeholder scaffolding.
- Do not hand-edit generated schema files unless the change is intentionally part of the generated output update.
