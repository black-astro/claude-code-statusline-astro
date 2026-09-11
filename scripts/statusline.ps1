# claude-code-statusline — Windows PowerShell implementation (5.1 and PowerShell 7+).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <project> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN% 4h10m
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
# Rarity odds in per-mille, highest first. They must total 1000.
$MascotOdds = @{ common = 600; uncommon = 250; rare = 100; unique = 40; legend = 10 }

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
} else {
    $Reset = ''; $Dim = ''; $CDir = ''; $CGitMain = ''; $CGitOther = ''
    $CModel = ''; $COk = ''; $CWarn = ''; $CCrit = ''
    $CCommon = ''; $CUncommon = ''; $CRare = ''; $CUnique = ''; $CLegend = ''
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
# The face is the day's draw. It is never stored and it is never rolled here:
# it is derived from HMAC-SHA256(machine key, today's date). The same day
# therefore always yields the same face however often this script runs, and no
# amount of editing or deleting files changes it - forcing a legend would mean
# inverting HMAC-SHA256. The key is created once by mascot-hook.ps1.
#
# Each face carries two frames of one expression, always the same width so the
# line never jitters. While a turn runs the frames alternate on every refresh;
# once the turn is done the face settles on its first frame.
#
# Glyphs are code points, like the bar cells, so the file survives any encoding.

$KaoError = @(
    @(0xFF08, 0xFF1B, 0x3078, 0xFF1A, 0xFF09),
    @(0xFF08, 0xFF1B, 0x03C9, 0xFF1B, 0xFF09)
)

$MascotTiers = @('common', 'uncommon', 'rare', 'unique', 'legend')

# Rarity -> faces -> frames.
$KaoTable = @{
    common = @(
        @(  # plain / blink
            @(0xFF08, 0x30FB, 0x03C9, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x03C9, 0xFF0D, 0xFF09)
        ),
        @(  # soft / blink
            @(0xFF08, 0x00B4, 0xFF65, 0x03C9, 0xFF65, 0xFF09),
            @(0xFF08, 0x00B4, 0xFF0D, 0x03C9, 0xFF0D, 0xFF09)
        ),
        @(  # blank / blink
            @(0xFF08, 0x30FB, 0x005F, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x005F, 0xFF0D, 0xFF09)
        ),
        @(  # sleepy / smile
            @(0xFF08, 0x0020, 0x02D8, 0x03C9, 0x02D8, 0x0020, 0xFF09),
            @(0xFF08, 0x0020, 0x02D8, 0x1D17, 0x02D8, 0x0020, 0xFF09)
        ),
        @(  # cat / blink
            @(0xFF08, 0x003D, 0x30FB, 0x03C9, 0x30FB, 0x003D, 0xFF09),
            @(0xFF08, 0x003D, 0xFF0D, 0x03C9, 0xFF0D, 0x003D, 0xFF09)
        ),
        @(  # grin / blink
            @(0xFF08, 0x30FB, 0x2200, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x2200, 0xFF0D, 0xFF09)
        )
    )
    uncommon = @(
        @(  # happy / wink
            @(0xFF08, 0x0E51, 0x02C3, 0x1D17, 0x02C2, 0xFF09),
            @(0xFF08, 0x0E51, 0x02C2, 0x1D17, 0x02C3, 0xFF09)
        ),
        @(  # round / blink
            @(0xFF08, 0xFF61, 0xFF65, 0x03C9, 0xFF65, 0xFF61, 0xFF09),
            @(0xFF08, 0xFF61, 0xFF0D, 0x03C9, 0xFF0D, 0xFF61, 0xFF09)
        ),
        @(  # laugh / hum
            @(0xFF08, 0x005E, 0x25BD, 0x005E, 0xFF09),
            @(0xFF08, 0x005E, 0x03C9, 0x005E, 0xFF09)
        ),
        @(  # smug / blink
            @(0xFF08, 0x30FB, 0x3142, 0x30FB, 0xFF09),
            @(0xFF08, 0xFF0D, 0x3142, 0xFF0D, 0xFF09)
        ),
        @(  # smile / blink
            @(0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09),
            @(0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09)
        )
    )
    rare = @(
        @(  # sparkle
            @(0xFF08, 0x0E51, 0x02C3, 0x1D17, 0x02C2, 0xFF09, 0x2727),
            @(0xFF08, 0x0E51, 0x02C3, 0x1D17, 0x02C2, 0xFF09, 0x2726)
        ),
        @(  # cheer / wave
            @(0x30FD, 0xFF08, 0x2022, 0x203F, 0x2022, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x2022, 0x203F, 0x2022, 0xFF09, 0xFF89)
        ),
        @(  # star eyes
            @(0xFF08, 0x2605, 0x03C9, 0x2605, 0xFF09),
            @(0xFF08, 0x2606, 0x03C9, 0x2606, 0xFF09)
        ),
        @(  # smile sparkle
            @(0xFF08, 0x25D5, 0x203F, 0x25D5, 0xFF09, 0x2727),
            @(0xFF08, 0x25E0, 0x203F, 0x25E0, 0xFF09, 0x2726)
        ),
        @(  # banzai
            @(0x005C, 0xFF08, 0x005E, 0x006F, 0x005E, 0xFF09, 0x002F),
            @(0x005C, 0xFF08, 0x005E, 0x004F, 0x005E, 0xFF09, 0x002F)
        )
    )
    unique = @(
        @(  # shining
            @(0xFF08, 0x2606, 0x25BD, 0x2606, 0xFF09),
            @(0xFF08, 0x2605, 0x25BD, 0x2605, 0xFF09)
        ),
        @(  # shocked
            @(0x30FD, 0xFF08, 0x00B0, 0x3007, 0x00B0, 0xFF09, 0xFF89),
            @(0x30FE, 0xFF08, 0x00B0, 0x0414, 0x00B0, 0xFF09, 0xFF89)
        ),
        @(  # excited
            @(0xFF08, 0xFF89, 0x25D5, 0x30EE, 0x25D5, 0xFF09, 0xFF89),
            @(0xFF08, 0x30FD, 0x25D5, 0x30EE, 0x25D5, 0xFF09, 0x30FD)
        ),
        @(  # heart eyes
            @(0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09),
            @(0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09)
        )
    )
    legend = @(
        @(  # blessed
            @(0x2727, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2727),
            @(0x2726, 0xFF08, 0x25D5, 0x1D17, 0x25D5, 0xFF09, 0x2726)
        ),
        @(  # in love
            @(0x30FD, 0xFF08, 0x2661, 0x203F, 0x2661, 0xFF09, 0x30CE),
            @(0x30FE, 0xFF08, 0x2665, 0x203F, 0x2665, 0xFF09, 0xFF89)
        ),
        @(  # triumph
            @(0xFF08, 0xFF89, 0x2267, 0x2207, 0x2266, 0xFF09, 0xFF89),
            @(0xFF08, 0xFF89, 0x2267, 0x25BD, 0x2266, 0xFF09, 0xFF89)
        ),
        @(  # singing
            @(0x266A, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0x266A),
            @(0x266B, 0xFF08, 0x0E51, 0x1D16, 0x25E1, 0x1D16, 0x0E51, 0xFF09, 0x266B)
        )
    )
}

# Builds a face frame from its code points. Every glyph is inside the BMP, so a
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

# Today's draw: @{ Tier; Index } or $null when there is no key.
# Two independent 32-bit windows of one HMAC pick the tier and the face, so the
# tier is not recoverable from the face or the other way round.
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

    $roll = [int]($n1 % 1000)
    $tier = $MascotTiers[0]
    $acc = 0
    foreach ($t in $MascotTiers) {
        $acc += [int]$MascotOdds[$t]
        if ($roll -lt $acc) { $tier = $t; break }
    }

    $pool = $KaoTable[$tier]
    $idx = 0
    if ($pool.Count -gt 0) { $idx = [int]($n2 % $pool.Count) }
    return @{ Tier = $tier; Index = $idx }
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

    $state = ($raw -split '\s+')[0]
    $working = ($state -eq 'working')

    if ($state -eq 'error') {
        $frame = 0
        if ($Now -gt 0) { $frame = [int](($Now / 5) % $KaoError.Count) }
        return "$($CCrit)$(New-Kao $KaoError[$frame])$($Reset)"
    }
    if (-not $working -and $state -ne 'done') { return '' }

    $draw = Get-GachaDraw
    if ($null -eq $draw) { return '' }

    $face = $KaoTable[$draw.Tier][$draw.Index]
    $frame = 0
    if ($working -and $Now -gt 0 -and $face.Count -gt 0) {
        $frame = [int](($Now / 5) % $face.Count)
    }

    switch ($draw.Tier) {
        'legend'   { $color = $CLegend }
        'unique'   { $color = $CUnique }
        'rare'     { $color = $CRare }
        'uncommon' { $color = $CUncommon }
        default    { $color = $CCommon }
    }
    return "$($color)$(New-Kao $face[$frame])$($Reset)"
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
