#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# Antigravity Tools 自动更新脚本 - Windows 版
# =============================================================================

# 配置常量
$REPO = "lbjlaq/Antigravity-Manager"
$APP_NAME = "Antigravity Tools"
$DEFAULT_INSTALL_DIR = Join-Path $env:LOCALAPPDATA $APP_NAME
$DEFAULT_EXE_PATH = Join-Path $DEFAULT_INSTALL_DIR "${APP_NAME}.exe"
$TMP_DIR = Join-Path $env:TEMP "antigravity-updater-$PID"
$API_LATEST = "https://api.github.com/repos/$REPO/releases/latest"
$CURL_TIMEOUT = 30
$MIN_FREE_SPACE_MB = 500

# =============================================================================
# 工具函数
# =============================================================================

function Write-ColorText {
    param(
        [string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Write-Host $Text -ForegroundColor $Color
}

# 语义化版本比较(返回 $true 表示 $Ver1 > $Ver2)
function Test-VersionGreaterThan {
    param([string]$Ver1, [string]$Ver2)
    if ($Ver1 -eq $Ver2) { return $false }
    try {
        $v1 = [System.Version]::new($Ver1)
        $v2 = [System.Version]::new($Ver2)
        return $v1 -gt $v2
    }
    catch {
        # 回退到字符串逐段比较
        $parts1 = $Ver1.Split('.')
        $parts2 = $Ver2.Split('.')
        $maxLen = [Math]::Max($parts1.Length, $parts2.Length)
        for ($i = 0; $i -lt $maxLen; $i++) {
            $p1 = if ($i -lt $parts1.Length) { [int]$parts1[$i] } else { 0 }
            $p2 = if ($i -lt $parts2.Length) { [int]$parts2[$i] } else { 0 }
            if ($p1 -gt $p2) { return $true }
            if ($p1 -lt $p2) { return $false }
        }
        return $false
    }
}

# 读取已安装版本(从注册表或文件版本信息)
function Get-InstalledVersion {
    # 1. 尝试注册表(卸载信息)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            $entry = Get-ChildItem $regPath -ErrorAction SilentlyContinue |
                Get-ItemProperty -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*$APP_NAME*" } |
                Select-Object -First 1
            if ($entry -and $entry.DisplayVersion) {
                return @{ Version = $entry.DisplayVersion; Path = $entry.InstallLocation }
            }
        }
    }

    # 2. 尝试从默认安装路径读取文件版本
    if (Test-Path $DEFAULT_EXE_PATH) {
        try {
            $fileVer = (Get-Item $DEFAULT_EXE_PATH).VersionInfo.ProductVersion
            if ($fileVer) {
                return @{ Version = $fileVer; Path = $DEFAULT_INSTALL_DIR }
            }
        }
        catch { }
    }

    # 3. 扫描常见安装目录
    $searchDirs = @(
        (Join-Path $env:ProgramFiles $APP_NAME),
        (Join-Path ${env:ProgramFiles(x86)} $APP_NAME),
        (Join-Path $env:LOCALAPPDATA $APP_NAME)
    )
    foreach ($dir in $searchDirs) {
        $exe = Join-Path $dir "${APP_NAME}.exe"
        if (Test-Path $exe) {
            try {
                $fileVer = (Get-Item $exe).VersionInfo.ProductVersion
                return @{ Version = $fileVer; Path = $dir }
            }
            catch { }
        }
    }

    return $null
}

# 检查磁盘空间
function Test-DiskSpace {
    $drive = (Get-Item $env:LOCALAPPDATA).PSDrive
    $freeGB = (Get-PSDrive $drive.Name).Free / 1MB
    if ($freeGB -lt $MIN_FREE_SPACE_MB) {
        Write-ColorText "❌ 磁盘空间不足(需要${MIN_FREE_SPACE_MB}MB，当前$([math]::Round($freeGB))MB)" Red
        exit 1
    }
}

# 选择下载URL(根据架构优先级匹配)
function Find-DownloadUrl {
    param(
        [object]$Release,
        [string]$Pattern
    )
    foreach ($asset in $Release.assets) {
        if ($asset.browser_download_url -match $Pattern) {
            return $asset.browser_download_url
        }
    }
    return $null
}

