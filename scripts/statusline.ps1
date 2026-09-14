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

$StatuslineVersion = '1.2.0'

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# This script runs on every redraw, so the hot path below avoids cmdlets
# (each costs tens of milliseconds to spin up) and uses .NET calls instead.

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
# doing. The companion hooks (mascot-hook.ps1) tell it the state; without them
# it still shows the face, just never animated.
$ShowMascot = $true
# The mascot speaks a line when a turn finishes; set $false for the face alone.
$ShowMascotTalk = $true
# Seconds per expression frame while a turn runs. Claude Code only redraws
# every refreshInterval (the installer sets 2), so keep the two equal.
$AnimSecs = 2
# Legend gradient: how many cells the colour band travels per second. A ramp
# is 36 cells long, so at 1.5 it comes full circle every 24 seconds. The band
# moves on every redraw regardless of refreshInterval; a shorter interval only
# makes the motion finer, never faster.
$GradientSpeed = 1.5
# 24-bit colour for the legend ramp. Set $false on a terminal that only knows
# 256 colours; the ramp then snaps to the nearest of those.
$LegendTrueColor = $true
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
# trimmed of whitespace, hashed as UTF-8.
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
    $CacheDir = "$homeDir\.claude\statusline-cache"
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
    $CLegend = "$($Esc)[1;38;5;208m"  # orange, bold - only when the gradient is off
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

    if ($BarGap -eq '') {
        $bar = ($BarFull * $filled) + ($BarEmpty * ($BarLength - $filled))
    } else {
        $cells = [string[]]::new($BarLength)
        for ($i = 0; $i -lt $BarLength; $i++) {
            if ($i -lt $filled) { $cells[$i] = $BarFull } else { $cells[$i] = $BarEmpty }
        }
        $bar = [string]::Join($BarGap, $cells)
    }

    $out = "$($c)[$($BarPad)$($bar)$($c)$($BarPad)] $($cPct)$($pct)$($Reset)"
    if ($countdown -ne '') { $out += " $($Dim)$($countdown)$($Reset)" }
    return $out
}

# Last path segment, left-truncated so long names lose their head, not their tail.
function Get-LeafName {
    param([string]$Path, [int]$Max)

    $trimmed = $Path -replace '[\\/]+$', ''
    if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = $Path }
    $parts = $trimmed -split '[\\/]'
    $name = $parts[$parts.Count - 1]
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
# Faces are separated by '|' and their frames by '#', exactly as in the sh
# version; no face contains either character. This file carries a UTF-8 BOM so
# the glyphs and the Korean lines below survive any editor.

