# claude-code-statusline - mascot state hook (Windows PowerShell 5.1 and 7+).
#
# Claude Code never tells the status line whether a turn is running, so the
# hooks record it here and statusline.ps1 reads it back. Wire it up like this:
#
#   UserPromptSubmit -> mascot-hook.ps1 -State working
#   Stop             -> mascot-hook.ps1 -State done
#   StopFailure      -> mascot-hook.ps1 -State error
#
# The script writes one small file and prints nothing, so it can never disturb
# a turn. Every failure path exits 0 for the same reason.
param(
    [ValidateSet('working', 'done', 'error')]
    [string]$State = 'done'
)

$ErrorActionPreference = 'SilentlyContinue'

$payload = ''
try { $payload = [Console]::In.ReadToEnd() } catch { }

$sid = ''
try { $sid = (ConvertFrom-Json $payload).session_id } catch { }
if ([string]::IsNullOrWhiteSpace([string]$sid)) { exit 0 }

# Must match the key statusline.ps1 derives: alphanumerics only, first 8 chars.
$key = ([string]$sid) -replace '[^a-zA-Z0-9]', ''
if ($key.Length -gt 8) { $key = $key.Substring(0, 8) }
if ($key -eq '') { exit 0 }

$homeDir = $HOME
if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = $env:USERPROFILE }
$dir = $env:STATUSLINE_CACHE_DIR
if ([string]::IsNullOrWhiteSpace($dir)) {
    $dir = Join-Path $homeDir '.claude\statusline-cache'
}

try {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
} catch { exit 0 }

# The timestamp doubles as the roll seed, so a finished turn keeps the same
# face across every redraw instead of re-rolling on each refresh.
$now = 0
try { $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } catch { }

try {
    [System.IO.File]::WriteAllText((Join-Path $dir "mascot-$($key).txt"), "$State $now")
} catch { }

exit 0
