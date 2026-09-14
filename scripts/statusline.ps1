# claude-statusline — Windows PowerShell implementation (5.1 and PowerShell 7+).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% 4h10m
#
# Set NO_COLOR=1 to strip the ANSI colors.

# Run with no arguments (the way Claude Code calls it) to print the status line.
#   -Roll      roll today's mascot (once a day) and exit
#   -Roll -Tier <name>   maintainer only: set the tier outright
#   -Today     print the mascot you are currently wearing and exit
#   -Version   print the version and exit
#   -Help      print a short usage summary and exit
param(
    [switch]$Roll,
    [switch]$Today,
    [switch]$Version,
    [switch]$Help,
    [string]$Tier = ''
)

$StatuslineVersion = '1.5.0'

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
# 레전드 색 띠를 한 번에 몇 칸 밀지. 스크립트가 다시 불리는 주기는
# refreshInterval 이 정하므로, 색만 빠르게 흐르게 하려면 이 값을 올린다.
$GradientShift = 4
# How long after a turn ends the mascot keeps talking. Past this it goes quiet
# until the next turn, so an idle terminal is not left with a stale sentence.
$TalkWindowSecs = 60
# Rarity odds in per-mille, highest first, totalling 1000. These are fixed on
# purpose: everyone rolls against the same table, and editing them turns the roll
# into a choice, which is no roll at all.
$MascotOdds = @{ common = 400; uncommon = 350; rare = 180; unique = 60; legend = 10 }

