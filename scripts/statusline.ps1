# claude-code-statusline — Windows PowerShell implementation (5.1 and PowerShell 7+).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% 4h10m
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   -Version   print the version and exit
#   -Today     print today's mascot draw and exit
#   -Help      print a short usage summary and exit
param(
    [switch]$Version,
    [switch]$Today,
    [switch]$Help
)

$StatuslineVersion = '1.3.0'

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---- appearance ------------------------------------------------------------
$BarLength = 10
# U+25FC/25FB draw a near-square block with the glyph's own margins, so flush
# cells still show a hairline gap, and the empty cell renders as an outlined
# box rather than a shaded fill. Glyphs are built from code points so the file
# survives being saved in any encoding.
$BarFull = [string][char]0x25FC   # ◼ filled cell
$BarEmpty = [string][char]0x25FB  # ◻ empty cell (outlined)
$BarGap = ''                      # cells are flush; the glyph separates itself
$BarPad = ''                      # spacing just inside the brackets
$DirMax = 32                      # project name is left-truncated past this
$Ellipsis = [string][char]0x2026

$ShowSevenDay = $false  # set to $true to also show the 7-day (weekly) meter

# Mascot: a kaomoji at the end of the line that reflects what the session is
# doing. It needs the companion hooks (mascot-hook.ps1) to know the state -
# without them the state file never appears and the mascot stays hidden.
$ShowMascot = $true
# The mascot speaks a line when a turn finishes; set $false for the face alone.
$ShowMascotTalk = $true
# Seconds per animation step. Claude Code only redraws every refreshInterval,
# so anything below that value changes nothing - keep the two in step.
$AnimSecs = 3
# Rarity odds in per-mille, highest first. They must total 1000.
$MascotOdds = @{ common = 400; uncommon = 350; rare = 180; unique = 60; legend = 10 }

# Maintainer tier. A key whose SHA-256 is listed here also rolls 'dev' faces;
# every other key never sees them. Only the hash is published, so the list gives
# nothing away - matching it would mean finding a preimage of SHA-256. Add your
# own hash to claim the tier on your machine: SHA-256 of the key file's text,
# trimmed of whitespace, hashed as UTF-8. The README gives the exact command.
$DevKeyHashes = @(
    '837cbfd9a3f7b0c8887e1654f8bed41800fd80a4cd4a969a14b1a5095d6fa31a'
)
# Per-mille odds of the dev tier; the ordinary tiers share what is left, keeping
# their ratio to each other.
$DevOdds = 100

# Meters turn amber at WarnAt and red at CritAt.
$WarnAt = 60
$CritAt = 90

# Rate-limit snapshots are shared between sessions through this directory so
# every terminal shows the freshest value any of them has seen.
$homeDir = $HOME
if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = $env:USERPROFILE }
$CacheDir = $env:STATUSLINE_CACHE_DIR
if ([string]::IsNullOrWhiteSpace($CacheDir)) {
    $CacheDir = Join-Path $homeDir '.claude\statusline-cache'
}

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
    $COk = "$($Esc)[38;5;46m"         # neon green — under WarnAt
    $CWarn = "$($Esc)[38;5;214m"      # amber      — WarnAt and up
    $CCrit = "$($Esc)[38;5;203m"      # red        — CritAt and up
    # Mascot rarity palette, common -> legend.
    $CCommon = "$($Esc)[38;5;255m"    # white
    $CUncommon = "$($Esc)[38;5;82m"   # green
    $CRare = "$($Esc)[38;5;117m"      # sky blue
    $CUnique = "$($Esc)[38;5;141m"    # purple
    $CLegend = "$($Esc)[1;38;5;208m"  # orange, bold
    $CDev = "$($Esc)[1;38;5;51m"      # cyan, bold - maintainer only
} else {
    $Reset = ''; $Dim = ''; $CDir = ''; $CGitMain = ''; $CGitOther = ''
    $CModel = ''; $COk = ''; $CWarn = ''; $CCrit = ''
    $CCommon = ''; $CUncommon = ''; $CRare = ''; $CUnique = ''; $CLegend = ''
    $CDev = ''
}

$Now = 0
try { $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } catch { $Now = 0 }

# Rounds a raw percentage to a clamped [0,100] integer; $null when unparseable.
function Get-Pct {
    param($Raw)
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) { return $null }
    $value = 0.0
    if (-not [double]::TryParse(
            [string]$Raw,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)) { return $null }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }
    return [int][Math]::Floor($value + 0.5)
}

# Parses an epoch-seconds value; $null when unparseable.
function Get-Epoch {
    param($Raw)
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) { return $null }
    $value = 0.0
    if (-not [double]::TryParse(
            [string]$Raw,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)) { return $null }
    if ($value -le 0) { return $null }
    return [long][Math]::Floor($value)
}

