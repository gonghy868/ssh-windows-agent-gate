<#
.SYNOPSIS
SSH Gate — ForceCommand sandbox for AI agents on Windows.
Blocks dangerous commands, allows read-anywhere, restricts writes to workspace.
.DESCRIPTION
Designed to be set as ForceCommand in sshd_config for a dedicated agent user.
Every SSH command passes through Gate before reaching PowerShell.
.NOTES
Version: 8.12
Author: Based on production use with Hermes Agent
License: MIT
#>

# --- Config ---
$workspace = "D:\agent-user\workspace"
$gate_user = "agent-user"

# --- Blacklist (global, executed FIRST — prevents && / ; / | chaining) ---
$blocked_patterns = @(
    # System manipulation
    '\bRestart-Computer\b', '\bStop-Computer\b', '\bshutdown\b',
    # User/security management
    '\bnet\s+user\b', '\bnet\s+localgroup\b',
    # Registry
    '\breg\b',
    # Disk operations
    '\bformat\b',
    # Permission changes
    '\bicacls\b', '\bcacls\b', '\btakeown\b',
    # Archive operations (can be used to plant files)
    '\bExpand-Archive\b', '\bCompress-Archive\b',
    # Code execution
    '\bInvoke-Expression\b'
)

$cmd = $args -join ' '

# --- Step 0: Path traversal check ---
if ($cmd -match '\.\.[\\/]') {
    Write-Host '[GATE] BLOCKED: Path traversal detected'
    exit 1
}

# --- Step 1: Blacklist check ---
foreach ($pattern in $blocked_patterns) {
    if ($cmd -match $pattern) {
        Write-Host "[GATE] BLOCKED: Command matched blacklist pattern: $pattern"
        exit 1
    }
}

# --- Step 2: Claude Code (experimental) ---
if ($cmd -match '^claude\b') {
    $pure_info = $cmd -match '^\s*claude\b\s*--(version|help|doctor)\s*$'
    $tools_ok = $cmd -match '--allowedTools\s+["'']?[^"'']*Read'
    if ($pure_info -or ($cmd -match '--allowedTools' -and $tools_ok)) {
        # Load user PATH for npm global modules
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
        Invoke-Expression $cmd; exit $LASTEXITCODE
    } else {
        if ($cmd -match '--allowedTools') {
            Write-Host '[GATE] BLOCKED: --allowedTools must include Read'
        } else {
            Write-Host '[GATE] BLOCKED: claude requires allowed flag (--version/--help/--doctor/--allowedTools)'
        }
        exit 1
    }
}

# --- Step 3: Read-only operations (no path restriction, can read entire disk) ---
$read_only_patterns = @(
    '^dir\b',
    '^ls\b',
    '^type\b',
    '^cat\b',
    '^Get-Content\b',
    '^echo\b',
    '^pwd\b',
    '^whoami\b',
    '^hostname\b',
    '^findstr\b',
    '^Select-String\b',
    '^Get-ChildItem\b',
    '^Get-Item\b',
    '^Test-Path\b',
    '^Get-ItemProperty\b',
    '^Write-Host\b',
    '^Write-Output\b',
    '^Write-Warning\b',
    '^Get-\w+\b',
    '^Select-\w+\b',
    '^Where-\w+\b',
    '^Format-\w+\b',
    '^Measure-\w+\b',
    '^Compare-\w+\b',
    '^Group-\w+\b',
    '^Sort-\w+\b',
    '^Out-Host\b',
    '^Out-String\b',
    '^Out-Null\b',
    '^\$env:\w+\b'
)

foreach ($pattern in $read_only_patterns) {
    if ($cmd -match $pattern) {
        # Block shell redirect (>, >>)
        if ($cmd -match '>[>]?\s') {
            Write-Host '[GATE] BLOCKED: Redirect operator not allowed in read-only mode'
            exit 1
        }
        Invoke-Expression $cmd; exit $LASTEXITCODE
    }
}

# --- Step 4: Write operations (path restricted) ---
$write_patterns = @(
    '^Set-Content\b', '^Add-Content\b', '^Out-File\b',
    '^New-Item\b', '^Copy-Item\b', '^cp\b',
    '^Write-\w+\b',
    '^del\b', '^Remove-Item\b', '^rm\b', '^erase\b',
    '^Clear-Content\b', '^Clear-Item\b',
    '^Move-Item\b', '^mv\b', '^rename\b', '^ren\b'
)

foreach ($pattern in $write_patterns) {
    if ($cmd -match $pattern) {
        # Exact path match with trailing backslash (prevents workspace_data bypass)
        $workspace_escaped = [regex]::Escape($workspace + '\')
        if ($cmd -match $workspace_escaped) {
            # Gate self-protection: prevent deleting/modifying Gate script
            if ($cmd -match [regex]::Escape('ssh-gate.ps1') -and $cmd -match '^\s*(del|Remove-Item|rm|erase|Clear-Content)\b') {
                Write-Host '[GATE] BLOCKED: Cannot modify Gate script via remote'
                exit 1
            }
            Invoke-Expression $cmd; exit $LASTEXITCODE
        } else {
            Write-Host "[GATE] BLOCKED: Write to path outside workspace: $workspace"
            exit 1
        }
    }
}

# --- Step 5: Unknown command ---
Write-Host "[GATE] BLOCKED: Unknown command (not in whitelist)"
exit 1
