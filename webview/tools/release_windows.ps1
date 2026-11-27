# Windows 설치 파일을 이 PC에서 빌드하고 v<버전> 릴리스에 올린다.
#   dist\GoogleMessagesWeb-Setup-<버전>.exe       (Inno Setup 6)
#   dist\GoogleMessagesWeb-<버전>.msi             (WiX 5 가 있을 때만)
#   dist\GoogleMessagesWeb-Portable-<버전>.zip
# macOS dmg 는 main 에 합쳤을 때 Actions(Release 워크플로)가 같은 릴리스에 올린다.
# 먼저 끝난 쪽이 초안 릴리스를 만들고, exe 와 dmg 가 모두 모이면 게시된다.
#
#   tools\release_windows.ps1             빌드 + 업로드 (main 과 같은 커밋에서만)
#   tools\release_windows.ps1 -NoUpload   빌드만
#   tools\release_windows.ps1 -Yes        없는 도구를 묻지 않고 설치
# 필요한 도구(Inno Setup, WiX)가 없으면 설치할지 물어보고 설치한다.
param(
    [switch]$NoUpload,
    [switch]$SkipBuild,
    [switch]$Yes
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

# 없는 도구를 설치할지 묻는다. 답할 수 없는(대화형이 아닌) 실행에서는 설치하지 않는다.
function Confirm-Install([string]$what) {
    if ($Yes) { return $true }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Write-Warning "$what 이(가) 없습니다. 설치하려면 -Yes 를 붙여 다시 실행하세요."
        return $false
    }
    $answer = Read-Host "$what 이(가) 없습니다. 지금 설치할까요? [Y/n]"
    return ($answer -eq '' -or $answer -match '^(y|yes|ㅛ|네|예)$')
}

function Find-Iscc {
    @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Find-Wix {
    $cmd = Get-Command wix -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = "$env:USERPROFILE\.dotnet\tools\wix.exe"
    if (Test-Path $local) { return $local }
    return $null
}

# Inno Setup 6 (exe 설치 파일). 없으면 winget 으로 현재 사용자에게 설치한다.
function Get-Iscc {
    $iscc = Find-Iscc
    if ($iscc) { return $iscc }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Inno Setup 6 이 없고 winget 도 없습니다. https://jrsoftware.org/isdl.php 에서 설치하세요.' }
    if (-not (Confirm-Install 'Inno Setup 6 (winget: JRSoftware.InnoSetup)')) { throw 'Inno Setup 6 이 없어 exe 설치 파일을 만들 수 없습니다.' }
    winget install --id JRSoftware.InnoSetup -e --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity
    $iscc = Find-Iscc
    if (-not $iscc) { throw 'Inno Setup 6 을 설치했지만 ISCC.exe 를 찾지 못했습니다.' }
    return $iscc
}

# WiX 5 (MSI). 없으면 dotnet 도구로 설치한다. 설치하지 않으면 MSI 만 건너뛴다.
function Get-Wix {
    $wix = Find-Wix
    if ($wix) { return $wix }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Warning 'WiX 가 없고 .NET SDK 도 없어 MSI 는 만들지 않습니다.'
        return $null
    }
    if (-not (Confirm-Install 'WiX 5.0.2 (dotnet tool, nuget.org)')) {
        Write-Warning 'WiX 를 설치하지 않아 MSI 는 만들지 않습니다.'
        return $null
    }
    dotnet tool install --global wix --version 5.0.2
    if ($LASTEXITCODE -ne 0) { throw 'WiX 설치 실패' }
    return Find-Wix
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter 가 없습니다. https://docs.flutter.dev/get-started/install/windows 에서 설치한 뒤 PATH 에 넣으세요.'
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
    # 도구는 오래 걸리는 빌드 전에 먼저 갖춘다
    $iscc = Get-Iscc
    $wix = Get-Wix

    Invoke-Step 'flutter pub get' { flutter pub get }
    # 증분 빌드는 WebView 플러그인에서 실패하므로 매번 지운다
    Remove-Item -Recurse -Force build\windows -ErrorAction SilentlyContinue
    Invoke-Step 'flutter build windows' { flutter build windows --release }

    New-Item -ItemType Directory -Force $dist | Out-Null
    Get-ChildItem $dist -File -Filter 'GoogleMessagesWeb-*' | Remove-Item -Force

    Invoke-Step 'Inno Setup' { & $iscc /Q "/DAppVersion=$version" installer\windows.iss }
    if ($wix) {
        Invoke-Step 'MSI (WiX)' { & $wix build installer\windows.wxs -arch x64 -d "Version=$version" -o "$dist\GoogleMessagesWeb-$version.msi" }
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