# Maintainer tier. A key whose SHA-256 is listed here also rolls 'dev' faces;
# every other key never sees them. Only the hash is published, so the list gives
# nothing away - matching it would mean finding a preimage of SHA-256. Add your
# own hash to claim the tier on your machine: SHA-256 of the key file's text,
# trimmed of whitespace, hashed as UTF-8. The README gives the exact command.
$DevKeyHashes = @(
    '64528c9f19e91ed0ca521f443a672235456aa3cdf23f45787f07482759777238'
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
# The face is whatever the last roll produced. Rolls happen once a day and
# only when asked for (statusline.ps1 -Roll); nothing here changes the face on
# its own. The result is signed with the machine key, so the stored tier and
# face cannot be edited into something rarer.
#
# Each face carries frames of one expression, all the same width so the line
# never jitters. The frames advance while a turn runs and settle on the first
# one when it ends. Legend additionally shimmers through a flowing gradient.
#
# Faces are code points, like the bar cells. The spoken lines are literals -
# Hangul written as code points would be unreadable - so this file carries a
# UTF-8 BOM to pin its encoding down.

$KaoError = @(
    @(0xFF08, 0xFF1B, 0x3078, 0xFF1A, 0xFF09),
    @(0xFF08, 0xFF1B, 0x03C9, 0xFF1B, 0xFF09)
)

$MascotTiers = @('common', 'uncommon', 'rare', 'unique', 'legend')

# Legend gradients. Each legend face flows through its own ramp - a narrow
# band of hues moved by brightness, rather than a full trip round the wheel.
$Palettes = @{
    abyss = @(17, 18, 19, 20, 26, 32, 38, 44, 51, 45, 39, 33, 27, 21, 19, 18)
    amethyst = @(54, 55, 56, 57, 93, 129, 165, 201, 207, 213, 219, 213, 207, 201, 165, 93)
    crimson = @(52, 53, 89, 125, 161, 197, 198, 199, 200, 201, 200, 199, 198, 197, 161, 125)
    dawn = @(55, 56, 57, 93, 129, 165, 201, 206, 211, 216, 221, 220, 214, 208, 172, 129)
    ember = @(52, 88, 124, 160, 196, 202, 208, 214, 220, 214, 208, 202, 196, 160, 124, 88)
    obsidian = @(232, 233, 234, 235, 236, 238, 240, 243, 246, 250, 252, 250, 246, 243, 240, 236)
    royal = @(58, 94, 130, 166, 202, 208, 214, 220, 226, 220, 214, 208, 202, 166, 130, 94)
}
# 레전드 얼굴 순서대로 쓰는 팔레트.
$LegendPalettes = @('dawn', 'amethyst', 'ember', 'abyss', 'royal', 'crimson', 'obsidian')

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
        @(  # （・◡・）
            @(0xFF08, 0x30FB, 0x25E1, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x25E1, 0xFF0D, 0xFF09)
        ),
        @(  # （￢_￢）
            @(0xFF08, 0xFFE2, 0x005F, 0xFFE2, 0xFF09),
            @(0xFF08, 0xFFE2, 0x03C9, 0xFFE2, 0xFF09)
        ),
        @(  # （＝_＝）
            @(0xFF08, 0xFF1D, 0x005F, 0xFF1D, 0xFF09),
            @(0xFF08, 0xFF1D, 0x03C9, 0xFF1D, 0xFF09)
        ),
        @(  # （・_・）
            @(0xFF08, 0x30FB, 0x005F, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x005F, 0xFF0D, 0xFF09)
        ),
        @(  # （≖‿≖）
            @(0xFF08, 0x2256, 0x203F, 0x2256, 0xFF09),
            @(0xFF08, 0x2256, 0x005F, 0x2256, 0xFF09)
        ),
        @(  # （◣_◢）
            @(0xFF08, 0x25E3, 0x005F, 0x25E2, 0xFF09),
            @(0xFF08, 0x25E2, 0x005F, 0x25E3, 0xFF09)
        ),
        @(  # （ーωー）
            @(0xFF08, 0x30FC, 0x03C9, 0x30FC, 0xFF09),
            @(0xFF08, 0x30FC, 0x005F, 0x30FC, 0xFF09)
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
        @(  # （◕‿◕）
            @(0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09),
            @(0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09)
        ),
        @(  # （≧ω≦）
            @(0xFF08, 0x2267, 0x03C9, 0x2266, 0xFF09),
            @(0xFF08, 0x2267, 0x1D17, 0x2266, 0xFF09)
        ),
        @(  # （･ω<）
            @(0xFF08, 0xFF65, 0x03C9, 0x003C, 0xFF09),
            @(0xFF08, 0xFF65, 0x1D17, 0x003C, 0xFF09)
        ),
        @(  # （ㆆ_ㆆ）
            @(0xFF08, 0x3186, 0x005F, 0x3186, 0xFF09),
            @(0xFF08, 0x3186, 0x03C9, 0x3186, 0xFF09)
        ),
        @(  # （◔_◔）
            @(0xFF08, 0x25D4, 0x005F, 0x25D4, 0xFF09),
            @(0xFF08, 0x25D4, 0x03C9, 0x25D4, 0xFF09)
        ),
        @(  # （◓_◓）
            @(0xFF08, 0x25D3, 0x005F, 0x25D3, 0xFF09),
            @(0xFF08, 0x25D3, 0x03C9, 0x25D3, 0xFF09)
        ),
        @(  # （・ㅂ・）
            @(0xFF08, 0x30FB, 0x3142, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x3142, 0xFF0D, 0xFF09)
        ),
        @(  # （¬‿¬）
            @(0xFF08, 0x00AC, 0x203F, 0x00AC, 0xFF09),
            @(0xFF08, 0x00AC, 0x03C9, 0x00AC, 0xFF09)
        ),
        @(  # （◑_◑）
            @(0xFF08, 0x25D1, 0x005F, 0x25D1, 0xFF09),
            @(0xFF08, 0x25D1, 0x03C9, 0x25D1, 0xFF09)
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
        @(  # （◕‿◕）✧
            @(0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09, 0x2727),
            @(0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09, 0x2726)
        ),
        @(  # \（^o^）/
            @(0x005C, 0xFF08, 0x005E, 0x006F, 0x005E, 0xFF09, 0x002F),
            @(0x005C, 0xFF08, 0x005E, 0x004F, 0x005E, 0xFF09, 0x002F)
        ),
        @(  # （๑✧‿✧๑）
            @(0xFF08, 0x0E51, 0x2727, 0x203F, 0x2727, 0x0E51, 0xFF09),
            @(0xFF08, 0x0E51, 0x2726, 0x203F, 0x2726, 0x0E51, 0xFF09)
        ),
        @(  # ヽ（^ω^）ノ
            @(0x30FD, 0xFF08, 0x005E, 0x03C9, 0x005E, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x005E, 0x1D17, 0x005E, 0xFF09, 0xFF89)
        ),
        @(  # （￣ｰ￣）✧
            @(0xFF08, 0xFFE3, 0xFF70, 0xFFE3, 0xFF09, 0x2727),
            @(0xFF08, 0xFFE3, 0xFF70, 0xFFE3, 0xFF09, 0x2726)
        ),
        @(  # （▼ω▼）✧
            @(0xFF08, 0x25BC, 0x03C9, 0x25BC, 0xFF09, 0x2727),
            @(0xFF08, 0x25BC, 0x03C9, 0x25BC, 0xFF09, 0x2726)
        ),
        @(  # （◣ω◢）✧
            @(0xFF08, 0x25E3, 0x03C9, 0x25E2, 0xFF09, 0x2727),
            @(0xFF08, 0x25E2, 0x03C9, 0x25E3, 0xFF09, 0x2726)
        ),
        @(  # （￢‿￢）✧
            @(0xFF08, 0xFFE2, 0x203F, 0xFFE2, 0xFF09, 0x2727),
            @(0xFF08, 0xFFE2, 0x203F, 0xFFE2, 0xFF09, 0x2726)
        ),
        @(  # （★ω★）
            @(0xFF08, 0x2605, 0x03C9, 0x2605, 0xFF09),
            @(0xFF08, 0x2606, 0x03C9, 0x2606, 0xFF09)
        ),
        @(  # （☞ﾟヮﾟ）☞
            @(0xFF08, 0x261E, 0xFF9F, 0x30EE, 0xFF9F, 0xFF09, 0x261E),
            @(0xFF08, 0x261C, 0xFF9F, 0x30EE, 0xFF9F, 0xFF09, 0x261C)
        )
    )
    unique = @(
        @(  # ✧ヽ（☆▽☆）ノ✧
            @(0x2727, 0x30FD, 0xFF08, 0x2606, 0x25BD, 0x2606, 0xFF09, 0x30CE, 0x2727),
            @(0x2726, 0x30FE, 0xFF08, 0x2605, 0x25BD, 0x2605, 0xFF09, 0xFF89, 0x2726)
        ),
        @(  # ✧（ﾉ◕ヮ◕）ﾉ✧
            @(0x2727, 0xFF08, 0xFF89, 0x25D5, 0x30EE, 0x25D5, 0xFF09, 0xFF89, 0x2727),
            @(0x2726, 0xFF08, 0x30FD, 0x25D5, 0x30EE, 0x25D5, 0xFF09, 0x30FD, 0x2726)
        ),
        @(  # ✧（๑♡‿♡๑）✧
            @(0x2727, 0xFF08, 0x0E51, 0x2661, 0x203F, 0x2661, 0x0E51, 0xFF09, 0x2727),
            @(0x2726, 0xFF08, 0x0E51, 0x2665, 0x203F, 0x2665, 0x0E51, 0xFF09, 0x2726)
        ),
        @(  # ✧ヽ（✧∇✧）ノ✧
            @(0x2727, 0x30FD, 0xFF08, 0x2727, 0x2207, 0x2727, 0xFF09, 0x30CE, 0x2727),
            @(0x2726, 0x30FE, 0xFF08, 0x2726, 0x25BD, 0x2726, 0xFF09, 0xFF89, 0x2726)
        ),
        @(  # ✧＼（◕ᴗ◕）／✧
            @(0x2727, 0xFF3C, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0xFF0F, 0x2727),
            @(0x2726, 0xFF3C, 0xFF08, 0x25E0, 0x1D17, 0x25E0, 0xFF09, 0xFF0F, 0x2726)
        ),
        @(  # ✧ヽ（￣ヘ￣）ﾉ✧
            @(0x2727, 0x30FD, 0xFF08, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0xFF89, 0x2727),
            @(0x2726, 0x30FE, 0xFF08, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0xFF89, 0x2726)
        ),
        @(  # ✧（╬◣_◢）ﾉ✧
            @(0x2727, 0xFF08, 0x256C, 0x25E3, 0x005F, 0x25E2, 0xFF09, 0xFF89, 0x2727),
            @(0x2726, 0xFF08, 0x256C, 0x25E2, 0x005F, 0x25E3, 0xFF09, 0x30FD, 0x2726)
        ),
        @(  # ✧ヽ（￢_￢）ﾉ✧
            @(0x2727, 0x30FD, 0xFF08, 0xFFE2, 0x005F, 0xFFE2, 0xFF09, 0xFF89, 0x2727),
            @(0x2726, 0x30FE, 0xFF08, 0xFFE2, 0x03C9, 0xFFE2, 0xFF09, 0xFF89, 0x2726)
        ),
        @(  # ✧ヽ（╬￣ヘ￣）✧
            @(0x2727, 0x30FD, 0xFF08, 0x256C, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0x2727),
            @(0x2726, 0x30FE, 0xFF08, 0x256C, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0x2726)
        ),
        @(  # ✧ᕙ（⇀‸↼）ᕗ✧
            @(0x2727, 0x1559, 0xFF08, 0x21C0, 0x2038, 0x21BC, 0xFF09, 0x1557, 0x2727),
            @(0x2726, 0x1566, 0xFF08, 0x21C0, 0x2038, 0x21BC, 0xFF09, 0x1564, 0x2726)
        )
    )
    legend = @(
        @(  # ･ﾟ✧（◕ᴗ◕）✧ﾟ･
            @(0xFF65, 0xFF9F, 0x2727, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2727, 0xFF9F, 0xFF65),
            @(0xFF65, 0xFF9F, 0x2726, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2726, 0xFF9F, 0xFF65),
            @(0xFF65, 0xFF9F, 0x2727, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2726, 0xFF9F, 0xFF65),
            @(0xFF65, 0xFF9F, 0x2726, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2727, 0xFF9F, 0xFF65)
        ),
        @(  # ♡ヽ（♥‿♥）ノ♡
            @(0x2661, 0x30FD, 0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09, 0x30CE, 0x2661),
            @(0x2665, 0x30FE, 0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09, 0xFF89, 0x2665),
            @(0x2661, 0x30FE, 0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09, 0xFF89, 0x2661),
            @(0x2665, 0x30FD, 0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09, 0x30CE, 0x2665)
        ),
        @(  # ✧ﾟ（ﾉ≧∇≦）ﾉﾟ✧
            @(0x2727, 0xFF9F, 0xFF08, 0xFF89, 0x2267, 0x2207, 0x2266, 0xFF09, 0xFF89, 0xFF9F, 0x2727),
            @(0x2726, 0xFF9F, 0xFF08, 0xFF89, 0x2267, 0x25BD, 0x2266, 0xFF09, 0xFF89, 0xFF9F, 0x2726),
            @(0x2727, 0xFF9F, 0xFF08, 0x30FD, 0x2267, 0x2207, 0x2266, 0xFF09, 0x30FD, 0xFF9F, 0x2727),
            @(0x2726, 0xFF9F, 0xFF08, 0x30FD, 0x2267, 0x25BD, 0x2266, 0xFF09, 0x30FD, 0xFF9F, 0x2726)
        ),
        @(  # ♪ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♪
            @(0x266A, 0xFF9F, 0xFF65, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0xFF65, 0xFF9F, 0x266A),
            @(0x266B, 0xFF9F, 0xFF65, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0xFF65, 0xFF9F, 0x266B),
            @(0x2669, 0xFF9F, 0xFF65, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0xFF65, 0xFF9F, 0x2669),
            @(0x266C, 0xFF9F, 0xFF65, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0xFF65, 0xFF9F, 0x266C)
        ),
        @(  # ･ﾟ✧（￣ヘ￣）✧ﾟ･
            @(0xFF65, 0xFF9F, 0x2727, 0xFF08, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0x2727, 0xFF9F, 0xFF65),
            @(0xFF65, 0xFF9F, 0x2726, 0xFF08, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0x2726, 0xFF9F, 0xFF65),
            @(0xFF65, 0xFF9F, 0x2727, 0xFF08, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0x2726, 0xFF9F, 0xFF65),
            @(0xFF65, 0xFF9F, 0x2726, 0xFF08, 0xFFE3, 0x30D8, 0xFFE3, 0xFF09, 0x2727, 0xFF9F, 0xFF65)
        ),
        @(  # ✦ﾟ（╬◣_◢）ﾟ✦
            @(0x2726, 0xFF9F, 0xFF08, 0x256C, 0x25E3, 0x005F, 0x25E2, 0xFF09, 0xFF9F, 0x2726),
            @(0x2727, 0xFF9F, 0xFF08, 0x256C, 0x25E2, 0x005F, 0x25E3, 0xFF09, 0xFF9F, 0x2727),
            @(0x2726, 0xFF9F, 0xFF08, 0x256C, 0x25E2, 0x005F, 0x25E3, 0xFF09, 0xFF9F, 0x2726),
            @(0x2727, 0xFF9F, 0xFF08, 0x256C, 0x25E3, 0x005F, 0x25E2, 0xFF09, 0xFF9F, 0x2727)
        ),
        @(  # ≪✧（╬▼_▼）✧≫
            @(0x226A, 0x2727, 0xFF08, 0x256C, 0x25BC, 0x005F, 0x25BC, 0xFF09, 0x2727, 0x226B),
            @(0x226A, 0x2726, 0xFF08, 0x256C, 0x25BC, 0x005F, 0x25BC, 0xFF09, 0x2726, 0x226B),
            @(0x226A, 0x2727, 0xFF08, 0x256C, 0x25BC, 0x03C9, 0x25BC, 0xFF09, 0x2726, 0x226B),
            @(0x226A, 0x2726, 0xFF08, 0x256C, 0x25BC, 0x03C9, 0x25BC, 0xFF09, 0x2727, 0x226B)
        )
    )
    dev = @(
        @(  # ｛・ω・｝
            @(0xFF5B, 0x30FB, 0x03C9, 0x30FB, 0xFF5D),
            @(0xFF5B, 0xFF0D, 0x03C9, 0xFF0D, 0xFF5D)
        ),
        @(  # ⟨◕ᴗ◕⟩
            @(0x27E8, 0x25D5, 0x1D17, 0x25D5, 0x27E9),
            @(0x27E8, 0x25E0, 0x1D17, 0x25E0, 0x27E9)
        ),
        @(  # ［◉_◉］
            @(0xFF3B, 0x25C9, 0x005F, 0x25C9, 0xFF3D),
            @(0xFF3B, 0x25CE, 0x005F, 0x25CE, 0xFF3D)
        ),
        @(  # ⟨◣_◢⟩
            @(0x27E8, 0x25E3, 0x005F, 0x25E2, 0x27E9),
            @(0x27E8, 0x25E2, 0x005F, 0x25E3, 0x27E9)
        )
    )
}

# The mascot only speaks while a turn runs, right after one ends, and when
# something is waiting on you. The rest of the time it just sits there.
$TalkWork = @{
    common = @('끙...', '우우', '낑낑', '웅...')
    uncommon = @('하는 중!', '조금만!', '열일 중!', '가는 중!')
    rare = @('작업 중이에요', '조금만 기다려요', '거의 다 왔어요')
    unique = @('처리하고 있어요!', '조금만 기다려 주세요!', '열심히 하는 중이에요!')
    legend = @('작업을 진행하고 있습니다!', '곧 마무리됩니다, 잠시만요!')
    dev = @('빌드 도는 중.', '컴파일 중.', '테스트 도는 중.')
}
$TalkDone = @{
    common = @('왕!', '냥!', '뿌!', '삐약!', '꽥!', '음냐')
    uncommon = @('왕왕!', '다했다!', '끝!', '됐다!', '오케이!', '히히')
    rare = @('다 됐어요', '끝났어요', '완료했어요', '해냈어요!', '준비 끝!')
    unique = @('작업 완료했어요!', '다 끝냈습니다!', '깔끔하게 끝냈어요!', '확인해 보세요!')
    legend = @('요청하신 작업 모두 완료했습니다!', '전부 끝냈습니다, 확인 부탁드려요!', '작업을 성공적으로 마쳤습니다!')
    dev = @('빌드 통과.', '커밋하시죠.', '배포 준비 완료.', '테스트 전부 초록불.')
}
$TalkNotify = @{
    common = @('앙?', '웅?', '왕?')
    uncommon = @('저기요!', '잠깐만요!', '봐주세요!')
    rare = @('확인해 주세요', '봐주셔야 해요')
    unique = @('확인 부탁해요!', '잠시 봐주세요!')
    legend = @('확인 부탁드립니다!', '잠시 확인해 주세요!')
    dev = @('입력 대기 중.', '확인 요망.')
}
$TalkError = @('앗...', '실패했어요...')

# 얼굴 이름 — -Today 에서 종류를 보여줄 때 쓴다.
$KaoNames = @{
    common = @('웅크림', '보드람', '졸림', '고양이', '히죽', '순둥', '무심', '정색', '멍함', '실눈', '날섬', '심드렁')
    uncommon = @('방긋', '동글', '활짝', '미소', '신남', '윙크', '시큰둥', '응시', '경계', '새침', '능글', '떨떠름')
    rare = @('반짝', '만세', '빛나는미소', '환호', '두근', '신난만세', '냉정', '결의', '관조', '냉소', '별눈', '손짓')
    unique = @('눈부심', '들뜸', '사랑', '환희', '두손번쩍', '위엄', '분노', '냉혹', '압도', '근육')
    legend = @('축복', '사랑폭발', '승리', '노래', '군림', '각성', '심판')
    dev = @('중괄호', '꺾쇠', '해커', '노려봄')
}

# Builds one frame from its code points. Every glyph is inside the BMP, so a
# plain [char] cast is both correct and cheap enough to run every refresh.
function New-Kao {
    param([int[]]$Cp)
    $text = ''
    foreach ($c in $Cp) { $text += [char]$c }
    return $text
}

# The per-machine key. mascot-hook.ps1 creates it once with a CSPRNG; no key
# means no mascot, which is also what a fresh install looks like.
function Get-GachaKey {
    $file = Join-Path $CacheDir '.gacha-key'
    try { return [System.IO.File]::ReadAllText($file).Trim() } catch { return '' }
}

# HMAC-SHA256 of a message under the machine key, as lowercase hex.
function Get-Hmac {
    param([string]$Key, [string]$Message)

    $hmac = $null
    try {
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = [Text.Encoding]::UTF8.GetBytes($Key)
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message))
        return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
    } catch {
        return ''
    } finally {
        if ($null -ne $hmac) { $hmac.Dispose() }
    }
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

