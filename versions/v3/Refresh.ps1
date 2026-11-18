[CmdletBinding()]
param([ValidateSet('Refresh','Diagnose','Check')][string]$Mode='Refresh',[string]$ImagePath)
$ErrorActionPreference='Stop'
$exitCode=0
$transcript=$false
$warnings=0
function Show-Status {
    Write-Host ('用户：'+[Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Host "Windows：$($cv.ProductName)，内部版本 $($cv.CurrentBuildNumber).$($cv.UBR)"
    foreach($name in @('Microsoft.HEIFImageExtension','Microsoft.HEVCVideoExtension','Microsoft.Windows.Photos')) {
        $packages=@(Get-AppxPackage -Name $name)
        if($packages.Count -eq 0) { Write-Warning "当前账户未安装：$name" }
        foreach($p in $packages) { Write-Host "$($p.Name)  $($p.Version)  状态=$($p.Status)" }
    }
    $advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $icons=(Get-ItemProperty -LiteralPath $advanced -Name IconsOnly -ErrorAction SilentlyContinue).IconsOnly
    Write-Host "IconsOnly=$icons（1 表示只显示图标，0 表示允许缩略图）"
    foreach($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer','HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer')) {
        $policy=Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if($policy.DisableThumbnails -eq 1) { Write-Warning "策略禁用了缩略图：$key；本工具不会覆盖组织策略。" }
    }
}
function Test-Picture([string]$Path) {
    if(-not $Path) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog=New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title='选择一张打不开的 HEIC 原图进行本地检测'
        $dialog.Filter='HEIC/HEIF 图片|*.heic;*.heif|所有文件|*.*'
        try {
            if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { Write-Host '已取消图片检测。'; return }
            $Path=$dialog.FileName
        } finally { $dialog.Dispose() }
    }
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop
    if($file.PSIsContainer -or $file.Length -eq 0) { throw '请选择非空的本地图片文件。' }
    Write-Host "检测文件：$($file.FullName)，大小 $($file.Length) 字节"
    $head=New-Object byte[] 32
    $stream=[IO.File]::OpenRead($file.FullName)
    try { $count=$stream.Read($head,0,$head.Length) } finally { $stream.Dispose() }
    Write-Host ('文件头：'+[BitConverter]::ToString($head,0,$count))
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    $stream=[IO.File]::OpenRead($file.FullName)
    try {
        $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame=$decoder.Frames[0]
        $buffer=New-Object byte[] 32
        $rect=New-Object Windows.Int32Rect(0,0,1,1)
        $frame.CopyPixels($rect,$buffer,32,0)
        Write-Host "Windows WPF/WIC 图片解码测试通过：$($frame.PixelWidth) × $($frame.PixelHeight)，$($frame.Format)" -ForegroundColor Green
        Write-Host '该检测只验证本地 WPF/WIC 解码路径；不代表照片应用和资源管理器均已通过测试。'
        Write-Host '如果双击仍打不开，请右键图片→打开方式→照片，确认使用的是微软照片应用。'
    } catch {
        Write-Warning 'Windows WPF/WIC 图片解码测试失败。刷新缓存不能单独修复这类解码错误。'
        $err=$_.Exception
        while($err) { Write-Host ('异常：'+$err.GetType().FullName+'；HRESULT=0x'+$err.HResult.ToString('X8')+'；'+$err.Message); $err=$err.InnerException }
        throw '请把这份日志和打开图片时的具体报错提供给我，以便继续判断文件格式、授权或照片应用问题。'
    } finally { $stream.Dispose() }
}
try {
    Write-Host 'HEIC 刷新与图片检测 v3' -ForegroundColor Cyan
    $logDir=Join-Path $env:LOCALAPPDATA 'HEIC-OfflineExtensions\Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logPath=Join-Path $logDir ('refresh-v3-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.txt')
    Start-Transcript -Path $logPath -Force | Out-Null
    $transcript=$true
    Show-Status
    if($Mode -eq 'Refresh') {
        Write-Host '正在开启缩略图显示、清理缩略图缓存并重启当前会话的文件资源管理器。'
        $advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        $old=(Get-ItemProperty -LiteralPath $advanced -Name IconsOnly -ErrorAction SilentlyContinue).IconsOnly
        @{IconsOnly=$old;Time=(Get-Date -Format o)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logDir ('thumbnail-setting-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json')) -Encoding UTF8
        if(-not (Test-Path -LiteralPath $advanced)) { New-Item -Path $advanced -Force | Out-Null }
        New-ItemProperty -LiteralPath $advanced -Name IconsOnly -Value 0 -PropertyType DWord -Force | Out-Null
        $cacheRoot=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'))
        $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
        $explorers=@(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
        $removed=0
        try {
            foreach($process in $explorers) { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
            if(Test-Path -LiteralPath $cacheRoot) {
                $rootItem=Get-Item -LiteralPath $cacheRoot -Force
                if(($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '缓存目录是链接，已跳过清理以避免误删。' }
                foreach($file in @(Get-ChildItem -LiteralPath $cacheRoot -Filter 'thumbcache_*.db' -File -Force)) {
                    $full=[IO.Path]::GetFullPath($file.FullName)
                    if([IO.Path]::GetDirectoryName($full) -ne $cacheRoot -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '缓存文件路径检查未通过。' }
                    try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop; $removed++ }
                    catch { $warnings++; Write-Warning "缓存仍被占用，未删除：$($file.Name)。$($_.Exception.Message)" }
                }
            }
        } finally {
            if($explorers.Count -gt 0) {
                $running=@(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
                if($running.Count -eq 0) { Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') }
            }
        }
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HeicShellRefresh { [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint e, uint f, IntPtr a, IntPtr b); }'
        [HeicShellRefresh]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
        Write-Host "刷新步骤完成，清理了 $removed 个缩略图缓存文件。" -ForegroundColor Green
        if($warnings -gt 0) { Write-Warning '部分缓存被占用；请注销再登录后测试。' }
        Write-Host '请重新打开图片所在文件夹。若仍打不开，运行“2-检测打不开的图片.cmd”。'
        Write-Host '此结果只表示刷新步骤完成，不表示 HEIC 图片已确认能打开。'
    } elseif($Mode -eq 'Diagnose') { Test-Picture $ImagePath }
    else { Write-Host '只读检查完成；未改设置、未清缓存、未重启资源管理器。' -ForegroundColor Green }
} catch {
    $exitCode=1
    Write-Host ('未完成：'+$_.Exception.Message) -ForegroundColor Red
    Write-Host ($_ | Out-String)
} finally {
    if($transcript) { Stop-Transcript | Out-Null; Write-Host "日志：$logPath" }
}
exit $exitCode