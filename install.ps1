# claude-code-statusline installer for Windows PowerShell 5.1+ and PowerShell 7+.
#
#   .\install.ps1
#   .\install.ps1 -NoMascot      # status line only, skip the mascot hooks
#   irm https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.ps1 | iex
#
# Copies statusline.ps1 (and mascot-hook.ps1) into ~/.claude/, then merges a
# statusLine entry and the mascot hooks into ~/.claude/settings.json. Existing
# settings are preserved and backed up.

param([switch]$NoMascot)

$ErrorActionPreference = 'Stop'

$repoRaw = 'https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main'

$home_ = $HOME
if ([string]::IsNullOrWhiteSpace($home_)) { $home_ = $env:USERPROFILE }
$claudeDir = Join-Path $home_ '.claude'
$target = Join-Path $claudeDir 'statusline.ps1'
$hookTarget = Join-Path $claudeDir 'mascot-hook.ps1'
$settings = Join-Path $claudeDir 'settings.json'

if (-not (Test-Path -LiteralPath $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

# Installs one script from the cloned repo, falling back to a download.
function Install-Script {
    param([string]$Name, [string]$Destination)

    $source = $null
    if ($PSScriptRoot) { $source = Join-Path $PSScriptRoot "scripts\$Name" }

    if ($source -and (Test-Path -LiteralPath $source)) {
        Copy-Item -LiteralPath $source -Destination $Destination -Force
        Write-Host "installed  $Destination (from $source)"
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$repoRaw/scripts/$Name" -OutFile $Destination -UseBasicParsing
        Write-Host "installed  $Destination (downloaded)"
    }
}

Install-Script 'statusline.ps1' $target
if (-not $NoMascot) { Install-Script 'mascot-hook.ps1' $hookTarget }

# Forward slashes keep the JSON free of escaped backslashes.
$commandPath = $target -replace '\\', '/'
$command = "powershell -NoProfile -ExecutionPolicy Bypass -File $commandPath"
$hookPath = $hookTarget -replace '\\', '/'

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
$statusLine | Add-Member -MemberType NoteProperty -Name 'refreshInterval' -Value 3

if ($data.PSObject.Properties.Name -contains 'statusLine') {
    $data.statusLine = $statusLine
} else {
    $data | Add-Member -MemberType NoteProperty -Name 'statusLine' -Value $statusLine
}

# Registers one mascot hook, dropping any earlier copy of it so re-running the
# installer never stacks duplicates. Hooks belonging to anything else are kept
# exactly as they were.
function Set-MascotHook {
    param($Root, [string]$EventName, [string]$State)

    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $hookPath -State $State"

    $kept = @()
    if ($Root.PSObject.Properties.Name -contains $EventName) {
        foreach ($group in @($Root.$EventName)) {
            $ours = $false
            foreach ($h in @($group.hooks)) {
                if ("$($h.command)" -like '*mascot-hook*') { $ours = $true }
            }
            if (-not $ours) { $kept += $group }
        }
    }

    $hook = New-Object PSObject
    $hook | Add-Member -MemberType NoteProperty -Name 'type' -Value 'command'
    $hook | Add-Member -MemberType NoteProperty -Name 'command' -Value $cmd

    $grp = New-Object PSObject
    $grp | Add-Member -MemberType NoteProperty -Name 'hooks' -Value @($hook)
    $kept += $grp

    if ($Root.PSObject.Properties.Name -contains $EventName) {
        $Root.$EventName = @($kept)
    } else {
        $Root | Add-Member -MemberType NoteProperty -Name $EventName -Value @($kept)
    }
}

if (-not $NoMascot) {
    if (-not ($data.PSObject.Properties.Name -contains 'hooks')) {
        $data | Add-Member -MemberType NoteProperty -Name 'hooks' -Value (New-Object PSObject)
    }
    Set-MascotHook $data.hooks 'UserPromptSubmit' 'working'
    Set-MascotHook $data.hooks 'Stop' 'done'
    Set-MascotHook $data.hooks 'StopFailure' 'error'
}

# settings.json must be UTF-8 without a BOM - a BOM breaks JSON.parse.
$json = $data | ConvertTo-Json -Depth 32
[System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "configured $settings"
Write-Host ''
Write-Host 'Done. Restart Claude Code (or open a new session) to see the status line.'