# The roll on file: @{ Date; Epoch; Tier; Index } or $null when there is none.
# A bad signature reads as no roll at all, so an edited file loses the mascot
# rather than granting a better one.
function Get-SavedRoll {
    $file = Join-Path $CacheDir 'gacha.txt'
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($file).Trim() } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $tok = $raw -split '\s+'
    if ($tok.Count -lt 6 -or $tok[0] -ne 'v1') { return $null }
    $key = Get-GachaKey
    if ($key -eq '') { return $null }

    $want = Get-Hmac $key "roll|v1|$($tok[1])|$($tok[2])|$($tok[3])|$($tok[4])"
    if ($want -eq '' -or $want -ne $tok[5]) { return $null }
    if ($null -eq $KaoTable[$tok[3]]) { return $null }

    $epoch = Get-Epoch $tok[2]
    if ($null -eq $epoch) { $epoch = 0 }
    return @{ Date = $tok[1]; Epoch = $epoch; Tier = $tok[3]; Index = [int]$tok[4] }
}

# One roll per calendar day. A stored roll stamped in the future means the
# clock moved backwards, and that does not earn another roll either.
function Test-CanRoll {
    param($Saved)

    if ($null -eq $Saved) { return $true }
    $today = ''
    try { $today = (Get-Date).ToString('yyyyMMdd') } catch { return $false }
    if ($Saved.Date -eq $today) { return $false }
    if ($Now -gt 0 -and $Saved.Epoch -gt 0 -and $Now -lt $Saved.Epoch) { return $false }
    return $true
}

