param([switch]$RunPending,[int]$WaitForProcess=0,[long]$WaitForStartTicks=0)
$root=Join-Path $env:LOCALAPPDATA 'HEIC-WIC-Compatibility'
$cleanupScriptText=[IO.File]::ReadAllText($PSCommandPath)
function Get-CleanupRunKey { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' }
function Remove-PendingCleanup {
 $key=Get-CleanupRunKey
 if(Test-Path -LiteralPath $key){Remove-ItemProperty -LiteralPath $key -Name 'HEIC-WIC-Compatibility-Cleanup' -ErrorAction SilentlyContinue}
}
function Set-PendingCleanup {
 $key=Get-CleanupRunKey
 if(-not(Test-Path -LiteralPath $key)){New-Item -Path $key -Force | Out-Null}
 $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $script=Join-Path $root 'Cleanup.ps1'
 $command='"'+$ps+'" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$script+'" -RunPending'
 New-ItemProperty -LiteralPath $key -Name 'HEIC-WIC-Compatibility-Cleanup' -Value $command -PropertyType String -Force | Out-Null
}
function Assert-CleanupDirectory($path){
 if(Test-Path -LiteralPath $path){
  $item=Get-Item -LiteralPath $path -Force
  if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "清理目标不是普通目录，已停止：$path"}
 }
}
function Start-PostExitCleanup {
 $entry=Join-Path $root '3-撤销修复.cmd'
 if($env:HEIC_UNINSTALL_ENTRY -ine $entry){return $false}
 # CMD keeps reading its batch file. Delete it only after that window exits.
 Set-PendingCleanup
 try{
  $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)
  $parent=Get-Process -Id $current.ParentProcessId -ErrorAction Stop
  if($parent.ProcessName -ne 'cmd'){throw '未找到撤销窗口进程。'}
  $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Cleanup.ps1')+'" -RunPending -WaitForProcess '+$parent.Id+' -WaitForStartTicks '+$parent.StartTime.ToUniversalTime().Ticks
  Start-Process -FilePath $ps -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
  Write-Host '注册已撤销。关闭本撤销窗口后，将自动删除安装文件及目录。' -ForegroundColor Green
 }catch{Write-Warning '注册已撤销；已安排下次登录后清理安装目录。'}
 return $true
}
function Assert-RuntimeUnregistered {
 foreach($scope in @('CurrentUser','LocalMachine')){foreach($view in @('Registry64','Registry32')){
  $b=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$scope,[Microsoft.Win32.RegistryView]::$view)
  $k=$null
  try{
   $k=$b.OpenSubKey('Software\Classes\CLSID\{6215667c-74ca-4076-a769-3f834c3f25f5}\InprocServer32')
   if($k){
    $path=[string]$k.GetValue('')
    foreach($arch in @('x64','x86')){if($path -ieq (Join-Path $root ('codec\'+$arch+'\wic_heic.dll'))){throw '解码器仍注册在使用中，未删除安装文件。'}}
   }
  }finally{if($k){$k.Dispose()};$b.Dispose()}
 }}
}
function Release-HeicHolders {
 $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $paths=@((Join-Path $root 'codec\x64\wic_heic.dll'),(Join-Path $root 'codec\x86\wic_heic.dll'))
 foreach($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -eq $session -and $_.ProcessName -in @('dllhost','rundll32','Microsoft.Photos','Photos')})){
  try{
   $modules=@($process.Modules)
   if(-not @($modules | Where-Object {$_.FileName -in $paths}).Count){continue}
   if($process.ProcessName -eq 'rundll32' -and -not @($modules | Where-Object ModuleName -ieq 'PhotoViewer.dll').Count){continue}
   $instance=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
   if(-not $instance -or (Invoke-CimMethod -InputObject $instance -MethodName GetOwnerSid).Sid -ne $sid){continue}
   if($process.ProcessName -eq 'dllhost'){
    Write-Host ('正在释放本工具的缩略图解码进程：'+$process.Id)
    Stop-Process -Id $process.Id -ErrorAction Stop
   }elseif($process.MainWindowHandle -ne [IntPtr]::Zero){
    Write-Host ('正在关闭使用本工具的看图窗口：'+$process.ProcessName)
    if($process.CloseMainWindow()){$null=$process.WaitForExit(1000)}
   }
  }catch{Write-Warning ('部分解码器占用未释放：'+$_.Exception.Message)}
 }
}
function Remove-HeicRuntime {
 $expected=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'HEIC-WIC-Compatibility'))
 if([IO.Path]::GetFullPath($root) -ine $expected){throw '安装目录路径校验失败。'}
 Assert-CleanupDirectory $root
 if(-not(Test-Path -LiteralPath $root)){Remove-PendingCleanup;return $true}
 foreach($relative in @('codec','codec\x64','codec\x86','Logs')){Assert-CleanupDirectory (Join-Path $root $relative)}
 $state=Join-Path $root 'backup.json'
 if(-not(Test-Path -LiteralPath $state)){throw '缺少撤销完成记录，未删除安装文件。'}
 $record=Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json
 if($record.Status -ne 'RolledBack'){throw '尚未完成撤销，未删除安装文件。'}
 Assert-RuntimeUnregistered
 $failed=$false
 foreach($relative in @('codec\x64\wic_heic.dll','codec\x86\wic_heic.dll','Verify.exe','自检样本.heic','Manage.ps1','hashes.json','3-撤销修复.cmd')){
  $path=Join-Path $root $relative
  if(Test-Path -LiteralPath $path){
   $file=Get-Item -LiteralPath $path -Force
   if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "安装文件类型异常，未删除：$relative"}
   try{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}catch{$failed=$true;Write-Warning ('文件仍被占用或无法删除：'+$relative)}
  }
 }
 $logs=Join-Path $root 'Logs'
 if(Test-Path -LiteralPath $logs){foreach($file in @(Get-ChildItem -LiteralPath $logs -File -Force)){
  if($file.Name -match '^(?:Install|Uninstall|Test|Open)-\d{8}-\d{6}-\d{3}\.txt$' -and ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){
   try{Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop}catch{$failed=$true}
  }
 }}
 foreach($relative in @('codec\x64','codec\x86','codec','Logs')){
  $dir=Join-Path $root $relative
  if((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0){[IO.Directory]::Delete($dir,$false)}
 }
 if($failed){return $false}
 $unknown=@(Get-ChildItem -LiteralPath $root -Force | Where-Object {$_.Name -notin @('backup.json','Cleanup.ps1')})
 if($unknown.Count){Write-Warning '目录中有其他文件，已保留；不会自动删除这些文件。';Remove-PendingCleanup;return $false}
 foreach($path in @((Join-Path $root 'Cleanup.ps1'),$state)){
  if(Test-Path -LiteralPath $path){$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '清理记录类型异常，已停止。'}}
 }
 # Keep the rollback marker until every runtime component has been removed.
 $helper=Join-Path $root 'Cleanup.ps1'
 try{
  if(Test-Path -LiteralPath $helper){Remove-Item -LiteralPath $helper -Force -ErrorAction Stop}
  Remove-Item -LiteralPath $state -Force -ErrorAction Stop
 }catch{
  if(-not(Test-Path -LiteralPath $helper)){[IO.File]::WriteAllText($helper,$cleanupScriptText,(New-Object Text.UTF8Encoding($true)))}
  Write-Warning '撤销记录或清理程序仍被占用，稍后再清理。'
  return $false
 }
 if(@(Get-ChildItem -LiteralPath $root -Force).Count -eq 0){[IO.Directory]::Delete($root,$false)}
 Remove-PendingCleanup
 return (-not(Test-Path -LiteralPath $root))
}
if($RunPending){
 try{
  if($WaitForProcess -gt 0){
   $parent=Get-Process -Id $WaitForProcess -ErrorAction SilentlyContinue
   if($parent -and $parent.StartTime.ToUniversalTime().Ticks -eq $WaitForStartTicks){if(-not $parent.WaitForExit(300000)){exit 0}}
  }
  # A subsequent reinstall cancels deletion even if a stale RunOnce command remains.
  $state=Join-Path $root 'backup.json'
  if(Test-Path -LiteralPath $state){$record=Get-Content -LiteralPath $state -Raw -Encoding UTF8 | ConvertFrom-Json;if($record.Status -ne 'RolledBack'){Remove-PendingCleanup;exit 0}}
  $null=Remove-HeicRuntime
 }catch{Write-Warning $_.Exception.Message;exit 1}
}
