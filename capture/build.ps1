# Builds dist\ScreenCapture.exe from src\*.cs.
# Needs only the .NET Framework C# compiler that ships with Windows (no SDK install).
param([switch]$Test)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$fx  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $fx 'csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }

New-Item -ItemType Directory -Force dist | Out-Null

if ($Test) {
    & $csc /nologo /codepage:65001 /out:dist\stitch_test.exe src\Stitcher.cs test\StitchTest.cs
    if ($LASTEXITCODE -ne 0) { throw 'Test compile failed.' }
    & dist\stitch_test.exe
    if ($LASTEXITCODE -ne 0) { throw 'Stitch test failed.' }
}

$sources = Get-ChildItem src\*.cs | ForEach-Object { $_.FullName }
& $csc /nologo /target:winexe /optimize+ /codepage:65001 /platform:x64 `
    /win32manifest:app.manifest `
    /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
    /out:dist\ScreenCapture.exe $sources
if ($LASTEXITCODE -ne 0) { throw 'Compile failed.' }
Write-Output "Built $PSScriptRoot\dist\ScreenCapture.exe"