# Rolls once and stores the signed result. Returns the new roll, or $null when
# there is no key. The randomness is cryptographic, so the outcome is not
# predictable from the date or from previous rolls.
function Invoke-GachaRoll {
    param([string]$WantTier = '')

    $key = Get-GachaKey
    if ($key -eq '') { return $null }

    # Picking a tier outright is a maintainer thing - it is how the faces get
    # looked at while working on them. Any other key is turned away here.
    if ($WantTier -ne '') {
        if (-not (Test-DevKey $key)) { return @{ Denied = $true } }
        if ($null -eq $KaoTable[$WantTier]) { return @{ BadTier = $true } }
    }

    $raw = New-Object byte[] 8
    $rng = $null
    try {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($raw)
    } catch {
        return $null
    } finally {
        if ($null -ne $rng) { $rng.Dispose() }
    }

    $n1 = ([long]$raw[0] * 16777216) + ([long]$raw[1] * 65536) + ([long]$raw[2] * 256) + [long]$raw[3]
    $n2 = ([long]$raw[4] * 16777216) + ([long]$raw[5] * 65536) + ([long]$raw[6] * 256) + [long]$raw[7]

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
    if ($WantTier -ne '') { $tier = $WantTier }

    $pool = $KaoTable[$tier]
    $idx = 0
    if ($pool.Count -gt 0) { $idx = [int]($n2 % $pool.Count) }

    $today = (Get-Date).ToString('yyyyMMdd')
    $stamp = $Now
    if ($stamp -le 0) { $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $sig = Get-Hmac $key "roll|v1|$($today)|$($stamp)|$($tier)|$($idx)"
    if ($sig -eq '') { return $null }

    try {
        if (-not (Test-Path -LiteralPath $CacheDir)) {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        }
        $file = Join-Path $CacheDir 'gacha.txt'
        [System.IO.File]::WriteAllText($file, "v1 $($today) $($stamp) $($tier) $($idx) $($sig)")
    } catch {
        return $null
    }
    return @{ Date = $today; Epoch = $stamp; Tier = $tier; Index = $idx }
}

# Flat tier color. Legend uses this only when colors are switched off.
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

# Paints every character its own hue along the rainbow and drifts the whole
# ramp one step per animation tick, so the color flows across the text.
function Get-GradientText {
    param([string]$Text, [int[]]$Ramp)

    if ([string]::IsNullOrEmpty($Reset)) { return $Text }
    if ($null -eq $Ramp -or $Ramp.Count -eq 0) { $Ramp = $Palettes.amethyst }
    $n = $Ramp.Count
    if ($n -le 0 -or $Text.Length -eq 0) { return $Text }

    # GradientShift 는 한 번 그릴 때 띠를 몇 칸 미는지. 스크립트가 다시 불리는
    # 주기는 refreshInterval 이 정하므로, 색을 빠르게 흐르게 하려면 이 값을 올린다.
    $step = 0
    if ($Now -gt 0) { $step = [int]((($Now / $AnimSecs) * $GradientShift) % $n) }

    $out = ''
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $idx = ($step + $i) % $n
        $out += "$($Esc)[1;38;5;$($Ramp[$idx])m$($Text[$i])"
    }
    return $out
}