function Format-Remaining {
    param([long]$Rem)
    if ($Rem -ge 3600) {
        return ('{0}h{1:d2}m' -f [int][Math]::Floor($Rem / 3600), [int][Math]::Floor(($Rem % 3600) / 60))
    }
    if ($Rem -ge 60) { return ('{0}m' -f [int][Math]::Floor($Rem / 60)) }
    return '<1m'
}

# Renders "[◼◼◼◼◻◻◻◻◻◻] 42% 4h10m". The whole meter — brackets, filled cells
# and the outlines of empty cells — carries the load color, and the bar width
# never changes so the line does not jitter.
# The countdown is the time until the window resets, computed locally from
# resets_at — it costs nothing and is the one part that is always current.
#
# A snapshot whose resets_at has already passed is from a window that is over,
# so the number is marked with "~" and dimmed instead of given a countdown.
function Get-Meter {
    param($Pct, $ResetEpoch)

    $stale = $false
    $countdown = ''
    if ($Now -gt 0 -and $null -ne $ResetEpoch -and $ResetEpoch -gt 0) {
        if ($ResetEpoch -lt $Now) { $stale = $true }
        else { $countdown = Format-Remaining ($ResetEpoch - $Now) }
    }

    if ($null -ne $Pct) {
        $n = [int]$Pct
        $filled = [int][Math]::Floor(($n + 5) / 10)
        if ($filled -gt $BarLength) { $filled = $BarLength }
        if ($filled -lt 0) { $filled = 0 }

        if ($n -ge $CritAt) { $c = $CCrit }
        elseif ($n -ge $WarnAt) { $c = $CWarn }
        else { $c = $COk }

        if ($stale) {
            $cPct = $Dim
            $pct = "~$n%"
            $countdown = ''
        } else {
            $cPct = $c
            $pct = "$n%"
        }
    } else {
        $filled = 0
        $c = $Dim
        $cPct = $Dim
        $pct = '--%'
        $countdown = ''
    }

    $cells = @()
    for ($i = 0; $i -lt $BarLength; $i++) {
        if ($i -lt $filled) { $cells += "$($c)$($BarFull)" }
        else { $cells += "$($c)$($BarEmpty)" }
    }
    $bar = $cells -join $BarGap

    $out = "$($c)[$($BarPad)$($bar)$($c)$($BarPad)] $($cPct)$($pct)$($Reset)"
    if ($countdown -ne '') { $out += " $($Dim)$($countdown)$($Reset)" }
    return $out
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

# ---- mascot ---------------------------------------------------------------
# The face is the day's draw, derived from HMAC-SHA256(machine key, date) and
# never stored, so it is fixed for the whole day and identical on every redraw.
# The key is created once by mascot-hook.ps1.
#
# Each face carries frames of one expression, all the same width so the line
# never jitters. The frames advance while a turn runs and settle on the first
# one when it ends. Legend and dev also cycle their color on every refresh.
#
# Faces are code points, like the bar cells. The spoken lines are literals -
# Hangul written as code points would be unreadable - so this file carries a
# UTF-8 BOM to pin its encoding down.

$KaoError = @(
    @(0xFF08, 0xFF1B, 0x3078, 0xFF1A, 0xFF09),
    @(0xFF08, 0xFF1B, 0x03C9, 0xFF1B, 0xFF09)
)

$MascotTiers = @('common', 'uncommon', 'rare', 'unique', 'legend')

# Legend and dev cycle through these instead of taking one fixed color.
$RainbowColors = @(196, 202, 208, 214, 220, 190, 118, 46, 48, 51, 45, 39, 63, 99, 129, 201)

# Rarity -> faces -> frames.
$KaoTable = @{
    common = @(
        @(  # （・ω・）
            @(0xFF08, 0x30FB, 0x03C9, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x03C9, 0xFF0D, 0xFF09)
        ),
        @(  # （´･ω･）
            @(0xFF08, 0x00B4, 0xFF65, 0x03C9, 0xFF65, 0xFF09),
            @(0xFF08, 0x00B4, 0xFF0D, 0x03C9, 0xFF0D, 0xFF09)
        ),
        @(  # （・_・）
            @(0xFF08, 0x30FB, 0x005F, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x005F, 0xFF0D, 0xFF09)
        ),
        @(  # （ ˘ω˘ ）
            @(0xFF08, 0x0020, 0x02D8, 0x03C9, 0x02D8, 0x0020, 0xFF09),
            @(0xFF08, 0x0020, 0x02D8, 0x1D17, 0x02D8, 0x0020, 0xFF09)
        ),
        @(  # （=・ω・=）
            @(0xFF08, 0x003D, 0x30FB, 0x03C9, 0x30FB, 0x003D, 0xFF09),
            @(0xFF08, 0x003D, 0xFF0D, 0x03C9, 0xFF0D, 0x003D, 0xFF09)
        ),
        @(  # （・∀・）
            @(0xFF08, 0x30FB, 0x2200, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x2200, 0xFF0D, 0xFF09)
        ),
        @(  # （＞ω＜）
            @(0xFF08, 0xFF1E, 0x03C9, 0xFF1C, 0xFF09),
            @(0xFF08, 0xFF1E, 0x1D17, 0xFF1C, 0xFF09)
        ),
        @(  # （・ｖ・）
            @(0xFF08, 0x30FB, 0xFF56, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0xFF56, 0xFF0D, 0xFF09)
        ),
        @(  # （^_^）
            @(0xFF08, 0x005E, 0x005F, 0x005E, 0xFF09),
            @(0xFF08, 0x005E, 0x03C9, 0x005E, 0xFF09)
        ),
        @(  # （・◡・）
            @(0xFF08, 0x30FB, 0x25E1, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x25E1, 0xFF0D, 0xFF09)
        ),
        @(  # （・ツ・）
            @(0xFF08, 0x30FB, 0x30C4, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x30C4, 0xFF0D, 0xFF09)
        ),
        @(  # （¬ω¬）
            @(0xFF08, 0x00AC, 0x03C9, 0x00AC, 0xFF09),
            @(0xFF08, 0x00AC, 0x005F, 0x00AC, 0xFF09)
        )
    )
    uncommon = @(
        @(  # （๑˃ᴗ˂）
            @(0xFF08, 0x0E51, 0x02C3, 0x1D17, 0x02C2, 0xFF09),
            @(0xFF08, 0x0E51, 0x02C2, 0x1D17, 0x02C3, 0xFF09)
        ),
        @(  # （｡･ω･｡）
            @(0xFF08, 0xFF61, 0xFF65, 0x03C9, 0xFF65, 0xFF61, 0xFF09),
            @(0xFF08, 0xFF61, 0xFF0D, 0x03C9, 0xFF0D, 0xFF61, 0xFF09)
        ),
        @(  # （^▽^）
            @(0xFF08, 0x005E, 0x25BD, 0x005E, 0xFF09),
            @(0xFF08, 0x005E, 0x1D17, 0x005E, 0xFF09)
        ),
        @(  # （・ㅂ・）
            @(0xFF08, 0x30FB, 0x3142, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x3142, 0xFF0D, 0xFF09)
        ),
        @(  # （◕‿◕）
            @(0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09),
            @(0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09)
        ),
        @(  # （๑•ᴗ•๑）
            @(0xFF08, 0x0E51, 0x2022, 0x1D17, 0x2022, 0x0E51, 0xFF09),
            @(0xFF08, 0x0E51, 0x002D, 0x1D17, 0x002D, 0x0E51, 0xFF09)
        ),
        @(  # （≧ω≦）
            @(0xFF08, 0x2267, 0x03C9, 0x2266, 0xFF09),
            @(0xFF08, 0x2267, 0x1D17, 0x2266, 0xFF09)
        ),
        @(  # （･ω<）
            @(0xFF08, 0xFF65, 0x03C9, 0x003C, 0xFF09),
            @(0xFF08, 0xFF65, 0x1D17, 0x003C, 0xFF09)
        ),
        @(  # （。◕‿◕。）
            @(0xFF08, 0x3002, 0x25D5, 0x203F, 0x25D5, 0x3002, 0xFF09),
            @(0xFF08, 0x3002, 0x25E0, 0x203F, 0x25E0, 0x3002, 0xFF09)
        ),
        @(  # （＾▽＾）
            @(0xFF08, 0xFF3E, 0x25BD, 0xFF3E, 0xFF09),
            @(0xFF08, 0xFF3E, 0x1D17, 0xFF3E, 0xFF09)
        ),
        @(  # （･◡･）
            @(0xFF08, 0xFF65, 0x25E1, 0xFF65, 0xFF09),
            @(0xFF08, 0xFF65, 0x1D17, 0xFF65, 0xFF09)
        ),
        @(  # （≖‿≖）
            @(0xFF08, 0x2256, 0x203F, 0x2256, 0xFF09),
            @(0xFF08, 0x2256, 0x005F, 0x2256, 0xFF09)
        )
    )
    rare = @(
        @(  # （๑˃ᴗ˂）✧
            @(0xFF08, 0x0E51, 0x02C3, 0x1D17, 0x02C2, 0xFF09, 0x2727),
            @(0xFF08, 0x0E51, 0x02C3, 0x1D17, 0x02C2, 0xFF09, 0x2726)
        ),
        @(  # ヽ（•‿•）ノ
            @(0x30FD, 0xFF08, 0x2022, 0x203F, 0x2022, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x2022, 0x203F, 0x2022, 0xFF09, 0xFF89)
        ),
        @(  # （★ω★）
            @(0xFF08, 0x2605, 0x03C9, 0x2605, 0xFF09),
            @(0xFF08, 0x2606, 0x03C9, 0x2606, 0xFF09)
        ),
        @(  # （◕‿◕）✧
            @(0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09, 0x2727),
            @(0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09, 0x2726)
        ),
        @(  # \（^o^）/
            @(0x005C, 0xFF08, 0x005E, 0x006F, 0x005E, 0xFF09, 0x002F),
            @(0x005C, 0xFF08, 0x005E, 0x004F, 0x005E, 0xFF09, 0x002F)
        ),
        @(  # （✧ω✧）
            @(0xFF08, 0x2727, 0x03C9, 0x2727, 0xFF09),
            @(0xFF08, 0x2726, 0x03C9, 0x2726, 0xFF09)
        ),
        @(  # ヽ（◕‿◕）ノ
            @(0x30FD, 0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09, 0xFF89)
        ),
        @(  # （๑✧‿✧๑）
            @(0xFF08, 0x0E51, 0x2727, 0x203F, 0x2727, 0x0E51, 0xFF09),
            @(0xFF08, 0x0E51, 0x2726, 0x203F, 0x2726, 0x0E51, 0xFF09)
        ),
        @(  # （★‿★）
            @(0xFF08, 0x2605, 0x203F, 0x2605, 0xFF09),
            @(0xFF08, 0x2606, 0x203F, 0x2606, 0xFF09)
        ),
        @(  # （≧∇≦）✧
            @(0xFF08, 0x2267, 0x2207, 0x2266, 0xFF09, 0x2727),
            @(0xFF08, 0x2267, 0x25BD, 0x2266, 0xFF09, 0x2726)
        ),
        @(  # ヽ（^ω^）ノ
            @(0x30FD, 0xFF08, 0x005E, 0x03C9, 0x005E, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x005E, 0x1D17, 0x005E, 0xFF09, 0xFF89)
        ),
        @(  # （･∀･）✧
            @(0xFF08, 0xFF65, 0x2200, 0xFF65, 0xFF09, 0x2727),
            @(0xFF08, 0xFF65, 0x2200, 0xFF65, 0xFF09, 0x2726)
        )
    )
    unique = @(
        @(  # （☆▽☆）
            @(0xFF08, 0x2606, 0x25BD, 0x2606, 0xFF09),
            @(0xFF08, 0x2605, 0x25BD, 0x2605, 0xFF09)
        ),
        @(  # ヽ（°〇°）ﾉ
            @(0x30FD, 0xFF08, 0x00B0, 0x3007, 0x00B0, 0xFF09, 0xFF89),
            @(0x30FE, 0xFF08, 0x00B0, 0x0414, 0x00B0, 0xFF09, 0xFF89)
        ),
        @(  # （ﾉ◕ヮ◕）ﾉ
            @(0xFF08, 0xFF89, 0x25D5, 0x30EE, 0x25D5, 0xFF09, 0xFF89),
            @(0xFF08, 0x30FD, 0x25D5, 0x30EE, 0x25D5, 0xFF09, 0x30FD)
        ),
        @(  # （♡‿♡）
            @(0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09),
            @(0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09)
        ),
        @(  # （ﾉ☆▽☆）ﾉ
            @(0xFF08, 0xFF89, 0x2606, 0x25BD, 0x2606, 0xFF09, 0xFF89),
            @(0xFF08, 0x30FD, 0x2605, 0x25BD, 0x2605, 0xFF09, 0x30FD)
        ),
        @(  # （๑♡‿♡๑）
            @(0xFF08, 0x0E51, 0x2661, 0x203F, 0x2661, 0x0E51, 0xFF09),
            @(0xFF08, 0x0E51, 0x2665, 0x203F, 0x2665, 0x0E51, 0xFF09)
        ),
        @(  # ヽ（✧∇✧）ノ
            @(0x30FD, 0xFF08, 0x2727, 0x2207, 0x2727, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x2726, 0x25BD, 0x2726, 0xFF09, 0xFF89)
        ),
        @(  # （＠◕ᴗ◕＠）
            @(0xFF08, 0xFF20, 0x25D5, 0x1D17, 0x25D5, 0xFF20, 0xFF09),
            @(0xFF08, 0xFF20, 0x25E0, 0x1D17, 0x25E0, 0xFF20, 0xFF09)
        ),
        @(  # （ﾉ≧ڡ≦）ﾉ
            @(0xFF08, 0xFF89, 0x2267, 0x06A1, 0x2266, 0xFF09, 0xFF89),
            @(0xFF08, 0x30FD, 0x2267, 0x06A1, 0x2266, 0xFF09, 0x30FD)
        )
    )
    legend = @(
        @(  # ✧（◕ᴗ◕）✧
            @(0x2727, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2727),
            @(0x2726, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2726),
            @(0x2727, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2726),
            @(0x2726, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2727)
        ),
        @(  # ヽ（♡‿♡）ノ
            @(0x30FD, 0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09, 0xFF89),
            @(0x30FD, 0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09, 0xFF89)
        ),
        @(  # （ﾉ≧∇≦）ﾉ
            @(0xFF08, 0xFF89, 0x2267, 0x2207, 0x2266, 0xFF09, 0xFF89),
            @(0xFF08, 0xFF89, 0x2267, 0x25BD, 0x2266, 0xFF09, 0xFF89),
            @(0xFF08, 0x30FD, 0x2267, 0x2207, 0x2266, 0xFF09, 0x30FD),
            @(0xFF08, 0x30FD, 0x2267, 0x25BD, 0x2266, 0xFF09, 0x30FD)
        ),
        @(  # ♪（๑ᴖ◡ᴖ๑）♪
            @(0x266A, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0x266A),
            @(0x266B, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0x266B),
            @(0x2669, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0x2669),
            @(0x266C, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0x266C)
        ),
        @(  # （✧ᴗ✧）
            @(0xFF08, 0x2727, 0x1D17, 0x2727, 0xFF09),
            @(0xFF08, 0x2726, 0x1D17, 0x2726, 0xFF09),
            @(0xFF08, 0x2605, 0x1D17, 0x2605, 0xFF09),
            @(0xFF08, 0x2606, 0x1D17, 0x2606, 0xFF09)
        )
    )
    dev = @(
        @(  # （¬‿¬）
            @(0xFF08, 0x00AC, 0x203F, 0x00AC, 0xFF09),
            @(0xFF08, 0x00AC, 0x005F, 0x00AC, 0xFF09)
        ),
        @(  # （☞ﾟヮﾟ）☞
            @(0xFF08, 0x261E, 0xFF9F, 0x30EE, 0xFF9F, 0xFF09, 0x261E),
            @(0xFF08, 0x261C, 0xFF9F, 0x30EE, 0xFF9F, 0xFF09, 0x261C)
        ),
        @(  # （◣_◢）
            @(0xFF08, 0x25E3, 0x005F, 0x25E2, 0xFF09),
            @(0xFF08, 0x25E2, 0x005F, 0x25E3, 0xFF09)
        ),
        @(  # ᕙ（⇀‸↼）ᕗ
            @(0x1559, 0xFF08, 0x21C0, 0x2038, 0x21BC, 0xFF09, 0x1557),
            @(0x1566, 0xFF08, 0x21C0, 0x2038, 0x21BC, 0xFF09, 0x1564)
        )
    )
}

# What the mascot says once a turn is done. The higher the rarity, the more
# of an actual sentence it manages.
$TalkTable = @{
    common = @('왕!', '냥!', '뿌!', '삐약!', '꽥!', '음냐')
    uncommon = @('왕왕!', '다했다!', '끝!', '됐다!', '오케이!', '히히')
    rare = @('다 됐어요', '끝났어요', '완료했어요', '해냈어요!', '준비 끝!')
    unique = @('작업 완료했어요!', '다 끝냈습니다!', '깔끔하게 끝냈어요!', '확인해 보세요!')
    legend = @('요청하신 작업 모두 완료했습니다!', '전부 끝냈습니다, 확인 부탁드려요!', '작업을 성공적으로 마쳤습니다!')
    dev = @('빌드 통과.', '커밋하시죠.', '배포 준비 완료.', '테스트 전부 초록불.')
}
$TalkError = @('앗...', '실패했어요...')

# Builds one frame from its code points. Every glyph is inside the BMP, so a
# plain [char] cast is both correct and cheap enough to run every refresh.
function New-Kao {
    param([int[]]$Cp)
    $text = ''
    foreach ($c in $Cp) { $text += [char]$c }
    return $text
}

# The per-machine key the draw is derived from. Read-only here; mascot-hook.ps1
# creates it once with a CSPRNG. No key means no mascot, which is also what a
# fresh install looks like before the first turn ends.
function Get-GachaKey {
    $file = Join-Path $CacheDir '.gacha-key'
    try { return [System.IO.File]::ReadAllText($file).Trim() } catch { return '' }
}

# Whether this machine's key is one of the maintainer keys. Comparing hashes
# rather than keys is what lets the list ship in the open.
function Test-DevKey {
    param([string]$Key)

    if ($Key -eq '' -or $DevKeyHashes.Count -eq 0) { return $false }
    $sha = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key))
        $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    } catch {
        return $false
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
    foreach ($h in $DevKeyHashes) {
        if ($hex -eq ([string]$h).Trim().ToLower()) { return $true }
    }
    return $false
}