$KaoError = '（；へ；）#（；ㅅ；）'
$KaoCommon = '（・ω・）#（－ω－）|（´･ω･）#（´-ω-）|（ ˘ω˘ ）z#（ ˘ω˘ ）Z|（=・ω・=）#（=－ω－=）|（・∀・）#（－∀－）|（・◡・）#（－◡－）|（￢_￢）#（￢‿￢）|（＝_＝）#（＝.＝）|（・_・）#（－_－）|（≖‿≖）#（≖_≖）|（◣_◢）#（◢_◣）|（ー_ー）#（ー.ー）'
$KaoUncommon = '（๑˃ᴗ˂）#（๑˂ᴗ˃）|（｡･ω･｡）#（｡-ω-｡）|（^▽^）#（^∇^）|（◕‿◕）#（◠‿◠）|（≧ω≦）#（≧▽≦）|（･ω<）#（-ω<）|（ㆆ_ㆆ）#（ㆆ.ㆆ）|（◔_◔）#（◔‸◔）|（◓_◓）#（◒_◒）|（・ㅂ・）#（－ㅂ－）|（¬‿¬）#（¬_¬）|（◑_◑）#（◐_◐）'
$KaoRare = '（๑˃ᴗ˂）✧#（๑˂ᴗ˃）✦|ヽ（•‿•）ノ#ヾ（•‿•）ノ|（◕‿◕）✧#（◠‿◠）✦|\（^o^）/#\（^O^）/|（๑✧‿✧๑）#（๑✦‿✦๑）|ヽ（^ω^）ノ#ヾ（^ω^）ノ|（￣ｰ￣）✧#（￣ｰ￣）✦|（▼ω▼）✧#（▼ω▼）✦|（◣ω◢）✧#（◢ω◣）✦|（￢‿￢）✧#（￢‿￢）✦|（★ω★）#（☆ω☆）|（☞ﾟヮﾟ）☞#（☜ﾟヮﾟ）☜'
$KaoUnique = '✧ヽ（☆▽☆）ノ✧#✦ヾ（★▽★）ノ✦|✧（ﾉ◕ヮ◕）ﾉ✧#✦（ﾉ◠ヮ◠）ﾉ✦|✧（๑♡‿♡๑）✧#✦（๑♥‿♥๑）✦|✧ヽ（✧∇✧）ノ✧#✦ヾ（✦▽✦）ノ✦|✧＼（◕ᴗ◕）／✧#✦＼（◠ᴗ◠）／✦|✧ヽ（￣ヘ￣）ノ✧#✦ヾ（￣ヘ￣）ノ✦|✧ヽ（╬◣_◢）ノ✧#✦ヽ（╬◢_◣）ノ✦|✧ヽ（￢_￢）ノ✧#✦ヾ（￢‿￢）ノ✦|✧ヽ（╬￣ヘ￣）ノ✧#✦ヾ（╬￣ヘ￣）ノ✦|✧┗（⇀‸↼）┛✧#✦┗（⇀‸↼）┛✦'
$KaoLegend = '･ﾟ✧（◕ᴗ◕）✧ﾟ･#･ﾟ✦（◕ᴗ◕）✦ﾟ･#･ﾟ✧（◕ᴗ◕）✦ﾟ･#･ﾟ✦（◕ᴗ◕）✧ﾟ･|♡ヽ（♥‿♥）ノ♡#♥ヾ（♡‿♡）ノ♥#♡ヾ（♥‿♥）ノ♡#♥ヽ（♡‿♡）ノ♥|✧ﾟ（ﾉ≧∇≦）ﾉﾟ✧#✦ﾟ（ﾉ≧▽≦）ﾉﾟ✦#✧ﾟ（ﾉ≧∇≦）ﾉﾟ✦#✦ﾟ（ﾉ≧▽≦）ﾉﾟ✧|♪ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♪#♬ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♬#♩ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♩#♬ﾟ･（๑ᴖ◡ᴖ๑）･ﾟ♬|･ﾟ✧（￣ヘ￣）✧ﾟ･#･ﾟ✦（￣ヘ￣）✦ﾟ･#･ﾟ✧（￣ヘ￣）✦ﾟ･#･ﾟ✦（￣ヘ￣）✧ﾟ･|✦ﾟ（╬◣_◢）ﾟ✦#✧ﾟ（╬◢_◣）ﾟ✧#✦ﾟ（╬◢_◣）ﾟ✦#✧ﾟ（╬◣_◢）ﾟ✧|≪✧（╬▼_▼）✧≫#≪✦（╬▼_▼）✦≫#≪✧（╬▼_▼）✦≫#≪✦（╬▼_▼）✧≫'
$KaoDev = '｛・ω・｝#｛－ω－｝|⟨◕ᴗ◕⟩#⟨◠ᴗ◠⟩|［◉_◉］#［◉‸◉］|⟨◣_◢⟩#⟨◢_◣⟩'

$NameCommon = 'Kitten|Droopy|Snooze|Whiskers|Grin|Smiley|Side-eye|Meh|Blank|Smirk|Scowl|Deadpan'
$NameUncommon = 'Giggle|Rosy|Beam|Bright|Squee|Wink|Stare|Eyeroll|Half-lid|Hamster|Sly|Shifty'
$NameRare = 'Twinkle|Cheer|Glow|Hooray|Starry|Wave|Smug|Shades|Brat|Knowing|Starstruck|Gunslinger'
$NameUnique = 'Superstar|Jubilee|Lovestruck|Dazzle|Hurrah|Boss|Fury|Skeptic|Villain|Grit'
$NameLegend = 'Halo|Heartthrob|Bliss|Serenade|Monarch|Wrath|Overlord'
$NameDev = 'Root|Sudo|Kernel|Daemon'