# Wraps text in the right paint for its tier: the flowing gradient is reserved
# for legend; every other tier takes one flat color.
function Write-TierText {
    param([string]$Tier, [string]$Text, [int]$Index = 0)

    if ($Tier -eq 'legend') {
        $name = $LegendPalettes[$Index % $LegendPalettes.Count]
        return "$(Get-GradientText $Text $Palettes[$name])$($Reset)"
    }
    return "$(Get-TierColor $Tier)$($Text)$($Reset)"
}

# Picks a line from a pool, seeded with the timestamp the hook recorded, so it
# holds steady across redraws and changes with the next turn.
function Get-Talk {
    param($Pool, [long]$Stamp)

    if (-not $ShowMascotTalk) { return '' }
    if ($null -eq $Pool -or $Pool.Count -eq 0) { return '' }
    $h = ($Stamp * 1103515245 + 12345) % 2147483648
    if ($h -lt 0) { $h = -$h }
    return $Pool[[int]($h % $Pool.Count)]
}

# Reads the turn state the hooks left for this session and draws the face.
# Returns '' when nothing has been rolled yet or the hooks are not installed,
# so the line then looks exactly as it did before the mascot existed.
function Get-Mascot {
    param([string]$SidKey)

    if ([string]::IsNullOrWhiteSpace($SidKey)) { return '' }
    $file = Join-Path $CacheDir "mascot-$($SidKey).txt"
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($file).Trim() } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }

    $tok = $raw -split '\s+'
    $state = $tok[0]
    $stamp = 0
    if ($tok.Count -ge 2) {
        $parsed = Get-Epoch $tok[1]
        if ($null -ne $parsed) { $stamp = $parsed }
    }

    $draw = Get-SavedRoll
    if ($state -eq 'error') {
        $frame = 0
        if ($Now -gt 0) { $frame = [int](($Now / $AnimSecs) % $KaoError.Count) }
        $text = New-Kao $KaoError[$frame]
        $talk = Get-Talk $TalkError $stamp
        if ($talk -ne '') { $text += " $($talk)" }
        return "$($CCrit)$($text)$($Reset)"
    }
    if ($null -eq $draw) { return '' }

    $working = ($state -eq 'working')
    $face = $KaoTable[$draw.Tier][$draw.Index]
    $frame = 0
    if ($working -and $Now -gt 0 -and $face.Count -gt 0) {
        $frame = [int](($Now / $AnimSecs) % $face.Count)
    }
    $text = New-Kao $face[$frame]

    # Speaks while working, for a short while after finishing, and whenever
    # something is waiting on you. Otherwise it stays quiet.
    $talk = ''
    if ($working) {
        $talk = Get-Talk $TalkWork[$draw.Tier] $stamp
    } elseif ($state -eq 'notify') {
        $talk = Get-Talk $TalkNotify[$draw.Tier] $stamp
    } elseif ($state -eq 'done') {
        if ($Now -le 0 -or $stamp -le 0 -or ($Now - $stamp) -le $TalkWindowSecs) {
            $talk = Get-Talk $TalkDone[$draw.Tier] $stamp
        }
    }
    if ($talk -ne '') { $text += " $($talk)" }

    return (Write-TierText $draw.Tier $text $draw.Index)
}
# ---- subcommands -----------------------------------------------------------
# None of these read stdin, so they work from a plain prompt.

