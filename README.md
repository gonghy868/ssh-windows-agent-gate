# SSH Windows Agent Gate

> SSH ForceCommand sandbox for AI agents on Windows.
> Blacklist + read whitelist + write path restriction — secure agent-to-Windows access without giving full shell.

## Why

When your AI agent (running on a Linux cloud server) needs to read/write files on your Windows machine via SSH, you face a dilemma:

- **Full shell access** = agent can run any command, delete any file, install malware
- **No access** = agent is blind to your Windows environment

Gate solves this by sitting between the agent and PowerShell — intercepting every command, checking it against three layers of security, and only allowing safe operations.

## Full Architecture

```
User
  ├─ (via messaging app: Feishu / Telegram / Discord / etc.)
  │     ↓
  │  Hermes Gateway (runs on cloud VM)
  │     ↓
  └─ (via Hermes Desktop: Electron GUI client)
        ↓
Cloud VM (Linux)
  └─ AI Agent (Hermes / Claude Code / Codex / any agent)
        ↓ SSH (user: agent-user)
Windows Machine
  ├─ OpenSSH Server
  │    └─ ForceCommand → Gate.ps1
  │         ├─ Blacklist (global, executed first)
  │         ├─ Read Whitelist (no path restriction)
  │         └─ Write Path Restriction (workspace only)
  └─ PowerShell (if Gate allows)
```

### How the pieces fit

This architecture was built for a specific real-world setup:

