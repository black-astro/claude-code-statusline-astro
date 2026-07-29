# claude-code-statusline — Windows PowerShell implementation (5.1 and PowerShell 7+).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% | 7D [bar] NN%
#
# Set NO_COLOR=1 to strip the ANSI colors.

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---- appearance ------------------------------------------------------------
$BarLength = 10
# Built from code points so the file survives being saved in any encoding.
# U+2589 fills the left 7/8 of its cell, so cells sit flush against each other
# and the leftover 1/8 reads as a hairline gap — full cell height, no padding
# needed. A true square like U+25A0 is limited by the cell width instead, which
# is why it looks small.
$BarFull = [string][char]0x2589   # ▉ filled cell
$BarEmpty = [string][char]0x2591  # ░ empty cell
$BarGap = ''                      # cells are flush; the glyph separates itself
$BarPad = ' '                     # spacing just inside the brackets
$DirMax = 32                      # project name is left-truncated past this
$Ellipsis = [string][char]0x2026

$ShowSevenDay = $false  # set to $true to also show the 7-day (weekly) meter

# Meters turn amber at WarnAt and red at CritAt.
$WarnAt = 60
$CritAt = 90

$Esc = [char]27
if ([string]::IsNullOrEmpty($env:NO_COLOR)) {
    $Reset = "$($Esc)[0m"
    $Dim = "$($Esc)[90m"
    $CDir = "$($Esc)[97m"             # bright white — project name
    $CGitMain = "$($Esc)[95m"         # magenta — main / master
    $CGitOther = "$($Esc)[96m"        # sky blue — every other branch
    $CModel = "$($Esc)[93m"           # yellow — model name
    # 256-color meter palette. For 16-color-only terminals use
    # 96 / 93 / 91 in place of these three.
    $COk = "$($Esc)[38;5;117m"        # light blue — under WarnAt
    $CWarn = "$($Esc)[38;5;214m"      # amber      — WarnAt and up
    $CCrit = "$($Esc)[38;5;203m"      # red        — CritAt and up
} else {
    $Reset = ''; $Dim = ''; $CDir = ''; $CGitMain = ''; $CGitOther = ''
    $CModel = ''; $COk = ''; $CWarn = ''; $CCrit = ''
}

$Now = 0
try { $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } catch { $Now = 0 }

# Renders "[ ■ ■ ■ ■ □ □ □ □ □ □ ] 42%". Filled cells carry the load color,
# empty cells stay dim, and the width never changes so the line does not
# jitter as values appear.
#
# A rate-limit window whose ResetsAt has already passed means this session is
# holding an out-of-date snapshot, so the number is marked with "~" and dimmed.
function Get-Meter {
    param($Raw, $ResetsAt)

    $known = $true
    $value = 0.0
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) {
        $known = $false
    } elseif (-not [double]::TryParse(
            [string]$Raw,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)) {
        $known = $false
    }

    # Not named $reset: PowerShell variable names are case-insensitive, so it
    # would shadow the script-scope $Reset escape sequence.
    $stale = $false
    if ($Now -gt 0 -and $null -ne $ResetsAt) {
        $resetEpoch = 0.0
        if ([double]::TryParse(
                [string]$ResetsAt,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$resetEpoch)) {
            if ($resetEpoch -gt 0 -and $resetEpoch -lt $Now) { $stale = $true }
        }
    }

    if ($known) {
        if ($value -lt 0) { $value = 0 }
        if ($value -gt 100) { $value = 100 }
        $n = [int][Math]::Floor($value + 0.5)

        $filled = [int][Math]::Floor(($n + 5) / 10)
        if ($filled -gt $BarLength) { $filled = $BarLength }
        if ($filled -lt 0) { $filled = 0 }

        if ($n -ge $CritAt) { $c = $CCrit }
        elseif ($n -ge $WarnAt) { $c = $CWarn }
        else { $c = $COk }

        if ($stale) {
            $cPct = $Dim
            $pct = "~$n%"
        } else {
            $cPct = $c
            $pct = "$n%"
        }
    } else {
        $filled = 0
        $c = $Dim
        $cPct = $Dim
        $pct = '--%'
    }

    $cells = @()
    for ($i = 0; $i -lt $BarLength; $i++) {
        if ($i -lt $filled) { $cells += "$($c)$($BarFull)" }
        else { $cells += "$($Dim)$($BarEmpty)" }
    }
    $bar = $cells -join $BarGap

    return "$($Dim)[$($BarPad)$($bar)$($Dim)$($BarPad)] $($cPct)$($pct)$($Reset)"
}