# Prints one roll as "（・ω・）  [커먼]", tier label included.
function Show-Draw {
    param($Draw)

    $label = @{
        common = '커먼'; uncommon = '언커먼'; rare = '레어'
        unique = '유니크'; legend = '레전드'; dev = 'DEV'
    }[$Draw.Tier]
    $face = $KaoTable[$Draw.Tier][$Draw.Index]

    $frames = @()
    foreach ($f in $face) { $frames += (New-Kao $f) }

    $name = $KaoNames[$Draw.Tier][$Draw.Index]
    $total = $KaoTable[$Draw.Tier].Count

    Write-Output ("  {0}  {1}  [{2} {3}/{4}종]" -f (Write-TierText $Draw.Tier $frames[0]),
        $name, $label, ($Draw.Index + 1), $total)
    Write-Output ("  표정 {0}장  {1}" -f $frames.Count, ($frames -join '  '))
}

if ($Help) {
    Write-Output "claude-statusline-astro $StatuslineVersion"
    Write-Output ''
    Write-Output '  statusline.ps1            Claude Code calls this with session JSON on stdin'
    Write-Output '  statusline.ps1 -Roll      오늘의 마스코트 뽑기 (하루 한 번)'
    Write-Output '  statusline.ps1 -Today     지금 쓰고 있는 마스코트 보기'
    Write-Output '  statusline.ps1 -Version   버전 보기'
    Write-Output '  statusline.ps1 -Help      이 도움말'
    Write-Output ''
    Write-Output '뽑기는 하루 한 번이고, 뽑기 전까지 지금 마스코트가 그대로 유지됩니다.'
    Write-Output ''
    Write-Output '  statusline.ps1 -Roll -Tier legend    등급 지정 (메인테이너 키 전용)'
    exit 0
}

