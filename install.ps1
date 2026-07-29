# claude-code-statusline installer for Windows PowerShell 5.1+ and PowerShell 7+.
#
#   .\install.ps1
#   irm https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.ps1 | iex
#
# Copies statusline.ps1 into ~/.claude/ and merges a statusLine entry into
# ~/.claude/settings.json. Existing settings are preserved and backed up.

$ErrorActionPreference = 'Stop'

$repoRaw = 'https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main'

$home_ = $HOME
if ([string]::IsNullOrWhiteSpace($home_)) { $home_ = $env:USERPROFILE }
$claudeDir = Join-Path $home_ '.claude'
$target = Join-Path $claudeDir 'statusline.ps1'
$settings = Join-Path $claudeDir 'settings.json'

if (-not (Test-Path -LiteralPath $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

$source = $null
if ($PSScriptRoot) { $source = Join-Path $PSScriptRoot 'scripts\statusline.ps1' }

if ($source -and (Test-Path -LiteralPath $source)) {
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-Host "installed  $target (from $source)"
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "$repoRaw/scripts/statusline.ps1" -OutFile $target -UseBasicParsing
    Write-Host "installed  $target (downloaded)"
}

# Forward slashes keep the JSON free of escaped backslashes.
$commandPath = $target -replace '\\', '/'
$command = "powershell -NoProfile -ExecutionPolicy Bypass -File $commandPath"

$data = $null
if (Test-Path -LiteralPath $settings) {
    Copy-Item -LiteralPath $settings -Destination "$settings.bak" -Force
    Write-Host "backup     $settings.bak"
    $text = [System.IO.File]::ReadAllText($settings)
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $data = $text | ConvertFrom-Json
    }
}
if ($null -eq $data) { $data = New-Object PSObject }

$statusLine = New-Object PSObject
$statusLine | Add-Member -MemberType NoteProperty -Name 'type' -Value 'command'
$statusLine | Add-Member -MemberType NoteProperty -Name 'command' -Value $command
$statusLine | Add-Member -MemberType NoteProperty -Name 'refreshInterval' -Value 5

if ($data.PSObject.Properties.Name -contains 'statusLine') {
    $data.statusLine = $statusLine
} else {
    $data | Add-Member -MemberType NoteProperty -Name 'statusLine' -Value $statusLine
}

# settings.json must be UTF-8 without a BOM — a BOM breaks JSON.parse.
$json = $data | ConvertTo-Json -Depth 32
[System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "configured $settings"
Write-Host ''
Write-Host 'Done. Restart Claude Code (or open a new session) to see the status line.'