# Today's draw: @{ Tier; Index } or $null when there is no key. Two independent
# 32-bit windows of one HMAC pick the tier and the face.
function Get-GachaDraw {
    $key = Get-GachaKey
    if ($key -eq '') { return $null }

    $today = ''
    try { $today = (Get-Date).ToString('yyyyMMdd') } catch { return $null }

    $bytes = $null
    $hmac = $null
    try {
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = [Text.Encoding]::UTF8.GetBytes($key)
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("gacha|v1|$today"))
    } catch {
        return $null
    } finally {
        if ($null -ne $hmac) { $hmac.Dispose() }
    }
    if ($null -eq $bytes -or $bytes.Length -lt 8) { return $null }

    $n1 = ([long]$bytes[0] * 16777216) + ([long]$bytes[1] * 65536) + ([long]$bytes[2] * 256) + [long]$bytes[3]
    $n2 = ([long]$bytes[4] * 16777216) + ([long]$bytes[5] * 65536) + ([long]$bytes[6] * 256) + [long]$bytes[7]

    # A maintainer key adds the dev tier in front; the ordinary tiers then share
    # what is left of the 1000, keeping their ratio to each other. Whatever the
    # rounding leaves over goes to dev, so the odds still total exactly 1000.
    $tiers = $MascotTiers
    $odds = $MascotOdds
    if (Test-DevKey $key) {
        $scaled = @{}
        $used = 0
        foreach ($t in $MascotTiers) {
            $v = [int][Math]::Floor([double]$MascotOdds[$t] * (1000 - $DevOdds) / 1000)
            $scaled[$t] = $v
            $used += $v
        }
        $scaled['dev'] = 1000 - $used
        $tiers = @('dev') + $MascotTiers
        $odds = $scaled
    }

    $roll = [int]($n1 % 1000)
    $tier = $tiers[0]
    $acc = 0
    foreach ($t in $tiers) {
        $acc += [int]$odds[$t]
        if ($roll -lt $acc) { $tier = $t; break }
    }

    $pool = $KaoTable[$tier]
    $idx = 0
    if ($pool.Count -gt 0) { $idx = [int]($n2 % $pool.Count) }
    return @{ Tier = $tier; Index = $idx }
}

