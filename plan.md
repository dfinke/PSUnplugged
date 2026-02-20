I have a PowerShell project called **PSUnplugged** — a terminal-native agentic client for the OpenAI Codex App Server.

Current files:
- `CodexAppServer.psm1` — the core module (session, threads, turns, JSON-RPC)
- `Chat-Codex.ps1` — interactive chat REPL
- `ShowMarkdown.psm1` — terminal Markdown renderer
- `QuickStart.ps1` — usage examples

I need you to reorganize and rename this into a proper PowerShell module structure ready for the PowerShell Gallery.

**What I want:**

1. Rename `CodexAppServer.psm1` → `PSUnplugged.psm1` — keep all existing functions, no logic changes
2. Create `PSUnplugged.psd1` — a proper module manifest with:
   - ModuleVersion `0.1.0`
   - Author `Douglas Finke`
   - Description: `Terminal-native agentic AI for PowerShell. No IDE required.`
   - PowerShellVersion `7.0`
   - FunctionsToExport — all public functions currently exported
   - ProjectUri `https://github.com/dfinke/PSUnplugged`
   - LicenseUri pointing to MIT
   - Tags: `AI`, `Agent`, `Codex`, `OpenAI`, `LLM`, `MCP`, `Agentic`
3. Move `Chat-Codex.ps1` → `Examples/Start-AgentChat.ps1` — update any module import paths
4. Move `QuickStart.ps1` → `Examples/QuickStart.ps1` — update any module import paths
5. Keep `ShowMarkdown.psm1` as-is for now — it will be released separately

**Do not change any function logic or names.** Structure and naming only.

Final structure should be:
```
PSUnplugged.psm1
PSUnplugged.psd1
ShowMarkdown.psm1
Examples/
  Start-AgentChat.ps1
  QuickStart.ps1
README.md
```