# Legend ramps, 36 cells each, generated by docs/legend/render.py
# from the RGB keyframes there. One set in 24-bit colour, one snapped to the
# xterm cube for terminals that only know 256 colours.
$RampTrue = @{
    dawn = '38;2;90;46;166|38;2;101;49;171|38;2;112;52;176|38;2;123;55;181|38;2;133;57;186|38;2;144;60;191|38;2;155;63;196|38;2;167;68;189|38;2;178;72;182|38;2;190;77;175|38;2;201;81;168|38;2;213;86;161|38;2;224;90;154|38;2;229;98;147|38;2;234;106;140|38;2;240;114;133|38;2;245;122;126|38;2;250;130;119|38;2;255;138;112|38;2;255;147;109|38;2;255;156;105|38;2;255;165;102|38;2;255;173;99|38;2;255;182;95|38;2;255;191;92|38;2;255;197;100|38;2;255;203;107|38;2;255;209;115|38;2;255;215;123|38;2;255;221;130|38;2;255;227;138|38;2;227;197;143|38;2;200;167;147|38;2;173;137;152|38;2;145;106;157|38;2;118;76;161'
    crimson = '38;2;110;15;60|38;2;120;15;60|38;2;129;16;61|38;2;139;16;61|38;2;148;17;62|38;2;158;17;62|38;2;168;18;63|38;2;177;18;63|38;2;187;21;68|38;2;198;25;75|38;2;209;29;82|38;2;219;32;88|38;2;230;36;95|38;2;240;40;102|38;2;251;44;108|38;2;255;51;115|38;2;255;60;123|38;2;255;69;130|38;2;255;78;137|38;2;255;87;144|38;2;255;96;151|38;2;255;106;159|38;2;255;114;165|38;2;255;122;170|38;2;255;129;176|38;2;255;137;181|38;2;255;145;186|38;2;255;152;192|38;2;255;160;197|38;2;251;162;197|38;2;231;141;177|38;2;211;120;158|38;2;191;99;138|38;2;170;78;119|38;2;150;57;99|38;2;130;36;80'
    royal = '38;2;166;90;15|38;2;174;97;17|38;2;182;103;19|38;2;190;110;21|38;2;198;117;23|38;2;206;123;25|38;2;214;130;28|38;2;222;137;30|38;2;227;144;33|38;2;232;152;37|38;2;236;160;41|38;2;240;168;45|38;2;245;175;49|38;2;249;183;53|38;2;253;191;56|38;2;255;197;63|38;2;255;201;72|38;2;255;206;81|38;2;255;210;90|38;2;255;214;99|38;2;255;219;108|38;2;255;223;117|38;2;255;227;125|38;2;255;229;133|38;2;255;231;141|38;2;255;234;149|38;2;255;236;157|38;2;255;238;165|38;2;255;240;173|38;2;253;238;174|38;2;240;217;152|38;2;228;196;129|38;2;215;174;106|38;2;203;153;83|38;2;191;132;61|38;2;178;111;38'
    abyss = '38;2;18;32;110|38;2;20;37;123|38;2;22;43;135|38;2;23;48;148|38;2;25;54;161|38;2;27;59;173|38;2;29;65;186|38;2;31;70;198|38;2;32;79;207|38;2;34;88;215|38;2;35;98;222|38;2;37;107;230|38;2;38;117;237|38;2;40;127;245|38;2;41;136;252|38;2;44;146;255|38;2;47;157;255|38;2;50;168;255|38;2;53;179;255|38;2;55;189;255|38;2;58;200;255|38;2;61;211;255|38;2;67;219;254|38;2;79;224;252|38;2;90;230;250|38;2;101;235;248|38;2;112;240;246|38;2;123;246;244|38;2;134;251;242|38;2;140;249;236|38;2;122;218;218|38;2;105;187;200|38;2;87;156;182|38;2;70;125;164|38;2;53;94;146|38;2;35;63;128'
    amethyst = '38;2;59;15;122|38;2;66;19;134|38;2;73;23;146|38;2;80;27;157|38;2;87;31;169|38;2;94;35;181|38;2;102;39;193|38;2;109;43;205|38;2;116;48;212|38;2;124;52;219|38;2;131;57;226|38;2;139;61;232|38;2;146;66;239|38;2;154;71;246|38;2;161;75;252|38;2;168;81;255|38;2;175;88;255|38;2;182;94;255|38;2;189;101;255|38;2;196;108;255|38;2;203;114;255|38;2;210;121;255|38;2;215;128;255|38;2;219;136;255|38;2;223;143;255|38;2;226;151;255|38;2;230;158;255|38;2;234;166;255|38;2;237;173;255|38;2;235;174;251|38;2;210;152;233|38;2;185;129;214|38;2;160;106;196|38;2;134;83;177|38;2;109;61;159|38;2;84;38;140'
    ember = '38;2;107;10;10|38;2;119;11;11|38;2;132;12;12|38;2;144;13;13|38;2;156;14;14|38;2;169;16;16|38;2;181;17;17|38;2;194;18;18|38;2;203;25;18|38;2;211;33;18|38;2;219;41;18|38;2;227;49;18|38;2;235;57;18|38;2;244;66;18|38;2;252;74;18|38;2;255;83;20|38;2;255;94;22|38;2;255;105;25|38;2;255;116;28|38;2;255;126;31|38;2;255;137;34|38;2;255;148;36|38;2;255;157;40|38;2;255;165;45|38;2;255;174;50|38;2;255;182;55|38;2;255;190;60|38;2;255;198;65|38;2;255;206;70|38;2;251;207;72|38;2;230;179;63|38;2;210;151;54|38;2;189;123;46|38;2;169;95;37|38;2;148;66;28|38;2;128;38;19'
    radiance = '38;2;156;143;224|38;2;163;150;227|38;2;169;157;230|38;2;176;164;233|38;2;183;171;236|38;2;189;178;239|38;2;196;185;242|38;2;203;193;244|38;2;209;200;246|38;2;216;208;249|38;2;223;215;251|38;2;229;223;253|38;2;236;230;255|38;2;239;234;255|38;2;242;238;255|38;2;246;243;255|38;2;249;247;255|38;2;252;251;255|38;2;255;255;255|38;2;250;250;252|38;2;244;246;249|38;2;239;241;246|38;2;234;236;242|38;2;228;232;239|38;2;223;227;236|38;2;218;222;232|38;2;212;217;227|38;2;207;212;223|38;2;202;206;218|38;2;196;201;214|38;2;191;196;209|38;2;185;187;212|38;2;179;178;214|38;2;174;170;217|38;2;168;161;219|38;2;162;152;222'
}
$Ramp256 = @{
    dawn = '38;5;55|38;5;61|38;5;61|38;5;97|38;5;97|38;5;97|38;5;134|38;5;133|38;5;133|38;5;133|38;5;169|38;5;169|38;5;168|38;5;168|38;5;168|38;5;204|38;5;210|38;5;210|38;5;209|38;5;209|38;5;215|38;5;215|38;5;215|38;5;215|38;5;215|38;5;221|38;5;221|38;5;222|38;5;222|38;5;222|38;5;222|38;5;186|38;5;180|38;5;138|38;5;97|38;5;97'
    crimson = '38;5;53|38;5;89|38;5;89|38;5;89|38;5;89|38;5;125|38;5;125|38;5;125|38;5;125|38;5;161|38;5;161|38;5;161|38;5;161|38;5;197|38;5;197|38;5;204|38;5;204|38;5;204|38;5;204|38;5;204|38;5;204|38;5;205|38;5;205|38;5;211|38;5;211|38;5;211|38;5;211|38;5;211|38;5;218|38;5;218|38;5;175|38;5;175|38;5;132|38;5;132|38;5;95|38;5;89'
    royal = '38;5;130|38;5;130|38;5;130|38;5;130|38;5;172|38;5;172|38;5;172|38;5;172|38;5;172|38;5;172|38;5;214|38;5;214|38;5;215|38;5;215|38;5;215|38;5;221|38;5;221|38;5;221|38;5;221|38;5;221|38;5;221|38;5;222|38;5;222|38;5;222|38;5;222|38;5;222|38;5;229|38;5;229|38;5;229|38;5;229|38;5;222|38;5;186|38;5;179|38;5;173|38;5;137|38;5;130'
    abyss = '38;5;17|38;5;18|38;5;18|38;5;24|38;5;25|38;5;25|38;5;25|38;5;26|38;5;26|38;5;26|38;5;26|38;5;26|38;5;33|38;5;33|38;5;33|38;5;33|38;5;39|38;5;75|38;5;75|38;5;75|38;5;81|38;5;81|38;5;81|38;5;81|38;5;81|38;5;87|38;5;87|38;5;123|38;5;123|38;5;123|38;5;116|38;5;74|38;5;73|38;5;67|38;5;60|38;5;24'
    amethyst = '38;5;54|38;5;54|38;5;54|38;5;55|38;5;55|38;5;55|38;5;55|38;5;56|38;5;98|38;5;98|38;5;98|38;5;98|38;5;99|38;5;99|38;5;135|38;5;135|38;5;135|38;5;135|38;5;135|38;5;171|38;5;171|38;5;177|38;5;177|38;5;177|38;5;177|38;5;177|38;5;183|38;5;183|38;5;219|38;5;219|38;5;176|38;5;140|38;5;134|38;5;97|38;5;61|38;5;54'
    ember = '38;5;52|38;5;88|38;5;88|38;5;88|38;5;124|38;5;124|38;5;124|38;5;124|38;5;160|38;5;160|38;5;160|38;5;166|38;5;202|38;5;202|38;5;202|38;5;202|38;5;202|38;5;202|38;5;208|38;5;208|38;5;208|38;5;208|38;5;214|38;5;214|38;5;215|38;5;215|38;5;215|38;5;221|38;5;221|38;5;221|38;5;179|38;5;173|38;5;136|38;5;130|38;5;94|38;5;88'
    radiance = '38;5;140|38;5;140|38;5;146|38;5;146|38;5;147|38;5;147|38;5;183|38;5;183|38;5;189|38;5;189|38;5;189|38;5;189|38;5;225|38;5;225|38;5;231|38;5;231|38;5;231|38;5;231|38;5;231|38;5;231|38;5;231|38;5;231|38;5;195|38;5;189|38;5;189|38;5;188|38;5;188|38;5;188|38;5;188|38;5;188|38;5;152|38;5;146|38;5;146|38;5;146|38;5;146|38;5;140'
}
$LegendPalettes = @('dawn', 'crimson', 'royal', 'abyss', 'amethyst', 'ember', 'radiance')

