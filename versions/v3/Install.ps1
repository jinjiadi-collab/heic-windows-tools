[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$exitCode = 0
$logStarted = $false
try {
    Write-Host 'HEIC 图片支持 — 安装与刷新版 v3' -ForegroundColor Cyan
    $logDir = Join-Path $env:LOCALAPPDATA 'HEIC-OfflineExtensions\Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logPath = Join-Path $logDir ('install-v3-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    Start-Transcript -Path $logPath -Force | Out-Null
    $logStarted = $true
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { throw '本脚本只支持 Intel/AMD 64 位 Windows。' }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ([int]$cv.CurrentBuildNumber -lt 17763) { throw '请先更新至 Windows 10 1809 或以上版本。' }
    $records = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'inventory.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($records.Count -ne 2) { throw '安装包清单不完整。' }
    foreach ($r in $records) {
        if ($r.File -notin @('HEIF.appxbundle','HEVC.appxbundle')) { throw '安装文件名不符合预期。' }
        $path = Join-Path (Join-Path $PSScriptRoot 'Packages') $r.File
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $r.SHA256) { throw "安装包损坏：$($r.File)，请重新复制。" }
        $sig = Get-AuthenticodeSignature -LiteralPath $path
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -ne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
            throw "微软数字签名验证未通过：$($r.File)，状态 $($sig.Status)。请检查系统时间、根证书及日志；不会绕过签名检查。"
        }
        Write-Host "文件及微软签名检查通过：$($r.File) $($r.Version)"
    }
    if ($CheckOnly) {
        Write-Host '预检查通过，没有安装或修改组件。' -ForegroundColor Green
    } else {
        foreach ($r in $records) {
            $existing = Get-AppxPackage -Name $r.Name | Where-Object { [version]$_.Version -ge [version]$r.Version -and [string]$_.Status -eq 'Ok' } | Select-Object -First 1
            if ($existing) {
                Write-Host "已安装正常版本，跳过：$($r.Name) $($existing.Version)" -ForegroundColor Green
                continue
            }
            Write-Host "正在安装：$($r.Name)"
            Add-AppxPackage -Path (Join-Path (Join-Path $PSScriptRoot 'Packages') $r.File) -ErrorAction Stop
            $installed = Get-AppxPackage -Name $r.Name | Where-Object { [version]$_.Version -ge [version]$r.Version -and [string]$_.Status -eq 'Ok' } | Select-Object -First 1
            if (-not $installed) { throw "安装后检查未通过：$($r.Name)" }
            Write-Host "安装状态正常：$($r.Name) $($installed.Version)" -ForegroundColor Green
        }
        Write-Host '两个组件状态正常，接下来刷新缩略图与文件资源管理器。' -ForegroundColor Green
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Refresh.ps1') -Mode Refresh
        if($LASTEXITCODE -ne 0) { Write-Warning '组件安装通过，但刷新步骤未全部完成。请查看 refresh-v3 日志。' }
        Write-Host '缩略图未刷新时，可注销再登录。安装成功后，本下载文件夹可以删除。'
    }
} catch {
    $exitCode = 1
    Write-Host ('未完成：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_ | Out-String)
    Write-Host '若提示应用正在使用，请关闭照片、播放器后再试；若提示许可证问题，请通过微软商店获取授权。'
    Write-Host '请提供本窗口截图或下面的日志。'
} finally {
    if ($logStarted) { Stop-Transcript | Out-Null; Write-Host "日志：$logPath" }
}
exit $exitCode