# 显示更新日志
function Show-ReleaseNotes {
    param(
        [object]$Release,
        [string]$OldVer,
        [string]$NewVer
    )
    Write-Host ""
    Write-ColorText "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" Cyan
    $oldDisplay = if ($OldVer) { "v$OldVer" } else { "无" }
    Write-ColorText "📋 版本更新日志: $oldDisplay → v$NewVer" Cyan
    Write-ColorText "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" Cyan

    if ($Release.body) {
        $lines = $Release.body -split "`n" | Select-Object -First 20
        $lines | ForEach-Object { Write-Host $_ }
        Write-Host ""
    }
    else {
        Write-Host "未找到更新说明，访问完整发布页:"
        Write-Host "https://github.com/$REPO/releases/latest"
        Write-Host ""
    }

    Write-ColorText "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" Cyan
    Write-Host ""
}

# 安装应用(MSI/NSIS/ZIP)
function Install-Application {
    param([string]$FilePath)

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()

    switch ($ext) {
        ".msi" {
            Write-ColorText "📦 执行 MSI 安装..." Green
            $logFile = Join-Path $TMP_DIR "install.log"
            $proc = Start-Process "msiexec.exe" -ArgumentList "/i", "`"$FilePath`"", "/qb", "/norestart", "/l*v", "`"$logFile`"" -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Write-ColorText "❌ MSI 安装失败(退出码: $($proc.ExitCode))" Red
                Write-Host "查看日志: $logFile"
                exit 1
            }
        }
        ".exe" {
            Write-ColorText "📦 执行 EXE 安装..." Green
            # NSIS 静默安装常用参数
            $proc = Start-Process $FilePath -ArgumentList "/S", "/D=$DEFAULT_INSTALL_DIR" -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Write-ColorText "❌ EXE 安装失败(退出码: $($proc.ExitCode))" Red
                exit 1
            }
        }
        ".zip" {
            Write-ColorText "📦 解压 ZIP 安装包..." Green
            $extractDir = Join-Path $TMP_DIR "extracted"
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
            Expand-Archive -Path $FilePath -DestinationPath $extractDir -Force

            # 在解压目录中查找 exe
            $foundExe = Get-ChildItem $extractDir -Recurse -Filter "${APP_NAME}.exe" | Select-Object -First 1
            if (-not $foundExe) {
                Write-ColorText "❌  未在压缩包中找到 ${APP_NAME}.exe" Red
                Write-Host "目录内容:"
                Get-ChildItem $extractDir -Recurse | ForEach-Object { Write-Host "  $_" }
                exit 1
            }

            # 复制到安装目录
            $sourceDir = $foundExe.DirectoryName
            if (Test-Path $DEFAULT_INSTALL_DIR) {
                Remove-Item $DEFAULT_INSTALL_DIR -Recurse -Force
            }
            New-Item -ItemType Directory -Path $DEFAULT_INSTALL_DIR -Force | Out-Null
            Copy-Item "$sourceDir\*" $DEFAULT_INSTALL_DIR -Recurse -Force

            Write-ColorText "✅ 已安装至: $DEFAULT_INSTALL_DIR" Green
        }
        default {
            Write-ColorText "❌ 不支持的安装包格式: $ext" Red
            exit 1
        }
    }
}

# =============================================================================
# 主逻辑
# =============================================================================