$MascotTiers = @('common', 'uncommon', 'rare', 'unique', 'legend')

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

# The face string of a tier, or $null for a tier that does not exist.
function Get-Pool {
    param([string]$Tier)
    switch ($Tier) {
        'common'   { return $KaoCommon }
        'uncommon' { return $KaoUncommon }
        'rare'     { return $KaoRare }
        'unique'   { return $KaoUnique }
        'legend'   { return $KaoLegend }
        'dev'      { return $KaoDev }
    }
    return $null
}

function Get-Names {
    param([string]$Tier)
    switch ($Tier) {
        'common'   { return $NameCommon }
        'uncommon' { return $NameUncommon }
        'rare'     { return $NameRare }
        'unique'   { return $NameUnique }
        'legend'   { return $NameLegend }
        'dev'      { return $NameDev }
    }
    return ''
}

# The faces of a tier as an array of frame strings ("frame#frame").
function Get-Faces {
    param([string]$Tier)
    $pool = Get-Pool $Tier
    if ([string]::IsNullOrEmpty($pool)) { return @() }
    return ,($pool.Split('|'))
}

function Get-Frames {
    param([string]$Face)
    return ,($Face.Split('#'))
}

# The per-machine key. mascot-hook.ps1 creates it once with a CSPRNG; no key
# means no mascot, which is also what a fresh install looks like.
function Get-GachaKey {
    try { return [System.IO.File]::ReadAllText("$CacheDir\.gacha-key").Trim() } catch { return '' }
}

