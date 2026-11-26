# 포터블 버전을 만든다 → dist\GoogleMessagesWeb-Portable-<버전>.zip
#   GoogleMessagesWeb-Portable\
#     GoogleMessagesWeb.exe   실행 파일 (Launcher.cs)
#     App\                    프로그램 (flutter build windows --release 결과 + portable 표시 파일)
#     Data\                   설정·로그인 정보 (처음에는 비어 있다)
# 먼저 `flutter build windows --release` 를 해 두어야 한다.
# 필요한 것: .NET Framework C# 컴파일러 (Windows 에 들어 있음).
param([string]$Version)
$ErrorActionPreference = 'Stop'
$web = Split-Path $PSScriptRoot -Parent

if (-not $Version) {
    $Version = (Select-String -Path (Join-Path $web 'pubspec.yaml') -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
}
$release = Join-Path $web 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'google_messages_web.exe'))) {
    throw "빌드 결과가 없습니다: $release (먼저 flutter build windows --release)"
}
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }

$dist = Join-Path $web 'dist'
$stage = Join-Path $dist 'portable'
$root = Join-Path $stage 'GoogleMessagesWeb-Portable'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $root 'App'), (Join-Path $root 'Data') | Out-Null

Copy-Item (Join-Path $release '*') (Join-Path $root 'App') -Recurse
# 이 파일이 있으면 앱이 포터블 모드로 동작한다 (lib/portable.dart)
Set-Content -Path (Join-Path $root 'App\portable') -Value 'portable' -Encoding ascii

$parts = "$Version.0.0.0".Split('.')[0..3] -join '.'
$versionFile = Join-Path $stage 'Version.cs'
Set-Content -Path $versionFile -Encoding utf8 -Value @"
[assembly: System.Reflection.AssemblyVersion("$parts")]
[assembly: System.Reflection.AssemblyFileVersion("$parts")]
[assembly: System.Reflection.AssemblyInformationalVersion("$Version")]
"@
& $csc /nologo /target:winexe /optimize+ /codepage:65001 /platform:x64 `
    "/win32icon:$(Join-Path $web 'windows\runner\resources\app_icon.ico')" `
    "/out:$(Join-Path $root 'GoogleMessagesWeb.exe')" `
    (Join-Path $PSScriptRoot 'Launcher.cs') $versionFile
if ($LASTEXITCODE -ne 0) { throw 'Compile failed.' }
Remove-Item $versionFile

$zip = Join-Path $dist "GoogleMessagesWeb-Portable-$Version.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression.FileSystem
# 폴더째 넣는다 (빈 Data 폴더도 들어간다)
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $root, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
Write-Output "Built $zip"
