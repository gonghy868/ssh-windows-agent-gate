# ssh-windows-agent-gate

SSH ForceCommand sandbox for AI agents on Windows.
Blacklist + read whitelist + write path restriction — secure agent-to-Windows access.

## Quick Start

1. Place `ssh-gate.ps1` on your Windows machine (e.g. `D:\agent-user\workspace\scripts\`)
2. Add to `%ProgramData%\ssh\sshd_config`:

```
Match User agent-user
    ForceCommand powershell -NoProfile -File "D:\agent-user\workspace\scripts\ssh-gate.ps1"
```

3. Restart SSH service: `Restart-Service sshd`
4. Connect from your agent: `ssh agent-user@windows-ip "dir D:\documents"`

## Test

```powershell
# Should work (read anywhere)
dir C:\Users
Get-Content D:\documents\report.txt

# Should work (write to workspace)
Set-Content D:\agent-user\workspace\test.txt -Value "hello"

# Should be blocked
shutdown /s
reg add HKLM\...
Remove-Item C:\Windows\system32\...
```

## File Transfer

SCP/SFTP are not supported (ForceCommand conflicts with SCP protocol).
Use Base64 encoding + Set-Content workaround for small files (<10MB).

```powershell
# Write base64 to temp file, then decode
[System.IO.File]::WriteAllBytes('out.bin', [System.Convert]::FromBase64String('base64data'))
```

## Design

See README.md for full architecture, security model, and attack vector analysis.