# Flat tier color. Legend and dev do not use this - they get a gradient.
function Get-TierColor {
    param([string]$Tier)

    switch ($Tier) {
        'legend'   { return $CLegend }
        'dev'      { return $CDev }
        'unique'   { return $CUnique }
        'rare'     { return $CRare }
        'uncommon' { return $CUncommon }
        default    { return $CCommon }
    }
}

# Paints every character its own color along the rainbow and shifts the whole
# ramp one step per refresh, so the colors appear to flow across the text. This
# is what makes legend and dev shimmer instead of just sitting there.
function Get-GradientText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Reset)) { return $Text }
    $n = $RainbowColors.Count
    if ($n -le 0 -or $Text.Length -eq 0) { return $Text }

    $step = 0
    if ($Now -gt 0) { $step = [int](($Now / $AnimSecs) % $n) }

    $out = ''
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $idx = ($step + $i) % $n
        $out += "$($Esc)[1;38;5;$($RainbowColors[$idx])m$($Text[$i])"
    }
    return $out
}

# Wraps text in the right paint for its tier: the flowing gradient is reserved
# for legend; every other tier takes one flat color.
function Write-TierText {
    param([string]$Tier, [string]$Text)

    if ($Tier -eq 'legend') { return "$(Get-GradientText $Text)$($Reset)" }
    return "$(Get-TierColor $Tier)$($Text)$($Reset)"
}

