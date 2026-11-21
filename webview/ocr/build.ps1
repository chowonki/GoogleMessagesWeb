# Builds assets\ocr\gm_ocr.exe (the image text-recognition helper) from GmOcr.cs.
# Needs: .NET Framework C# compiler (ships with Windows) and the Windows 10/11 SDK (for Windows.winmd).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$fx  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $fx 'csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }

$winmd = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\UnionMetadata" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[0-9]' -and (Test-Path (Join-Path $_.FullName 'Windows.winmd')) } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $winmd) { throw 'Windows SDK (Windows.winmd) not found.' }

$out = Join-Path $PSScriptRoot '..\assets\ocr'
New-Item -ItemType Directory -Force $out | Out-Null
& $csc /nologo /target:winexe /optimize+ /codepage:65001 /platform:x64 `
    "/r:$(Join-Path $winmd.FullName 'Windows.winmd')" `
    "/r:$fx\System.Runtime.WindowsRuntime.dll" "/r:$fx\System.Runtime.dll" `
    "/r:$fx\System.Runtime.InteropServices.WindowsRuntime.dll" `
    "/out:$out\gm_ocr.exe" GmOcr.cs
if ($LASTEXITCODE -ne 0) { throw 'Compile failed.' }
Write-Output "Built $out\gm_ocr.exe"
