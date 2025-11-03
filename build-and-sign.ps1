<#
build-and-sign.ps1
Creates a reproducible-ish build of a PowerShell script into a Windows EXE using PS2EXE,
optionally signs it with a PFX (Authenticode) using signtool, and writes checksums + manifest.


Usage (examples):


Run with defaults from inside project root

PowerShell -ExecutionPolicy Bypass -File .\build-and-sign.ps1


Specify source, pfx and signtool explicitly

PowerShell -ExecutionPolicy Bypass -File .\build-and-sign.ps1 -Source 'C:\path\to\project\yourScript.ps1' `
-PfxPath 'C:\path\to\project\certs\codesign.pfx' -SignToolPath 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe'


Notes:



This script expects the ps2exe module (Invoke-ps2exe) to be available. If offline, copy the module into
%UserProfile%\Documents\WindowsPowerShell\Modules\ps2exe<version>\ and Import-Module it.

Signing requires signtool.exe (Windows SDK) and a PFX. Installing the SDK requires admin.

To maximize reproducibility, run inside a pinned builder VM snapshot and provide BUILD_ID externally:
$env:BUILD_ID = '2025-11-01T00:00:00Z'
#>


param(
[string]$Source = 'C:\path\to\project\yourscript.fixed.ps1',
[string]$OutDir = 'C:\path\to\project\out',
[string]$UnsignedName = 'myapp.unsigned.exe',
[string]$SignedName = 'myapp.exe',
[string]$IconFile = 'C:\path\to\project\assets\app.ico',            # optional
[string]$PfxPath = 'C:\path\to\project\certs\codesign.pfx',         # optional: leave blank to skip signing
[string]$SignToolPath = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe', # optional
[switch]$AppendLegacySha1,      # append legacy SHA1 signature for XP compatibility (modifies file)
[switch]$Force                  # bypass some interactive checks
)


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Write-Log { param($m) Write-Host "[*] $m" }
function Write-Err { param($m) Write-Host "[!] $m" -ForegroundColor Red }


Normalize paths

$Source = (Resolve-Path -Path $Source -ErrorAction SilentlyContinue)?.ProviderPath
$OutDir = Resolve-Path -Path $OutDir -ErrorAction SilentlyContinue
if (-not $OutDir) { New-Item -Path $([System.IO.Path]::GetFullPath($OutDir)) -ItemType Directory -Force | Out-Null; $OutDir = Resolve-Path -Path $OutDir }
$OutDir = $OutDir.ProviderPath
$UnsignedPath = Join-Path $OutDir $UnsignedName
$SignedPath   = Join-Path $OutDir $SignedName


BUILD_ID for deterministic metadata (set externally to reproduce)

if (-not $env:BUILD_ID) { $env:BUILD_ID = 'UNSPECIFIED' }
$BuildId = $env:BUILD_ID


Validate source

if (-not $Source -or -not (Test-Path $Source)) {
Write-Err "Source PS1 not found at '$Source'. Use -Source to point to an existing .ps1."
Write-Err "Files in project root (.ps1):"
Get-ChildItem -Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) -Filter '.ps1' -Recurse -File -ErrorAction SilentlyContinue |
Select-Object -First 100 FullName | ForEach-Object { Write-Host "  $_" }
exit 2
}
Write-Log "Using source: $Source"
Write-Log "Output directory: $OutDir"


Ensure ps2exe available

try {
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
Write-Log "ps2exe not loaded - attempting to Import-Module ps2exe"
Import-Module ps2exe -ErrorAction Stop
}
Get-Command Invoke-ps2exe -ErrorAction Stop | Out-Null
} catch {
Write-Err "ps2exe module not available. Install it or copy module to your user modules path."
Write-Err "If offline: on an internet machine run 'Save-Module -Name ps2exe -Path C:\temp\psmodules' and copy the result to %UserProfile%\Documents\WindowsPowerShell\Modules\ps2exe\."
exit 3
}


Prepare normalized source copy (embed BUILD_ID deterministically)

$NormalizedSource = Join-Path $OutDir 'main.normalized.ps1'
$Header = "# BUILD_ID: $BuildIdn# BuilderSnapshot: builder-v1n"


Read original and write normalized file (UTF8 without BOM)

$origText = Get-Content -Path $Source -Raw -ErrorAction Stop
[System.IO.File]::WriteAllText($NormalizedSource, $Header + $origText, [System.Text.Encoding]::UTF8)
Write-Log "Wrote normalized source to: $NormalizedSource"


Compile to unsigned EXE

Write-Log "Compiling normalized source to unsigned EXE: $UnsignedPath"
if (Test-Path $UnsignedPath) { Remove-Item $UnsignedPath -Force -ErrorAction SilentlyContinue }
$ps2exeParams = @{
InputFile  = $NormalizedSource
OutputFile = $UnsignedPath
NoConsole  = $true
x86        = $true
Verbose    = $true
}
if (Test-Path $IconFile) { $ps2exeParams.IconFile = $IconFile }
Invoke-ps2exe @ps2exeParams


if (-not (Test-Path $UnsignedPath)) {
Write-Err "Compilation failed: unsigned EXE not found at $UnsignedPath"
exit 4
}
Write-Log "Compilation OK: $UnsignedPath"


Pre-sign checksum

$preHash = Get-FileHash -Path $UnsignedPath -Algorithm SHA256
$preHash.Hash | Out-File -FilePath (Join-Path $OutDir 'checksum.unsigned.sha256.txt') -Encoding ascii
Write-Log "Unsigned SHA256: $($preHash.Hash)"


Signing (optional)

$DidSign = $false
if ($PfxPath -and (Test-Path $PfxPath) -and $SignToolPath -and (Test-Path $SignToolPath)) {
Write-Log "Signing prerequisites found. Will sign artifact."


Securely prompt

$securePwd = Read-Host -AsSecureString "PFX password (input hidden)"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
$pfxPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)


Copy unsigned to signed filename to sign in place

Copy-Item -Path $UnsignedPath -Destination $SignedPath -Force


Primary SHA256 + RFC3161 timestamp

$signCmd = & "$SignToolPath" sign /fd SHA256 /f "$PfxPath" /p $pfxPassPlain /tr http://timestamp.digicert.com /td SHA256 /v "$SignedPath"
if ($LASTEXITCODE -ne 0) {
Write-Err "signtool returned exit code $LASTEXITCODE during primary sign. Output:"
Write-Host $signCmd
# keep going to allow troubleshooting
} else {
Write-Log "Primary SHA256 signature applied."
$DidSign = $true
}


Optional: append legacy SHA1 signature for XP

if ($AppendLegacySha1) {
Write-Log "Appending legacy SHA1 signature for XP compatibility."
$legacyCmd = & "$SignToolPath" sign /fd SHA1 /f "$PfxPath" /p $pfxPassPlain /t http://timestamp.verisign.com/scripts/timstamp.dll /as /v "$SignedPath"
if ($LASTEXITCODE -ne 0) {
Write-Err "signtool exit code $LASTEXITCODE during legacy append."
Write-Host $legacyCmd
} else {
Write-Log "Legacy SHA1 signature appended."
}
}


Verify

Write-Log "Verifying signature..."
& "$SignToolPath" verify /pa /v "$SignedPath" 2>&1 | Tee-Object -FilePath (Join-Path $OutDir 'signtool.verify.log')


Clear plaintext

$pfxPassPlain = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()
} else {
if (-not $PfxPath) { Write-Log "No PfxPath provided — skipping signing." }
elseif (-not (Test-Path $PfxPath)) { Write-Log "PFX not found at $PfxPath — skipping signing." }
elseif (-not (Test-Path $SignToolPath)) { Write-Log "signtool not found at $SignToolPath — skipping signing." }
}


Post-sign checksums

if ($DidSign -and (Test-Path $SignedPath)) {
$finalHash = Get-FileHash -Path $SignedPath -Algorithm SHA256
$finalHash.Hash | Out-File -FilePath (Join-Path $OutDir 'checksum.signed.sha256.txt') -Encoding ascii
Write-Log "Signed SHA256: $($finalHash.Hash)"
} else {


fall back to unsigned artifact

$finalHash = Get-FileHash -Path $UnsignedPath -Algorithm SHA256
$finalHash.Hash | Out-File -FilePath (Join-Path $OutDir 'checksum.unsigned.sha256.txt') -Encoding ascii
Write-Log "Unsigned final SHA256: $($finalHash.Hash)"
}


Write manifest

$manifest = @{
build_id = $BuildId
source = $Source
normalized_source = $NormalizedSource
unsigned = $UnsignedPath
signed = (if (Test-Path $SignedPath) { $SignedPath } else { $null })
did_sign = $DidSign
append_legacy_sha1 = $AppendLegacySha1.IsPresent
unsigned_sha256 = (Get-FileHash -Path $UnsignedPath -Algorithm SHA256).Hash
signed_sha256 = (if (Test-Path $SignedPath) { (Get-FileHash -Path $SignedPath -Algorithm SHA256).Hash } else { $null })
timestamp = (Get-Date).ToString("o")
ps_version = $PSVersionTable.PSVersion.ToString()
signToolPath = (if ($SignToolPath) { $SignToolPath } else { $null })
pfx_path = (if ($PfxPath) { $PfxPath } else { $null })
}
$manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $OutDir 'build.manifest.json') -Encoding utf8


Write-Log "Build complete. Artifacts in: $OutDir"
if ($DidSign -and (Test-Path $SignedPath)) { Write-Host "`nSigned artifact: $SignedPath" }
Write-Host "Unsigned artifact: $UnsignedPath"
Write-Host "Manifest: $(Join-Path $OutDir 'build.manifest.json')"


End of script.