if ($Version) {
    Write-Output "claude-statusline-astro $StatuslineVersion"
    exit 0
}

if ($Roll) {
    # 등급을 직접 고르는 건 메인테이너 키에서만 됩니다.
    if ($Tier -ne '') {
        $forced = Invoke-GachaRoll $Tier
        if ($null -eq $forced) {
            Write-Output '지정에 실패했습니다.'
            exit 1
        }
        if ($forced.Denied) {
            Write-Output '등급을 직접 고르는 건 메인테이너 키에서만 됩니다.'
            Write-Output '일반 사용자는 -Roll 로 하루 한 번 뽑습니다.'
            exit 1
        }
        if ($forced.BadTier) {
            Write-Output "그런 등급이 없습니다: $Tier"
            Write-Output '고를 수 있는 값: common uncommon rare unique legend dev'
            exit 1
        }
        Write-Output "$Tier 등급으로 지정했습니다."
        Write-Output ''
        Show-Draw $forced
        exit 0
    }

    $saved = Get-SavedRoll
    if (-not (Test-CanRoll $saved)) {
        Write-Output '오늘 뽑기는 이미 사용했습니다. 내일 다시 뽑을 수 있어요.'
        Write-Output ''
        Show-Draw $saved
        exit 0
    }
    $new = Invoke-GachaRoll
    if ($null -eq $new) {
        Write-Output '뽑기에 실패했습니다. 턴을 한 번 끝내 비밀키가 만들어졌는지 확인해 주세요.'
        exit 1
    }
    Write-Output '오늘의 마스코트를 뽑았습니다!'
    Write-Output ''
    Show-Draw $new
    $pool = $TalkDone[$new.Tier]
    if ($null -ne $pool -and $pool.Count -gt 0) {
        Write-Output ("  대사      {0}" -f ($pool -join ' / '))
    }
    Write-Output ''
    Write-Output '다음 뽑기는 내일부터 가능합니다.'
    exit 0
}

if ($Today) {
    $saved = Get-SavedRoll
    if ($null -eq $saved) {
        Write-Output '아직 뽑은 마스코트가 없습니다. -Roll 로 뽑아 보세요.'
        exit 0
    }
    Write-Output ("지금 마스코트  (뽑은 날 {0})" -f $saved.Date)
    Write-Output ''
    Show-Draw $saved
    $pool = $TalkDone[$saved.Tier]
    if ($null -ne $pool -and $pool.Count -gt 0) {
        Write-Output ("  대사      {0}" -f ($pool -join ' / '))
    }
    Write-Output ''
    if (Test-CanRoll $saved) {
        Write-Output '오늘 뽑기가 남아 있습니다. -Roll 로 새로 뽑을 수 있어요.'
    } else {
        Write-Output '오늘 뽑기는 사용했습니다. 내일 다시 뽑을 수 있어요.'
    }
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