1. **User talks to the agent** from anywhere — a chat app (Feishu, Telegram, Discord, etc.) or a desktop GUI ([Hermes Desktop](https://github.com/NousResearch/hermes-agent)). Messages go to the agent running on a cloud VM.

2. **The agent lives on a cloud VM** (Linux, ~$5-15/month). It has internet access, can run code, call APIs, and search the web — but no direct access to your local files.

3. **The agent reaches your Windows machine via SSH** and Gate controls every command. The agent can read files from anywhere on disk (to analyze logs, check configs, browse directories) and write files into a locked-down workspace directory (to deliver reports, generate code, save artifacts).

4. **The workspace is shared** — files written by the agent appear immediately on your Windows desktop. Open them, edit them, move them, or feed them to other tools.

This means you get a **cloud-powered AI agent** with **local Windows access**, without giving the agent free rein over your machine.

### Why not run the agent on Windows directly?

| Factor | Cloud Linux VM | Windows local |
|--------|---------------|---------------|
| Cost | $5-15/month | Free (existing hardware) |
| Uptime | 24/7 | Depends on PC being on |
| GPU access | Expensive | ✅ Dedicated GPU |
| Agent ecosystem | ✅ Mature (Linux-first) | Limited |
| Security isolation | ✅ Sandboxed by default | Gate needed |
| File access | No local files | ✅ Full access |

Cloud + Gate gives you the best of both: a 24/7 agent with local filesystem access.

### Real-world walkthrough

Here's what this setup looks like in daily use:

> **"帮我看一下桌面上那份报价单里的数字对不对"**
>
> 1. I send this message in Feishu (or type it in Hermes Desktop)
> 2. The agent on the cloud VM receives it, reads the file via SSH+Gate:
>    `Get-Content "C:\Users\me\Desktop\报价单-2026-06-01.xlsx"`
> 3. Gate lets the read through (no path restriction for reads)
> 4. The agent extracts the numbers, compares them, writes a summary back to workspace:
>    `Set-Content D:\agent-user\workspace\price-check-report.md -Value "..." `
> 5. The summary lands on my Windows desktop as a file I can open immediately
> 6. The agent replies in Feishu with the conclusion

The Gate is invisible to the user — I talk to my agent normally, and it just *has* access to my local files without me needing to copy things to the cloud.

Data flows both ways:
- **Agent reads from Windows**: logs, configs, documents, screenshots, code files
- **Agent writes to Windows**: reports, generated code, downloaded files, analysis results

All via SSH commands, all through Gate. No cloud storage sync, no file upload portal, no shared drives.

## Three-Layer Defense

### Layer 1: Blacklist (Global, executed first)

Commands blocked regardless of context:

```
Restart-Computer, Stop-Computer, shutdown /s /r
net user, net localgroup, reg, format
icacls, cacls, takeown
Invoke-Expression
Expand-Archive, Compress-Archive
```

Blacklist runs **before** any other check — prevents `&&` / `;` / `|` chaining to bypass whitelist logic.

### Layer 2: Read Whitelist (No path restrictions)

Agent can read the entire filesystem. Whitelisted commands include:

```
dir, ls, type, cat, Get-Content, Get-ChildItem
Get-Item, Get-ItemProperty, Test-Path
Select-String, echo, Write-Host, Write-Output
Get-*, Select-*, Where-*, Format-*, Measure-*
$env:VAR (read environment variables)
```

Redirect operators (`>`, `>>`) are blocked — agent cannot overwrite files using shell redirection.

### Layer 3: Write Path Restriction (Exact match)

Write operations are only allowed under `D:\\agent-user\\workspace\\` (configurable). Commands:

```
Set-Content, Add-Content, Out-File
New-Item, Copy-Item, Move-Item
Remove-Item, del, rm, erase
Write-*, Clear-Content, Clear-Item
```

The path check uses a trailing backslash to prevent prefix-bypass attacks (e.g. `workspace_data` cannot match `workspace\\`).

## Usage

### Deployment

1. Install OpenSSH Server on Windows
2. Create a dedicated Windows user (e.g. `agent-user`, member of Administrators)
3. Place `ssh-gate.ps1` at the configured path
4. Add to `sshd_config`:

```
Match User agent-user
    ForceCommand powershell -NoProfile -File "D:\\path\\to\\ssh-gate.ps1"
```

### Reading Files

```powershell
# Any path, read-only
Get-Content D:\\documents\\report.txt
dir C:\\Users\\*\\Desktop\\*
Get-ChildItem D:\\data\\ -Recurse
```

### Writing Files (workspace only)

```powershell
# Only under workspace directory
Set-Content D:\\agent-user\\workspace\\output.txt -Value "hello"
New-Item -ItemType Directory D:\\agent-user\\workspace\\projects\\ -Force
```

### File Transfer: How data moves between cloud and Windows

This is the #1 question people ask about this setup. Here's the complete picture.

#### What works and what doesn't

| Method | Works with Gate? | Why |
|--------|-----------------|-----|
| `ssh user@host "Get-Content file.txt"` (read via SSH) | ✅ **Yes** | Read whitelist, no path restriction |
| `ssh user@host "Set-Content workspace\file.txt -Value ..."` (write via SSH) | ✅ **Yes** | Write restricted to workspace |
| `scp user@host:file.txt .` | ❌ **No** | SCP binary protocol corrupted by Gate |
| `sftp user@host` | ❌ **No** | Same reason — ForceCommand breaks SFTP |
| Cloud sync (Dropbox / OneDrive / Nextcloud) | ✅ **Yes** | Independent of Gate entirely |

So the flow is: **SSH commands for everything, SCP/SFTP is not needed.**

#### Complete walkthrough: Getting a file from Windows to the cloud

Say you want your cloud agent to analyze `C:\Users\me\Documents\report.pdf`:

**Step 1 — Read the file (agent initiates from cloud)**

```bash
# SSH into Windows, read file as text
ssh agent-user@windows-pc "Get-Content 'C:\Users\me\Documents\report.pdf' -Raw"
```

For binary files (PDF, images, Excel), read as base64:

```bash
ssh agent-user@windows-pc "[Convert]::ToBase64String([System.IO.File]::ReadAllBytes('C:\Users\me\Documents\report.pdf'))"
```

**Step 2 — The agent processes it** (on the cloud VM, no file movement needed)

The agent has the content in its context. It can analyze, summarize, extract data, whatever.

**Step 3 — Write results back to Windows (agent initiates from cloud)**

```bash
# Write a report to the workspace folder
ssh agent-user@windows-pc "Set-Content 'D:\agent-user\workspace\analysis-report.md' -Value '# Analysis Results\n...'"
```

The file lands at `D:\agent-user\workspace\analysis-report.md` on your Windows desktop. Open it directly.

#### Reverse flow: Getting a file from cloud to Windows

Say your cloud agent generated a chart image:

```bash
# On the cloud VM, encode the file
BASE64=$(base64 -w0 /home/ubuntu/output/chart.png)

# Write it to Windows workspace via SSH
ssh agent-user@windows-pc "Set-Content 'D:\agent-user\workspace\chart.b64' -Value '$BASE64'"

# Decode it on Windows (still via SSH, all through Gate)
ssh agent-user@windows-pc "[System.IO.File]::WriteAllBytes('D:\agent-user\workspace\chart.png', [System.Convert]::FromBase64String([System.IO.File]::ReadAllText('D:\agent-user\workspace\chart.b64').Trim()))"

# Clean up the temp base64 file
ssh agent-user@windows-pc "Remove-Item 'D:\agent-user\workspace\chart.b64'"
```

#### The workspace pattern

The `D:\agent-user\workspace\` directory is the **shared bridge**:
- The agent writes files there → they appear on your Windows immediately
- You put files there → the agent can read them
- Think of it like a shared folder or a network drive, but secured by Gate

#### If you really want SCP/SFTP

Temporarily disable ForceCommand for an admin user, transfer, re-enable:

```powershell
# As admin, edit C:\ProgramData\ssh\sshd_config, comment out ForceCommand line
# Restart SSH service, transfer files as admin, then uncomment and restart
Restart-Service sshd
```

Not recommended for routine use — it's a temporary hole in the security model.

### Claude Code Integration (Experimental)

Gate has partial support for Claude Code CLI (`^claude\\b`), allowing specific safe flags:

```
claude --version        ✅ Pure info
claude --help           ✅ Pure info
claude --doctor         ✅ Pure info
claude -p "task" --allowedTools "Read,Edit"  ✅ Restricted
claude --allowedTools "Bash"                  ❌ No Read flag
```

This is **experimental** and requires Claude Code CLI installed in PATH.

## Security Considerations

### What Gate Protects Against

| Attack | Gate's Defense |
|--------|---------------|
| Agent writes malware to system dir | Write restricted to workspace |
| Agent runs shutdown / format / regedit | Blacklisted |
| Agent chains commands (`&&`, `;`, `|`) | Blacklist runs first |
| Agent tries `workspace_data` path | Trailing `\\` prevents prefix match |
| Agent modifies Gate itself | Locked file (PowerShell holds handle) |
| Agent writes to Startup folder | Not under workspace path |

### What Gate Does NOT Protect Against

- **Agent uses SOCKS proxy through SSH** — SSH port forwarding happens before Gate runs. If agent controls your cloud server, it can use your Windows as a network pivot. Mitigation: secure your cloud server.
- **API key theft from cloud server** — Gate protects Windows, not the cloud. .env files on the cloud server are outside Gate's scope.

### Attack Vectors Found During Development (v8.9 → v8.11)

1. `dir | Invoke-Expression` — pipe to IEX bypass
2. `Remove-Item ...\\workspace_data\\...` — path prefix bypass
3. `claude --help -p "shutdown /s"` — flag reuse to smuggle payload
4. `claude --allowedTools "Bash"` — dangerous tool without Read oversight

## Version History

| Version | Changes |
|---------|---------|
| v8.1 | Initial release — basic whitelist |
| v8.2 | `Get-*` wildcard whitelist |
| v8.8 | Claude allowed flags array |
| v8.9 | Blacklist moved to top (prevent chaining bypass) |
| v8.10 | `Invoke-Expression` added to blacklist |
| v8.11 | Exact path matching with trailing backslash |
| v8.12 | Fixed `\\bclaude\\b` → `^claude\\b` (path false positive) |

## Related Work

- [OpenSSH ForceCommand documentation](https://man.openbsd.org/sshd_config.5#ForceCommand)
- [Restricting SSH Users Guide](https://www.jamieweb.net/blog/restricting-and-locking-down-ssh-users/)
- GitHub issue [openai/codex#12226](https://github.com/openai/codex/issues/12226) — Windows SSH sandbox challenges

## License

MIT