# Last path segment, left-truncated so long names lose their head, not their tail.
function Get-LeafName {
    param([string]$Path, [int]$Max)

    $trimmed = $Path -replace '[\\/]+$', ''
    if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = $Path }
    $name = ($trimmed -split '[\\/]') | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $trimmed }

    if ($name.Length -gt $Max) {
        $name = $Ellipsis + $name.Substring($name.Length - $Max + 1)
    }
    return $name
}

try {
    $raw = $null
    try { $raw = [Console]::In.ReadToEnd() } catch { $raw = $null }

    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
    }

    $dir = $null
    try { $dir = $data.workspace.current_dir } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        try { $dir = $data.cwd } catch { }
    }

    $model = $null
    try { $model = $data.model.display_name } catch { }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = '-' }

    $branch = ''
    $root = ''
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and $hasGit -and (Test-Path -LiteralPath $dir)) {
        try {
            $top = & git -C "$dir" rev-parse --show-toplevel 2>$null
            if (-not [string]::IsNullOrWhiteSpace($top)) {
                $root = ([string]($top | Select-Object -First 1)).Trim()
            }

            $b = & git -C "$dir" branch --show-current 2>$null
            if ([string]::IsNullOrWhiteSpace($b)) {
                $b = & git -C "$dir" rev-parse --abbrev-ref HEAD 2>$null
                if ("$b".Trim() -eq 'HEAD') {
                    $b = & git -C "$dir" rev-parse --short HEAD 2>$null
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($b)) {
                $branch = ([string]($b | Select-Object -First 1)).Trim()
            }
        } catch { }
    }

    # Only the project root is shown. The full path is noise once you know
    # where you are, and the repository root is what identifies the session.
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $dir }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $project = '-'
    } else {
        $project = Get-LeafName -Path $root -Max $DirMax
    }

    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = '-'
        $cBranch = $Dim
    } elseif ($branch -eq 'main' -or $branch -eq 'master') {
        $cBranch = $CGitMain
    } else {
        $cBranch = $CGitOther
    }

    $ctx = $null
    try { $ctx = $data.context_window.used_percentage } catch { }
    $five = $null
    $fiveReset = $null
    try { $five = $data.rate_limits.five_hour.used_percentage } catch { }
    try { $fiveReset = $data.rate_limits.five_hour.resets_at } catch { }
    $seven = $null
    $sevenReset = $null
    try { $seven = $data.rate_limits.seven_day.used_percentage } catch { }
    try { $sevenReset = $data.rate_limits.seven_day.resets_at } catch { }

    $sep = "$($Dim) | $($Reset)"
    $line = "$($Dim)DIR$($Reset) $($CDir)$($project)$($Reset)"
    $line += "$($sep)$($Dim)GIT$($Reset) $($cBranch)$($branch)$($Reset)"
    $line += "$($sep)$($Dim)MODEL$($Reset) $($CModel)$($model)$($Reset)"
    $line += "$($sep)$($Dim)CTX$($Reset) $(Get-Meter $ctx $null)"
    $line += "$($sep)$($Dim)5H$($Reset) $(Get-Meter $five $fiveReset)"
    if ($ShowSevenDay) {
        $line += "$($sep)$($Dim)7D$($Reset) $(Get-Meter $seven $sevenReset)"
    }

    Write-Output $line
} catch {
    Write-Output 'DIR - | GIT - | MODEL - | CTX --% | 5H --% | 7D --%'
}
