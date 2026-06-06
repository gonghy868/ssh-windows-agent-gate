# SSH Windows Agent Gate

> SSH ForceCommand sandbox for AI agents on Windows.
> Blacklist + read whitelist + write path restriction — secure agent-to-Windows access without giving full shell.

## Why

When your AI agent (running on a Linux cloud server) needs to read/write files on your Windows machine via SSH, you face a dilemma:

- **Full shell access** = agent can run any command, delete any file, install malware
- **No access** = agent is blind to your Windows environment

Gate solves this by sitting between the agent and PowerShell — intercepting every command, checking it against three layers of security, and only allowing safe operations.

## Architecture

```
Agent (Cloud Linux)
    ↓ SSH (user: agent-user)
Windows OpenSSH Server
    ↓ ForceCommand (sshd_config)
Gate.ps1 (PowerShell script)
    ↓ Blacklist → Read Whitelist → Write Path Check
PowerShell (if allowed)
```

- Gate is set as the **login shell** via sshd_config's `ForceCommand` for the agent user
- Every SSH command passes through Gate before execution
- Admin users bypass Gate entirely (no ForceCommand)

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

Write operations are only allowed under `D:\agent-user\workspace\` (configurable). Commands:

```
Set-Content, Add-Content, Out-File
New-Item, Copy-Item, Move-Item
Remove-Item, del, rm, erase
Write-*, Clear-Content, Clear-Item
```

The path check uses a trailing backslash to prevent prefix-bypass attacks (e.g. `workspace_data` cannot match `workspace\`).

## Usage

### Deployment

1. Install OpenSSH Server on Windows
2. Create a dedicated Windows user (e.g. `agent-user`, member of Administrators)
3. Place `ssh-gate.ps1` at the configured path
4. Add to `sshd_config`:

```
Match User agent-user
    ForceCommand powershell -NoProfile -File "D:\path\to\ssh-gate.ps1"
```

### Reading Files

```powershell
# Any path, read-only
Get-Content D:\documents\report.txt
dir C:\Users\*\Desktop\*
Get-ChildItem D:\data\ -Recurse
```

### Writing Files (workspace only)

```powershell
# Only under workspace directory
Set-Content D:\agent-user\workspace\output.txt -Value "hello"
New-Item -ItemType Directory D:\agent-user\workspace\projects\ -Force
```

### File Transfer

SCP/SFTP are **not supported** — ForceCommand intercepts the SCP protocol before PowerShell runs, and Gate's output banner corrupts SCP's binary protocol.

Workaround for file transfer:
1. **Small files (<10MB):** Base64 encode → write to temp file → decode via .NET method chain
2. **Large files:** Temporarily disable ForceCommand for admin user, transfer via SCP, re-enable

### Claude Code Integration (Experimental)

Gate has partial support for Claude Code CLI (`^claude\b`), allowing specific safe flags:

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
| Agent tries `workspace_data` path | Trailing `\` prevents prefix match |
| Agent modifies Gate itself | Locked file (PowerShell holds handle) |
| Agent writes to Startup folder | Not under workspace path |

### What Gate Does NOT Protect Against

- **Agent uses SOCKS proxy through SSH** — SSH port forwarding happens before Gate runs. If agent controls your cloud server, it can use your Windows as a network pivot. Mitigation: secure your cloud server.
- **API key theft from cloud server** — Gate protects Windows, not the cloud. .env files on the cloud server are outside Gate's scope.

### Attack Vectors Found During Development (v8.9 → v8.11)

1. `dir \| Invoke-Expression` — pipe to IEX bypass
2. `Remove-Item ...\workspace_data\...` — path prefix bypass
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
| v8.12 | Fixed `\bclaude\b` → `^claude\b` (path false positive) |

## Related Work

- [OpenSSH ForceCommand documentation](https://man.openbsd.org/sshd_config.5#ForceCommand)
- [Restricting SSH Users Guide](https://www.jamieweb.net/blog/restricting-and-locking-down-ssh-users/)
- GitHub issue [openai/codex#12226](https://github.com/openai/codex/issues/12226) — Windows SSH sandbox challenges

## License

MIT