try {
    if (Test-Path $TMP_DIR) { Remove-Item $TMP_DIR -Recurse -Force }
    New-Item -ItemType Directory -Path $TMP_DIR -Force | Out-Null

    # ---------- 1) 获取最新版本信息 ----------
    Write-ColorText "🔎 检查 GitHub 最新版本..." Cyan

    try {
        # TLS 1.2 强制启用(旧版 Windows 可能未默认开启)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri $API_LATEST -TimeoutSec $CURL_TIMEOUT -UseBasicParsing
    }
    catch {
        Write-ColorText "❌ 网络请求失败(超时${CURL_TIMEOUT}s)，请检查网络或稍后重试" Red
        Write-Host "错误详情: $($_.Exception.Message)"
        exit 1
    }

    $LATEST_TAG = $release.tag_name
    if (-not $LATEST_TAG) {
        Write-ColorText "❌ 无法解析 tag_name，API响应异常" Red
        exit 1
    }

    $LATEST_VER = $LATEST_TAG -replace '^v', ''
    Write-Host "📦 GitHub最新版本: " -NoNewline
    Write-ColorText $LATEST_TAG Green

    # ---------- 2) 获取本地已安装版本 ----------
    $installed = Get-InstalledVersion
    $INSTALLED_VER = ""

    if ($installed) {
        $INSTALLED_VER = $installed.Version
        if ($INSTALLED_VER) {
            Write-Host "💻 本地安装版本: " -NoNewline
            Write-ColorText "v$INSTALLED_VER" Yellow -NoNewline
            Write-Host "  ($($installed.Path))"
        }
        else {
            Write-ColorText "💻 本地应用存在但版本号不可读取: $($installed.Path)" Yellow
        }
    }
    else {
        Write-Host "💻 本地安装版本: " -NoNewline
        Write-ColorText "(未检测到)" Yellow
    }

    # ---------- 3) 版本比较与决策 ----------
    if ($INSTALLED_VER -and -not (Test-VersionGreaterThan $LATEST_VER $INSTALLED_VER)) {
        Write-Host ""
        Write-ColorText "✅ 已是最新版本，无需更新" Green
        exit 0
    }

    # 展示更新日志
    Show-ReleaseNotes -Release $release -OldVer $INSTALLED_VER -NewVer $LATEST_VER

    # 确认安装/更新
    $actionText = if ($INSTALLED_VER) { "更新" } else { "安装" }
    $oldDisplay = if ($INSTALLED_VER) { "v$INSTALLED_VER" } else { "无" }

    Write-ColorText "⚠️  即将${actionText}: $oldDisplay → v$LATEST_VER" Yellow
    $ans = Read-Host "确认${actionText}? (y/N)"
    if ($ans -notmatch '^(y|Y|yes|YES)$') {
        Write-ColorText "🚫 用户取消" Red
        exit 0
    }

    # 检查磁盘空间
    Test-DiskSpace

    # ---------- 4) 选择下载资源(根据架构适配) ----------
    $ARCH = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    # 检测 ARM64 (Windows 11+)
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") {
        $ARCH = "arm64"
    }
    Write-Host "🖥️  系统架构: $ARCH"

    $URL = $null
    # 针对不同架构搜索对应安装包(优先级: msi > nsis/exe > zip)
    switch ($ARCH) {
        "arm64" {
            $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_arm64-setup\.exe$"
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_arm64.*\.msi$" }
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_arm64.*\.zip$" }
            # 回退到 x64(ARM64 Windows 可运行 x64 程序)
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x64-setup\.exe$" }
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x64.*\.msi$" }
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x64.*\.zip$" }
        }
        "x64" {
            $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x64-setup\.exe$"
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x64.*\.msi$" }
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x64.*\.zip$" }
        }
        "x86" {
            $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x86-setup\.exe$"
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x86.*\.msi$" }
            if (-not $URL) { $URL = Find-DownloadUrl $release "Antigravity\.Tools_${LATEST_VER}_x86.*\.zip$" }
        }
    }

    if (-not $URL) {
        Write-ColorText "❌ 未找到适配当前架构($ARCH)的下载资源" Red
        Write-Host "可用资源列表:"
        $release.assets | ForEach-Object { Write-Host "  $($_.browser_download_url)" }
        exit 1
    }

    $FILE_NAME = [System.IO.Path]::GetFileName($URL)
    $FILE_PATH = Join-Path $TMP_DIR $FILE_NAME

    # ---------- 5) 下载文件 ----------
    Write-Host ""
    Write-ColorText "⬇️  下载中: $FILE_NAME" Cyan
    Write-Host "   URL: $URL"

    try {
        # 使用 BITS 传输(支持断点续传)或回退到 WebClient
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $URL -Destination $FILE_PATH -DisplayName "下载 $APP_NAME"
        }
        else {
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($URL, $FILE_PATH)
        }
    }
    catch {
        Write-ColorText "❌ 下载失败，请检查网络连接" Red
        Write-Host "错误详情: $($_.Exception.Message)"
        exit 1
    }

    if (-not (Test-Path $FILE_PATH) -or (Get-Item $FILE_PATH).Length -eq 0) {
        Write-ColorText "❌ 下载文件无效(大小为0)" Red
        exit 1
    }

    Write-Host "✅ 下载完成: $((Get-Item $FILE_PATH).Length / 1MB) MB"

    # ---------- 6) 安装 ----------
    # 关闭正在运行的应用
    $runningProc = Get-Process -Name "Antigravity Tools" -ErrorAction SilentlyContinue
    if ($runningProc) {
        Write-ColorText "⏳ 正在关闭运行中的 $APP_NAME..." Yellow
        $runningProc | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    Install-Application -FilePath $FILE_PATH

    # ---------- 7) 验证安装 ----------
    $newInstalled = Get-InstalledVersion
    $finalVer = if ($newInstalled) { $newInstalled.Version } else { $LATEST_VER }

    Write-Host ""
    Write-ColorText "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" Green
    Write-ColorText "🎉 ${actionText}成功! v$finalVer" Green
    Write-ColorText "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" Green
}
finally {
    # 清理临时文件
    if (Test-Path $TMP_DIR) {
        Remove-Item $TMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}