# HMAC-SHA256 of a message under the machine key, as lowercase hex.
function Get-Hmac {
    param([string]$Key, [string]$Message)

    $hmac = $null
    try {
        $hmac = [System.Security.Cryptography.HMACSHA256]::new()
        $hmac.Key = [Text.Encoding]::UTF8.GetBytes($Key)
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message))
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
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
        $hex = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
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
# rather than granting a better one. Index counts from 0, as in the sh version.
function Get-SavedRoll {
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText("$CacheDir\gacha.txt").Trim() } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $tok = $raw -split '\s+'
    if ($tok.Count -lt 6 -or $tok[0] -ne 'v1') { return $null }
    $key = Get-GachaKey
    if ($key -eq '') { return $null }

    $want = Get-Hmac $key "roll|v1|$($tok[1])|$($tok[2])|$($tok[3])|$($tok[4])"
    if ($want -eq '' -or $want -ne $tok[5]) { return $null }

    $faces = Get-Faces $tok[3]
    $idx = 0
    if (-not [int]::TryParse($tok[4], [ref]$idx)) { return $null }
    if ($faces.Count -eq 0 -or $idx -lt 0 -or $idx -ge $faces.Count) { return $null }

    $epoch = Get-Epoch $tok[2]
    if ($null -eq $epoch) { $epoch = 0 }
    return @{ Date = $tok[1]; Epoch = $epoch; Tier = $tok[3]; Index = $idx }
}

