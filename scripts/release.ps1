<#
.SYNOPSIS
  Builds everything a Velora release needs into dist/, ready to attach to a
  GitHub release by hand.

.DESCRIPTION
  Every installed copy checks
    https://github.com/siamahnaf/velora/releases/latest/download/latest.json
  so each release must carry that file plus the files it names:

    dist/Velora_<v>_x64-setup.exe     the installer (updater fallback)
    dist/Velora_<v>_x64.zip           the in-place update payload
    dist/Velora_<v>_x64-portable.zip  the portable download
    dist/latest.json                  the manifest, with both signatures

  The release tag must be v<version> (e.g. v1.3.0), the version being the one
  in src-tauri/tauri.conf.json — latest.json's URLs point at that tag.

  Signing uses TAURI_SIGNING_PRIVATE_KEY if set, otherwise
  %USERPROFILE%\.tauri\velora.key. The key has no password.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/release.ps1
#>
# 'Continue', not 'Stop': Windows PowerShell turns every stderr line of a native
# command into an error record, and bun/cargo report progress on stderr.
# Failures are caught by $LASTEXITCODE and the checks below instead.
$ErrorActionPreference = 'Continue'
# node prints UTF-8; read as the ANSI code page, "×" in the notes became "Ã—".
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = Split-Path -Parent $PSScriptRoot

# A terminal opened before the tools were installed does not have them yet.
foreach ($dir in @("$env:USERPROFILE\.bun\bin", "$env:USERPROFILE\.cargo\bin", "$env:ProgramFiles\nodejs", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer")) {
  if ((Test-Path $dir) -and ($env:PATH -notlike "*$dir*")) { $env:PATH = "$dir;$env:PATH" }
}
Set-Location $root

$repo = 'siamahnaf/velora'
$version = (Get-Content src-tauri/tauri.conf.json -Raw | ConvertFrom-Json).version
Write-Host "Velora $version" -ForegroundColor Cyan

# The MSVC environment: bindgen (FFmpeg bindings) needs its INCLUDE paths, and a
# plain shell does not have them.
if (-not $env:INCLUDE) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $vs) { throw 'Visual Studio C++ Build Tools not found.' }
  $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
  cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] }
  }
}

$key = if ($env:TAURI_SIGNING_PRIVATE_KEY) { $env:TAURI_SIGNING_PRIVATE_KEY } else { Join-Path $env:USERPROFILE '.tauri\velora.key' }
if (-not $env:TAURI_SIGNING_PRIVATE_KEY -and -not (Test-Path $key)) { throw "No signing key at $key" }
# The contents, not the path: `tauri signer sign` reads this as the key itself.
$env:TAURI_SIGNING_PRIVATE_KEY = if (Test-Path $key) { (Get-Content $key -Raw).Trim() } else { $key }
# CI mode: Windows cannot hold an empty environment variable, so an empty
# password reads as "not set" and the build would stop to ask for one.
$env:CI = 'true'

function Sign([string]$file) {
  # `--password=` rather than `-p ""`: Windows PowerShell drops empty arguments.
  # The key comes from TAURI_SIGNING_PRIVATE_KEY, set above; passing `-f` as
  # well is refused as two keys.
  bun run tauri signer sign '--password=' $file | Out-Null
  if (-not (Test-Path "$file.sig")) { throw "signing $file failed" }
}

$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Path $dist | Out-Null

Write-Host 'Building...' -ForegroundColor Cyan
bun run tauri build --ci
if ($LASTEXITCODE -ne 0) { throw "tauri build failed ($LASTEXITCODE)" }

$exe = Get-ChildItem 'src-tauri/target/release/bundle/nsis/*-setup.exe' | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not (Test-Path "$($exe.FullName).sig")) { Sign $exe.FullName }
$setup = "Velora_${version}_x64-setup.exe"
Copy-Item $exe.FullName (Join-Path $dist $setup)
$setupSig = (Get-Content "$($exe.FullName).sig" -Raw).Trim()

Write-Host 'Packing the update and portable zips...' -ForegroundColor Cyan
$work = Join-Path $env:TEMP "velora-release-$version"
if (Test-Path $work) { Remove-Item $work -Recurse -Force -Confirm:$false }
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-windows-update.ps1 -Version $version -OutDir $work
if ($LASTEXITCODE -ne 0) { throw 'packing the update payload failed' }
$zipName = "Velora_${version}_x64.zip"
Sign (Join-Path $work $zipName)
Copy-Item (Join-Path $work $zipName) $dist
$zipSig = (Get-Content (Join-Path $work "$zipName.sig") -Raw).Trim()

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-windows-update.ps1 -Version $version -OutDir $work -Portable
if ($LASTEXITCODE -ne 0) { throw 'packing the portable download failed' }
Copy-Item (Join-Path $work "Velora_${version}_x64-portable.zip") $dist

$notes = ''
if (Test-Path "changelog/$version.md") { $notes = (node scripts/changelog.mjs notes $version) -join "`n" }
$base = "https://github.com/$repo/releases/download/v$version"
$manifest = [ordered]@{
  version   = $version
  notes     = $notes
  pub_date  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  platforms = [ordered]@{
    'windows-x86_64'     = [ordered]@{ signature = $setupSig; url = "$base/$setup" }
    'windows-x86_64-zip' = [ordered]@{ signature = $zipSig; url = "$base/$zipName" }
  }
}
# Without a BOM: the updater's JSON parser rejects one.
[System.IO.File]::WriteAllText((Join-Path $dist 'latest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
if ($notes) { [System.IO.File]::WriteAllText((Join-Path $dist 'notes.md'), $notes, (New-Object System.Text.UTF8Encoding $false)) }

Write-Host ''
Write-Host "Done. Create a GitHub release with tag v$version and attach everything in dist\ except notes.md:" -ForegroundColor Green
Get-ChildItem $dist | ForEach-Object { Write-Host "  $($_.Name)" }
if ($notes) { Write-Host 'dist\notes.md holds the release description.' }
