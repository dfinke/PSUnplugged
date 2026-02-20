# PSUnplugged

> The IDE had a good run. PowerShell agentic AI, unplugged.

A terminal-native agentic client for the [OpenAI Codex App Server](https://github.com/openai/codex). Multi-turn conversations, streaming responses, full Markdown rendered in your terminal. No VS Code. No extensions. No GUI.

Just PowerShell.

> **This release is read-only.** The agent can read files, answer questions, and reason about your code — but won't write or execute anything. Read/write mode with approval flow is coming in [AI Agent Forge](https://forms.gle/gvw8cU2pgFeXWMNZA).

---

## Why

The IDE with a side-panel chat window is a fossil. The future is agentic workflows running wherever your code runs — including the terminal you already have open.

PSUnplugged talks directly to the Codex App Server over JSON-RPC via stdio. It gives you a first-class agentic experience from pure PowerShell, on any machine, in any pipeline.

And because the Codex App Server is provider-agnostic, so is PSUnplugged. Point it at OpenAI, Azure, Ollama, Mistral — swap a line in config.toml and you're done.

---

## What's Inside

```
PSUnplugged.psm1          # module — session, threads, turns, JSON-RPC
PSUnplugged.psd1          # module manifest (PowerShell Gallery ready)
ShowMarkdown.psm1         # terminal Markdown renderer
Examples/
  Start-AgentChat.ps1    # interactive REPL — multi-turn chat, streaming, slash commands
  QuickStart.ps1         # working examples for every feature
```

| File | What it does |
|---|---|
| `PSUnplugged.psm1` | Full PowerShell module — session management, threads, turns, low-level JSON-RPC |
| `PSUnplugged.psd1` | Module manifest — version, author, tags, Gallery metadata |
| `Examples/Start-AgentChat.ps1` | Interactive REPL — multi-turn chat, streaming, slash commands |
| `Examples/QuickStart.ps1` | Working examples for every feature |
| `ShowMarkdown.psm1` | Terminal Markdown renderer — headers, code blocks, tables with box-drawing chars |

---

## Quick Start

**Prerequisites**

1. **Node.js 18+** — [nodejs.org](https://nodejs.org) (provides `npm`)
2. **PowerShell 7+** — [aka.ms/powershell](https://aka.ms/powershell) (Windows ships with 5.1; this module requires 7)
3. **Codex CLI**
   ```powershell
   npm i -g @openai/codex
   ```
4. **Authenticate** — choose one:
   - **ChatGPT account** (free tier, supports `gpt-5.1-codex` only):
     ```powershell
     codex login
     ```
   - **OpenAI API key** (required for `gpt-4.1`, `gpt-4o`, etc.) — pass it directly at runtime, no login needed:
     ```powershell
     .\Examples\Start-AgentChat.ps1 -ApiKey $env:OPENAI_API_KEY
     ```
5. **Clone this repo**
   ```powershell
   git clone https://github.com/dfinke/PSUnplugged
   cd PSUnplugged
   ```

> **Windows tip:** If `Start-CodexSession` can't find the binary, set `$env:CODEX_EXE` to the full path of `codex.exe`:
> ```powershell
> $env:CODEX_EXE = (Get-ChildItem (npm root -g) -Recurse -Filter codex.exe | Where-Object { $_.Length -gt 1MB } | Select-Object -First 1).FullName
> ```

**Interactive chat**

```powershell
# ChatGPT account (default model)
.\Examples\Start-AgentChat.ps1

# OpenAI API key — use any model
.\Examples\Start-AgentChat.ps1 -Model gpt-4.1 -ApiKey $env:OPENAI_API_KEY
```

**One-liner from a script**

```powershell
Import-Module .\PSUnplugged.psm1

$session = Start-CodexSession
$answer  = Invoke-CodexQuestion -Session $session -Text "What does this repo do?"
Write-Host $answer
Stop-CodexSession -Session $session
```

**Multi-turn conversation**

```powershell
$session = Start-CodexSession
$thread  = New-CodexThread -Session $session -Cwd (Get-Location).Path

$r1 = Invoke-CodexTurn -Session $session -ThreadId $thread.id -Text "List the files here"
$r2 = Invoke-CodexTurn -Session $session -ThreadId $thread.id -Text "Now explain what each one does"

Stop-CodexSession -Session $session
```

**Slash commands inside the chat REPL**

```
/new         start a fresh thread
/model <n>   switch model and start a new thread
/verbose     toggle raw JSON-RPC output
/quit        exit
```

---

<!-- Provider-Agnostic section under review — wire_api compat being validated across providers

## Provider-Agnostic

The Codex App Server supports any OpenAI-compatible provider. Add a block to `~/.codex/config.toml` (global) or `.codex/config.toml` in your project root (project-scoped) and point `env_key` at the environment variable holding your API key — Codex picks it up automatically, nothing hardcoded.

> **Project-scoped config:** drop a `.codex/config.toml` in your repo root and Codex uses it automatically for that project (trusted projects only). Providers, MCP servers, model settings — all scoped to that repo. Nothing bleeds into your global config.

Example `config.toml`:

```toml
# xAI Grok
[model_providers.xai]
name = "xAI"
base_url = "https://api.x.ai/v1"
env_key = "XAI_API_KEY"
wire_api = "chat"

# Mistral
[model_providers.mistral]
name = "Mistral"
base_url = "https://api.mistral.ai/v1"
env_key = "MISTRAL_API_KEY"
wire_api = "chat"

# Ollama (local, no key needed)
[model_providers.ollama]
name = "Ollama"
base_url = "http://localhost:11434/v1"

# Azure OpenAI
[model_providers.azure]
name = "Azure OpenAI"
base_url = "https://YOUR_RESOURCE.openai.azure.com/openai/v1"
env_key = "AZURE_OPENAI_API_KEY"
wire_api = "responses"
```

Then in PowerShell:

```powershell
$env:XAI_API_KEY = "your-key-here"
```

Or for a quick one-off redirect without touching config.toml:

```powershell
$env:OPENAI_BASE_URL = "http://localhost:11434/v1"
```

> **Note:** Providers that don't speak the OpenAI wire format (like Anthropic) need a translation proxy such as [LiteLLM](https://github.com/BerriAI/litellm).

-->

## More Than a Chat Client

The Codex App Server isn't just a model endpoint — it's a full agentic runtime. Think of it as MCP on steroids:

- **MCP client built in** — wire up any MCP server, local or remote, and the model sees its tools natively
- **Threads and memory** — persistent multi-turn conversations with full history
- **Approval policies** — control whether the agent can execute commands and modify files, or stay read-only
- **AGENTS.md and Skills** — already have an AGENTS.md in your repo? It works automatically. Your project context, your instructions, zero extra config
  - `AGENTS.md` lives at your **repo root** (e.g. `c:\PSUnplugged\AGENTS.md`) — the Codex App Server picks it up automatically for any trusted project checkout
  - **Skills** live under `.codex/skills/` in your repo root (e.g. `.codex/skills/my-skill.md`) — each file describes a reusable capability the model can invoke by name
  - A **global** `AGENTS.md` can also live at `~/.codex/AGENTS.md` to apply instructions across all projects
  - Skills and AGENTS.md stack: global instructions + repo-level instructions + skills are all merged into the agent's context at session start
- **Provider-agnostic** — swap models without changing client code

PSUnplugged is the PowerShell binding to that runtime. When OpenAI ships the cloud version of the app-server, the same code points at a URL instead of a local process.

---

## Coming Next

**Read/write mode** — the agent can execute commands, modify files, and take action in your repo. Includes an approval flow so nothing runs without your sign-off. Dropping at launch of AI Agent Forge.

**MCP support** — local and remote servers, drop-in config. The model sees them as callable tools. Web search, databases, custom APIs — no extra client code needed.

**Much more** — PSUnplugged is just the client. The real magic is in the Codex App Server, and we're just getting started. Expect rapid iteration, new features, and a lot of surprises.

**[Join the AI Agent Forge waitlist →](https://forms.gle/gvw8cU2pgFeXWMNZA)**

---

## Built With

Vibe coded entirely with [Claude](https://claude.ai) (Opus). Powered by the [OpenAI Codex App Server](https://github.com/openai/codex).

---

## License

MIT — use it, fork it, ship it.