# One roll per calendar day. A stored roll stamped in the future means the
# clock moved backwards, and that does not earn another roll either.
function Test-CanRoll {
    param($Saved)

    if ($null -eq $Saved) { return $true }
    $today = ''
    try { $today = [DateTime]::Now.ToString('yyyyMMdd') } catch { return $false }
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
        if ($null -eq (Get-Pool $WantTier)) { return @{ BadTier = $true } }
    }

    $raw = [byte[]]::new(8)
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

    $faces = Get-Faces $tier
    $idx = 0
    if ($faces.Count -gt 0) { $idx = [int]($n2 % $faces.Count) }

    $today = [DateTime]::Now.ToString('yyyyMMdd')
    $stamp = $Now
    if ($stamp -le 0) { $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $sig = Get-Hmac $key "roll|v1|$($today)|$($stamp)|$($tier)|$($idx)"
    if ($sig -eq '') { return $null }

    try {
        [void][System.IO.Directory]::CreateDirectory($CacheDir)
        [System.IO.File]::WriteAllText("$CacheDir\gacha.txt", "v1 $($today) $($stamp) $($tier) $($idx) $($sig)")
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

# The ramp of a palette as an array of SGR colour parameters, taken from the
# precomputed tables above (24-bit or 256-colour, per LegendTrueColor).
$script:RampCache = @{}
function Get-Ramp {
    param([string]$Name)

    if ($script:RampCache.ContainsKey($Name)) { return $script:RampCache[$Name] }
    $table = $Ramp256
    if ($LegendTrueColor) { $table = $RampTrue }
    $codes = [string]$table[$Name]
    if ([string]::IsNullOrEmpty($codes)) { $codes = [string]$table['amethyst'] }
    $ramp = $codes.Split('|')
    $script:RampCache[$Name] = $ramp
    return $ramp
}

# Paints every character its own colour along the ramp and slides the whole
# band GradientSpeed cells per second, so the colour flows across the text.
function Get-GradientText {
    param([string]$Text, [string]$PaletteName, [int]$Offset = -1)

    if ([string]::IsNullOrEmpty($Reset) -or $Text.Length -eq 0) { return $Text }
    $ramp = Get-Ramp $PaletteName
    $n = $ramp.Count

    $step = $Offset
    if ($step -lt 0) {
        $step = 0
        if ($Now -gt 0) { $step = [int]([Math]::Floor($Now * $GradientSpeed) % $n) }
    }

    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        [void]$sb.Append($Esc).Append('[1;').Append($ramp[($step + $i) % $n]).Append('m').Append($Text[$i])
    }
    return $sb.ToString()
}

# Wraps text in the right paint for its tier: the flowing gradient is reserved
# for legend; every other tier takes one flat color.
function Write-TierText {
    param([string]$Tier, [string]$Text, [int]$Index = 0, [int]$Offset = -1)

    if ($Tier -eq 'legend') {
        $name = $LegendPalettes[$Index % $LegendPalettes.Count]
        return "$(Get-GradientText $Text $name $Offset)$($Reset)"
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

# Draws the face for the current roll, animated by the turn state the hooks
# left for this session. Returns '' only when nothing has been rolled yet, so
# the line then looks exactly as it did before the mascot existed.
function Get-Mascot {
    param([string]$SidKey)

    # The face is the machine-wide roll, so it shows in every session from the
    # first redraw. The state file only adds what the turn is doing; until the
    # hooks write one the mascot simply sits idle.
    $state = 'idle'
    $stamp = 0
    if (-not [string]::IsNullOrWhiteSpace($SidKey)) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText("$CacheDir\mascot-$($SidKey).txt").Trim() } catch { $raw = '' }
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $tok = $raw -split '\s+'
            $state = $tok[0]
            if ($tok.Count -ge 2) {
                $parsed = Get-Epoch $tok[1]
                if ($null -ne $parsed) { $stamp = $parsed }
            }
        }
    }

    $draw = Get-SavedRoll
    if ($state -eq 'error') {
        $frames = Get-Frames $KaoError
        $frame = 0
        if ($Now -gt 0) { $frame = [int](($Now / $AnimSecs) % $frames.Count) }
        $text = $frames[$frame]
        $talk = Get-Talk $TalkError $stamp
        if ($talk -ne '') { $text += " $($talk)" }
        return "$($CCrit)$($text)$($Reset)"
    }
    if ($null -eq $draw) { return '' }

    $working = ($state -eq 'working')
    $faces = Get-Faces $draw.Tier
    $frames = Get-Frames $faces[$draw.Index]
    $frame = 0
    if ($working -and $Now -gt 0 -and $frames.Count -gt 0) {
        $frame = [int](($Now / $AnimSecs) % $frames.Count)
    }
    $text = $frames[$frame]

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

# Prints one roll as "（・ω・）  Kitten  [커먼 1/12]", name and tier included.
function Show-Draw {
    param($Draw)

    $label = @{
        common = '커먼'; uncommon = '언커먼'; rare = '레어'
        unique = '유니크'; legend = '레전드'; dev = 'DEV'
    }[$Draw.Tier]
    $faces = Get-Faces $Draw.Tier
    $frames = Get-Frames $faces[$Draw.Index]
    $names = (Get-Names $Draw.Tier).Split('|')
    $name = ''
    if ($Draw.Index -lt $names.Count) { $name = $names[$Draw.Index] }

    Write-Output ("  {0}  {1}  [{2} {3}/{4}]" -f (Write-TierText $Draw.Tier $frames[0] $Draw.Index 0),
        $name, $label, ($Draw.Index + 1), $faces.Count)
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

# ---- payload fields --------------------------------------------------------
# The handful of fields this line needs are pulled with regular expressions
# rather than ConvertFrom-Json, which alone costs about 100 ms per redraw.

# A string field: the first "key": "value" in the payload, JSON escapes undone.
function Get-JsonStr {
    param([string]$Json, [string]$Key)
    $m = [regex]::Match($Json, '"' + [regex]::Escape($Key) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    if ($v.IndexOf('\') -ge 0) {
        $v = [regex]::Replace($v, '\\u([0-9a-fA-F]{4})', { param($mm) [string][char][Convert]::ToInt32($mm.Groups[1].Value, 16) })
        $v = $v.Replace('\"', '"').Replace('\/', '/').Replace('\\', '\')
    }
    return $v
}

# The body of "key": { ... }, found by scanning braces so nesting of any depth
# is fine, with the nested objects blanked out so a field lookup inside cannot
# land in one of them. (No string value in the payload contains a brace.)
function Get-JsonObj {
    param([string]$Json, [string]$Key)
    $at = $Json.IndexOf('"' + $Key + '"')
    if ($at -lt 0) { return $null }
    $open = $Json.IndexOf('{', $at)
    if ($open -lt 0) { return $null }
    $colon = $Json.IndexOf(':', $at)
    if ($colon -lt 0 -or $colon -gt $open) { return $null }
    $depth = 0
    $pos = $open
    while ($pos -lt $Json.Length) {
        $nextOpen = $Json.IndexOf('{', $pos)
        $nextClose = $Json.IndexOf('}', $pos)
        if ($nextClose -lt 0) { return $null }
        if ($nextOpen -ge 0 -and $nextOpen -lt $nextClose) {
            $depth++
            $pos = $nextOpen + 1
        } else {
            $depth--
            $pos = $nextClose + 1
            if ($depth -eq 0) {
                $body = $Json.Substring($open + 1, $nextClose - $open - 1)
                if ($body.IndexOf('{') -ge 0) { $body = [regex]::Replace($body, '\{[^{}]*\}', '') }
                return $body
            }
        }
    }
    return $null
}

# A numeric field inside an already extracted object body.
function Get-JsonNum {
    param([string]$Body, [string]$Key)
    if ($null -eq $Body) { return $null }
    $m = [regex]::Match($Body, '"' + [regex]::Escape($Key) + '"\s*:\s*(-?[0-9][0-9.]*)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

try {
    $raw = $null
    try { $raw = [Console]::In.ReadToEnd() } catch { $raw = $null }
    if ($null -eq $raw) { $raw = '' }

    $dir = $null
    $workspace = Get-JsonObj $raw 'workspace'
    if ($null -ne $workspace) { $dir = Get-JsonStr $workspace 'current_dir' }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-JsonStr $raw 'cwd' }

    $model = $null
    $modelObj = Get-JsonObj $raw 'model'
    if ($null -ne $modelObj) { $model = Get-JsonStr $modelObj 'display_name' }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = '-' }

    # One git call answers everything: repository root, branch, and the short
    # hash for a detached HEAD. A missing git or a directory outside any
    # repository both fall through with nothing set.
    $branch = ''
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($dir) -and [System.IO.Directory]::Exists($dir)) {
        try {
            $lines = @(& git -C "$dir" rev-parse --show-toplevel --abbrev-ref HEAD --short HEAD 2>$null)
            if ($lines.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace([string]$lines[0])) {
                $root = ([string]$lines[0]).Trim()
            }
            if ($lines.Count -ge 2) {
                $b = ([string]$lines[1]).Trim()
                if ($b -eq 'HEAD' -and $lines.Count -ge 3) { $b = ([string]$lines[2]).Trim() }
                if (-not [string]::IsNullOrWhiteSpace($b)) { $branch = $b }
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

    $ctxPct = Get-Pct (Get-JsonNum (Get-JsonObj $raw 'context_window') 'used_percentage')

    $five = Get-JsonObj $raw 'five_hour'
    $seven = Get-JsonObj $raw 'seven_day'
    $fiveU = Get-Pct (Get-JsonNum $five 'used_percentage')
    $fiveR = Get-Epoch (Get-JsonNum $five 'resets_at')
    $sevenU = Get-Pct (Get-JsonNum $seven 'used_percentage')
    $sevenR = Get-Epoch (Get-JsonNum $seven 'resets_at')

    $sessionId = Get-JsonStr $raw 'session_id'

    # ---- cross-session rate-limit sync -------------------------------------
    # The payload's rate_limits are a per-session snapshot frozen at that
    # session's last API response, so idle terminals drift apart and disagree
    # with the web usage page. Every session therefore publishes the snapshot
    # it was handed, and every session renders the best snapshot published by
    # anyone: the newest window wins, and within the same window the highest
    # reading wins, because account usage only rises while a window is open.
    #
    # Cache line format (one per session): "v1 <5h%> <5h_reset> <7d%> <7d_reset>"
    try { [void][System.IO.Directory]::CreateDirectory($CacheDir) } catch { }

    $sidKey = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$sessionId)) {
        $sidKey = ([string]$sessionId) -replace '[^a-zA-Z0-9]', ''
        if ($sidKey.Length -gt 8) { $sidKey = $sidKey.Substring(0, 8) }
    }

    if ($null -ne $fiveU -and $sidKey -ne '' -and [System.IO.Directory]::Exists($CacheDir)) {
        try {
            $fr = '-'; if ($null -ne $fiveR) { $fr = [string]$fiveR }
            $su = '-'; if ($null -ne $sevenU) { $su = [string]$sevenU }
            $sr = '-'; if ($null -ne $sevenR) { $sr = [string]$sevenR }
            [System.IO.File]::WriteAllText(
                "$CacheDir\rl-$sidKey.txt",
                "v1 $fiveU $fr $su $sr`n",
                ([System.Text.UTF8Encoding]::new($false)))
        } catch { }

        # Entries from long-dead sessions stop mattering once their window
        # closes; sweep anything untouched for two days. The sweep itself runs
        # at most once an hour, tracked by a marker file, so it costs nothing
        # on an ordinary redraw.
        try {
            $marker = "$CacheDir\.swept"
            $due = $true
            if ([System.IO.File]::Exists($marker)) {
                $due = ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($marker)).TotalHours -ge 1
            }
            if ($due) {
                $cutoff = [DateTime]::UtcNow.AddHours(-48)
                foreach ($pattern in @('rl-*.txt', 'mascot-*.txt')) {
                    foreach ($f in [System.IO.Directory]::GetFiles($CacheDir, $pattern)) {
                        if ([System.IO.File]::GetLastWriteTimeUtc($f) -lt $cutoff) {
                            [System.IO.File]::Delete($f)
                        }
                    }
                }
                [System.IO.File]::WriteAllText($marker, '')
            }
        } catch { }
    }

    $best5U = $fiveU; $best5R = 0; if ($null -ne $fiveR) { $best5R = $fiveR }
    $best7U = $sevenU; $best7R = 0; if ($null -ne $sevenR) { $best7R = $sevenR }

    try {
        foreach ($f in [System.IO.Directory]::GetFiles($CacheDir, 'rl-*.txt')) {
            $parts = ''
            try { $parts = [System.IO.File]::ReadAllText($f).Trim() } catch { continue }
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

    [Console]::Out.WriteLine($out)
} catch {
    [Console]::Out.WriteLine('DIR - | GIT - | MODEL - | CTX --% | 5H --%')
}
