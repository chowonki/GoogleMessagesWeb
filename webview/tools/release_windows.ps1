# Windows 설치 파일을 이 PC에서 빌드하고 v<버전> 릴리스에 올린다.
#   dist\GoogleMessagesWeb-Setup-<버전>.exe       (Inno Setup 6)
#   dist\GoogleMessagesWeb-<버전>.msi             (WiX 5 가 있을 때만)
#   dist\GoogleMessagesWeb-Portable-<버전>.zip
# macOS dmg 는 main 에 합쳤을 때 Actions(Release 워크플로)가 같은 릴리스에 올린다.
# 먼저 끝난 쪽이 초안 릴리스를 만들고, exe 와 dmg 가 모두 모이면 게시된다.
#
#   tools\release_windows.ps1             빌드 + 업로드 (main 과 같은 커밋에서만)
#   tools\release_windows.ps1 -NoUpload   빌드만
param(
    [switch]$NoUpload,
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$web = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $web -Parent
Set-Location $web

function Invoke-Step([string]$name, [scriptblock]$body) {
    Write-Host "== $name" -ForegroundColor Cyan
    & $body
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$name 실패 (exit $LASTEXITCODE)" }
}

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$tag = "v$version"
Write-Host "버전 $version"

if (-not $NoUpload) {
    # 릴리스 파일은 main 에 들어간 커밋으로만 만든다
    git -C $repo fetch -q origin main
    $head = (git -C $repo rev-parse HEAD).Trim()
    $main = (git -C $repo rev-parse origin/main).Trim()
    if ($head -ne $main) { throw "지금 커밋($($head.Substring(0,7)))이 origin/main($($main.Substring(0,7)))과 다릅니다. main 을 받아 온 뒤 다시 실행하세요." }
    $dirty = git -C $repo status --porcelain -- webview packages .github | Where-Object { $_ -notmatch 'generated_plugin|GeneratedPluginRegistrant' }
    if ($dirty) { throw "커밋하지 않은 변경이 있습니다:`n$($dirty -join "`n")" }
    $state = gh release view $tag --json isDraft --jq .isDraft 2>$null
    if ($state -eq 'false') { throw "$tag 은 이미 게시되었습니다. 버전을 올린 뒤 다시 실행하세요." }
}

$dist = Join-Path $web 'dist'
if (-not $SkipBuild) {
    Invoke-Step 'flutter pub get' { flutter pub get }
    # 증분 빌드는 WebView 플러그인에서 실패하므로 매번 지운다
    Remove-Item -Recurse -Force build\windows -ErrorAction SilentlyContinue
    Invoke-Step 'flutter build windows' { flutter build windows --release }

    New-Item -ItemType Directory -Force $dist | Out-Null
    Get-ChildItem $dist -File -Filter 'GoogleMessagesWeb-*' | Remove-Item -Force

    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) 이 없습니다.' }
    Invoke-Step 'Inno Setup' { & $iscc /Q "/DAppVersion=$version" installer\windows.iss }

    $wix = Get-Command wix -ErrorAction SilentlyContinue
    if (-not $wix -and (Test-Path "$env:USERPROFILE\.dotnet\tools\wix.exe")) { $wix = "$env:USERPROFILE\.dotnet\tools\wix.exe" }
    if ($wix) {
        Invoke-Step 'MSI (WiX)' { & $wix build installer\windows.wxs -arch x64 -d "Version=$version" -o "$dist\GoogleMessagesWeb-$version.msi" }
    } else {
        Write-Warning 'WiX 가 없어 MSI 는 만들지 않습니다. (dotnet tool install --global wix --version 5.0.2)'
    }

    Invoke-Step '포터블' { & (Join-Path $web 'portable\build.ps1') -Version $version }
}

$files = Get-ChildItem $dist -File | Where-Object {
    $_.Name -in @("GoogleMessagesWeb-Setup-$version.exe", "GoogleMessagesWeb-$version.msi", "GoogleMessagesWeb-Portable-$version.zip")
}
$files | Format-Table Name, Length -AutoSize | Out-Host
if (-not ($files | Where-Object Name -eq "GoogleMessagesWeb-Setup-$version.exe")) { throw 'exe 설치 파일이 없습니다.' }
if ($NoUpload) { Write-Host '빌드만 했습니다 (-NoUpload).'; return }

$paths = $files.FullName
gh release view $tag *> $null
if ($LASTEXITCODE -eq 0) {
    Invoke-Step "업로드 ($tag)" { gh release upload $tag @paths --clobber }
} else {
    Invoke-Step "초안 릴리스 만들기 ($tag)" {
        gh release create $tag @paths --draft --target $main `
            --title "Google 메시지 웹 $tag" --notes-file (Join-Path $repo '.github\release-notes.md')
    }
}

$assets = gh release view $tag --json assets --jq '.assets[].name'
if ($assets -contains "GoogleMessagesWeb-$version.dmg") {
    Invoke-Step "게시 ($tag)" { gh release edit $tag --draft=false --latest }
    Write-Host "$tag 을 게시했습니다."
} else {
    Write-Host "$tag 초안에 Windows 파일을 올렸습니다. Actions 가 dmg 를 올리면 게시됩니다."
}