# Picks the spoken line for a finished turn. Seeded with the timestamp the hook
# recorded, so the line is stable across redraws but changes with the next turn.
function Get-Talk {
    param([string]$Tier, [long]$Stamp)

    if (-not $ShowMascotTalk) { return '' }
    $pool = $TalkTable[$Tier]
    if ($null -eq $pool -or $pool.Count -eq 0) { return '' }
    $h = ($Stamp * 1103515245 + 12345) % 2147483648
    if ($h -lt 0) { $h = -$h }
    return $pool[[int]($h % $pool.Count)]
}

# Reads the turn state the hooks left for this session and draws the face.
# Returns '' when the hooks are not installed, so the line then looks exactly
# as it did before the mascot existed.
function Get-Mascot {
    param([string]$SidKey)

    if ([string]::IsNullOrWhiteSpace($SidKey)) { return '' }
    $file = Join-Path $CacheDir "mascot-$($SidKey).txt"
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($file).Trim() } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }

    $tok = $raw -split '\s+'
    $state = $tok[0]
    $working = ($state -eq 'working')
    $stamp = 0
    if ($tok.Count -ge 2) {
        $parsed = Get-Epoch $tok[1]
        if ($null -ne $parsed) { $stamp = $parsed }
    }

    if ($state -eq 'error') {
        $frame = 0
        if ($Now -gt 0) { $frame = [int](($Now / $AnimSecs) % $KaoError.Count) }
        $out = "$($CCrit)$(New-Kao $KaoError[$frame])"
        if ($ShowMascotTalk -and $TalkError.Count -gt 0) {
            $h = ($stamp * 1103515245 + 12345) % 2147483648
            if ($h -lt 0) { $h = -$h }
            $out += " $($TalkError[[int]($h % $TalkError.Count)])"
        }
        return "$($out)$($Reset)"
    }
    if (-not $working -and $state -ne 'done') { return '' }

    $draw = Get-GachaDraw
    if ($null -eq $draw) { return '' }

    $face = $KaoTable[$draw.Tier][$draw.Index]
    $frame = 0
    if ($working -and $Now -gt 0 -and $face.Count -gt 0) {
        $frame = [int](($Now / $AnimSecs) % $face.Count)
    }

    $text = New-Kao $face[$frame]
    # The mascot only speaks once the turn is over; mid-turn it just animates.
    if (-not $working) {
        $talk = Get-Talk $draw.Tier $stamp
        if ($talk -ne '') { $text += " $($talk)" }
    }
    return (Write-TierText $draw.Tier $text)
}
# ---- subcommands -----------------------------------------------------------
# None of these read stdin, so they work from a plain prompt.

