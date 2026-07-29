# claude-code-statusline — Windows PowerShell implementation (5.1 and PowerShell 7+).
#
# Reads the Claude Code session JSON from stdin and prints exactly one line:
#   DIR <path> | GIT <branch> | MODEL <name> | CTX [bar] NN% | 5H [bar] NN%
#
# Set NO_COLOR=1 to strip the ANSI colors.

$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

$BarLength = 10
# Built from code points so the file stays readable no matter how it is encoded.
$BarFull = [string][char]0x25B0   # BLACK PARALLELOGRAM
$BarEmpty = [string][char]0x25B1  # WHITE PARALLELOGRAM

$Esc = [char]27
if ([string]::IsNullOrEmpty($env:NO_COLOR)) {
    $Reset = "$($Esc)[0m"
    $Dim = "$($Esc)[90m"
    $CDir = "$($Esc)[96m"
    $CGit = "$($Esc)[95m"
    $CModel = "$($Esc)[93m"
    $COk = "$($Esc)[92m"
    $CWarn = "$($Esc)[93m"
    $CCrit = "$($Esc)[91m"
} else {
    $Reset = ''; $Dim = ''; $CDir = ''; $CGit = ''; $CModel = ''
    $COk = ''; $CWarn = ''; $CCrit = ''
}

# Renders "[▰▰▰▰▱▱▱▱▱▱] 42%", colored green/amber/red by how full it is.
function Get-Meter {
    param($Raw)

    $blank = "$($Dim)[----------] --%$($Reset)"
    if ($null -eq $Raw -or [string]::IsNullOrWhiteSpace([string]$Raw)) { return $blank }

    $value = 0.0
    $parsed = [double]::TryParse(
        [string]$Raw,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$value)
    if (-not $parsed) { return $blank }

    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }
    $n = [int][Math]::Floor($value + 0.5)

    $filled = [int][Math]::Floor(($n + 5) / 10)
    if ($filled -gt $BarLength) { $filled = $BarLength }
    if ($filled -lt 0) { $filled = 0 }

    if ($n -ge 85) { $c = $CCrit }
    elseif ($n -ge 60) { $c = $CWarn }
    else { $c = $COk }

    $bar = ($BarFull * $filled) + ($BarEmpty * ($BarLength - $filled))
    return "$($Dim)[$($c)$($bar)$($Dim)] $($c)$($n)%$($Reset)"
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
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '-' }

    $model = $null
    try { $model = $data.model.display_name } catch { }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = '-' }

    $branch = '-'
    if ($dir -ne '-' -and (Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $dir)) {
        try {
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
        if ([string]::IsNullOrWhiteSpace($branch)) { $branch = '-' }
    }

    $ctx = $null
    try { $ctx = $data.context_window.used_percentage } catch { }
    $five = $null
    try { $five = $data.rate_limits.five_hour.used_percentage } catch { }

    $sep = "$($Dim) | $($Reset)"
    $line = "$($Dim)DIR$($Reset) $($CDir)$($dir)$($Reset)"
    $line += "$($sep)$($Dim)GIT$($Reset) $($CGit)$($branch)$($Reset)"
    $line += "$($sep)$($Dim)MODEL$($Reset) $($CModel)$($model)$($Reset)"
    $line += "$($sep)$($Dim)CTX$($Reset) $(Get-Meter $ctx)"
    $line += "$($sep)$($Dim)5H$($Reset) $(Get-Meter $five)"

    Write-Output $line
} catch {
    Write-Output 'DIR - | GIT - | MODEL - | CTX [----------] --% | 5H [----------] --%'
}