if ($Help) {
    Write-Output "claude-code-statusline-astro $StatuslineVersion"
    Write-Output ''
    Write-Output '  statusline.ps1            Claude Code calls this with session JSON on stdin'
    Write-Output '  statusline.ps1 -Today     show the mascot drawn for today'
    Write-Output '  statusline.ps1 -Version   show the version'
    Write-Output '  statusline.ps1 -Help      this text'
    Write-Output ''
    Write-Output 'Settings live at the top of this file. Update by re-running install.ps1.'
    exit 0
}

if ($Version) {
    Write-Output "claude-code-statusline-astro $StatuslineVersion"
    exit 0
}

if ($Today) {
    $draw = Get-GachaDraw
    if ($null -eq $draw) {
        Write-Output '아직 뽑기 전입니다. 턴을 한 번 끝내면 오늘의 마스코트가 정해집니다.'
        exit 0
    }
    $face = $KaoTable[$draw.Tier][$draw.Index]
    $label = @{
        common = '커먼'; uncommon = '언커먼'; rare = '레어'
        unique = '유니크'; legend = '레전드'; dev = 'DEV'
    }[$draw.Tier]

    $frames = @()
    foreach ($f in $face) { $frames += (New-Kao $f) }

    Write-Output ("오늘의 마스코트  {0}  [{1}]" -f (Write-TierText $draw.Tier $frames[0]), $label)
    Write-Output ("표정 {0}장         {1}" -f $frames.Count, ($frames -join '  '))
    $pool = $TalkTable[$draw.Tier]
    if ($null -ne $pool -and $pool.Count -gt 0) {
        Write-Output ("대사              {0}" -f ($pool -join ' / '))
    }
    Write-Output ''
    Write-Output '얼굴은 날짜로 정해집니다. 내일 다시 뽑힙니다.'
    exit 0
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

    $ctxPct = $null
    try { $ctxPct = Get-Pct $data.context_window.used_percentage } catch { }

    $fiveU = $null; $fiveR = $null
    $sevenU = $null; $sevenR = $null
    try { $fiveU = Get-Pct $data.rate_limits.five_hour.used_percentage } catch { }
    try { $fiveR = Get-Epoch $data.rate_limits.five_hour.resets_at } catch { }
    try { $sevenU = Get-Pct $data.rate_limits.seven_day.used_percentage } catch { }
    try { $sevenR = Get-Epoch $data.rate_limits.seven_day.resets_at } catch { }

    $sessionId = $null
    try { $sessionId = $data.session_id } catch { }

    # ---- cross-session rate-limit sync -------------------------------------
    # The payload's rate_limits are a per-session snapshot frozen at that
    # session's last API response, so idle terminals drift apart and disagree
    # with the web usage page. Every session therefore publishes the snapshot
    # it was handed, and every session renders the best snapshot published by
    # anyone: the newest window wins, and within the same window the highest
    # reading wins, because account usage only rises while a window is open.
    #
    # Cache line format (one per session): "v1 <5h%> <5h_reset> <7d%> <7d_reset>"
    try {
        if (-not (Test-Path -LiteralPath $CacheDir)) {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        }
    } catch { }

    $sidKey = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$sessionId)) {
        $sidKey = ([string]$sessionId) -replace '[^a-zA-Z0-9]', ''
        if ($sidKey.Length -gt 8) { $sidKey = $sidKey.Substring(0, 8) }
    }

    if ($null -ne $fiveU -and $sidKey -ne '' -and (Test-Path -LiteralPath $CacheDir)) {
        try {
            $fr = '-'; if ($null -ne $fiveR) { $fr = [string]$fiveR }
            $su = '-'; if ($null -ne $sevenU) { $su = [string]$sevenU }
            $sr = '-'; if ($null -ne $sevenR) { $sr = [string]$sevenR }
            $line = "v1 $fiveU $fr $su $sr"
            [System.IO.File]::WriteAllText(
                (Join-Path $CacheDir "rl-$sidKey.txt"),
                $line + "`n",
                (New-Object System.Text.UTF8Encoding($false)))
        } catch { }

        # Entries from long-dead sessions stop mattering once their window
        # closes; sweep anything untouched for two days.
        try {
            $cutoff = (Get-Date).AddHours(-48)
            Get-ChildItem -LiteralPath $CacheDir -Include 'rl-*.txt', 'mascot-*.txt' -Recurse |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -Confirm:$false
        } catch { }
    }

    $best5U = $fiveU; $best5R = 0; if ($null -ne $fiveR) { $best5R = $fiveR }
    $best7U = $sevenU; $best7R = 0; if ($null -ne $sevenR) { $best7R = $sevenR }

    try {
        foreach ($f in (Get-ChildItem -LiteralPath $CacheDir -Filter 'rl-*.txt' -ErrorAction SilentlyContinue)) {
            $parts = ''
            try { $parts = [System.IO.File]::ReadAllText($f.FullName).Trim() } catch { continue }
            $tok = $parts -split '\s+'
            if ($tok.Count -lt 5 -or $tok[0] -ne 'v1') { continue }

            $u5 = Get-Pct $tok[1]
            $r5 = Get-Epoch $tok[2]
            if ($null -eq $r5) { $r5 = 0 }
            if ($null -ne $u5) {
                if ($null -eq $best5U -or $r5 -gt $best5R) { $best5U = $u5; $best5R = $r5 }
                elseif ($r5 -eq $best5R -and $u5 -gt $best5U) { $best5U = $u5 }
            }

            $u7 = Get-Pct $tok[3]
            $r7 = Get-Epoch $tok[4]
            if ($null -eq $r7) { $r7 = 0 }
            if ($null -ne $u7) {
                if ($null -eq $best7U -or $r7 -gt $best7R) { $best7U = $u7; $best7R = $r7 }
                elseif ($r7 -eq $best7R -and $u7 -gt $best7U) { $best7U = $u7 }
            }
        }
    } catch { }

    # ---- output ------------------------------------------------------------
    $sep = "$($Dim) | $($Reset)"
    $out = "$($Dim)DIR$($Reset) $($CDir)$($project)$($Reset)"
    $out += "$($sep)$($Dim)GIT$($Reset) $($cBranch)$($branch)$($Reset)"
    $out += "$($sep)$($Dim)MODEL$($Reset) $($CModel)$($model)$($Reset)"
    $out += "$($sep)$($Dim)CTX$($Reset) $(Get-Meter $ctxPct $null)"
    $out += "$($sep)$($Dim)5H$($Reset) $(Get-Meter $best5U $best5R)"
    if ($ShowSevenDay) {
        $out += "$($sep)$($Dim)7D$($Reset) $(Get-Meter $best7U $best7R)"
    }
    if ($ShowMascot) {
        $mascot = Get-Mascot $sidKey
        if ($mascot -ne '') { $out += " $($mascot)" }
    }

    Write-Output $out
} catch {
    Write-Output 'DIR - | GIT - | MODEL - | CTX --% | 5H --%'
}
