[CmdletBinding()]
param([ValidateSet('Install','Uninstall','Test','Open')][string]$Mode='Install',[string]$ImagePath)
$ErrorActionPreference='Stop'
$exitCode=0
$root=Join-Path $env:LOCALAPPDATA 'HEIC-WIC-Compatibility'
$statePath=Join-Path $root 'backup.json'
$codecId='{6215667c-74ca-4076-a769-3f834c3f25f5}'
$progid='Codex.HEIC.PhotoViewer'
$views=@('Registry64','Registry32')
function Clear-Logs {
 try {
  $basePath=[IO.Path]::GetFullPath($root)
  $logs=Join-Path $basePath 'Logs'
  foreach($dir in @($basePath,$logs)){
   if(Test-Path -LiteralPath $dir){
    $item=Get-Item -LiteralPath $dir -Force
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '日志目录不是普通文件夹，已跳过清理。'}
   }
  }
  if(Test-Path -LiteralPath $logs){
   foreach($file in @(Get-ChildItem -LiteralPath $logs -File -Force)){
    if($file.Name -match '^(?:Install|Uninstall|Test|Open)-\d{8}-\d{6}-\d{3}\.txt$' -and ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and [IO.Path]::GetDirectoryName($file.FullName) -eq $logs){
     Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
    }
   }
   if(@(Get-ChildItem -LiteralPath $logs -Force).Count -eq 0){[IO.Directory]::Delete($logs,$false)}
  }
 }catch{Write-Warning ('旧日志未全部清理：'+$_.Exception.Message)}
}
function Base($scope,$view){
 $hive=if($scope -eq 'LocalMachine'){[Microsoft.Win32.RegistryHive]::LocalMachine}else{[Microsoft.Win32.RegistryHive]::CurrentUser}
 return [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,[Microsoft.Win32.RegistryView]::$view)
}
function Data-In($kind,$data){
 switch($kind){
  'Binary' {return ,[Convert]::FromBase64String([string]$data)}
  'DWord' {return [int]$data}
  'QWord' {return [long]$data}
  'MultiString' {return ,[string[]]$data}
  default {return [string]$data}
 }
}
function Get-Old($scope,$view,$path,$name){
 $b=Base $scope $view;$k=$null
 try{
  $k=$b.OpenSubKey($path,$false)
  if($null -eq $k -or $k.GetValueNames() -notcontains $name){return @{Exists=$false;Kind='String';Data=$null}}
  $kind=$k.GetValueKind($name).ToString();$data=$k.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if($kind -eq 'Binary'){$data=[Convert]::ToBase64String($data)}
  return @{Exists=$true;Kind=$kind;Data=$data}
 }finally{if($k){$k.Dispose()};$b.Dispose()}
}
function Set-Reg($scope,$change,$restore=$false){
 $b=Base $scope $change.View;$k=$null
 try{
  if($restore -and -not $change.Old.Exists){
   $k=$b.OpenSubKey($change.Path,$true);if($k){$k.DeleteValue($change.Name,$false)};return
  }
  $k=$b.CreateSubKey($change.Path)
  $kind=if($restore){[string]$change.Old.Kind}else{[string]$change.Kind}
  $data=if($restore){$change.Old.Data}else{$change.Data}
  $k.SetValue([string]$change.Name,(Data-In $kind $data),[Microsoft.Win32.RegistryValueKind]::$kind)
 }finally{if($k){$k.Dispose()};$b.Dispose()}
}
function Save-State($s){$s | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $statePath -Encoding UTF8}
function Get-OrphanState($scope){
 $owned=[Collections.Generic.List[object]]::new()
 foreach($view in $views){
  $c='Software\Classes\CLSID\'+$codecId
  $cat='Software\Classes\CLSID\{7ED96837-96F0-4812-B211-F13C24117ED3}\Instance\'+$codecId
  $pg='Software\Classes\'+$progid
  $anchor=$false
  foreach($path in @($c,$cat,$pg)){
   $b=Base $scope $view;$k=$null
   try{
    $k=$b.OpenSubKey($path)
    if(-not $k){continue}
    if($path -eq $c){
     $arch=if($view -eq 'Registry64'){'x64'}else{'x86'}
     $dll=Get-Old $scope $view ($c+'\InprocServer32') ''
     $expected=Join-Path $root ('codec\'+$arch+'\wic_heic.dll')
     if(-not $dll.Exists -or [string]$dll.Data -ine $expected -or $k.GetValue('Author') -ne 'prsyahmi@github'){throw "同名解码器不属于本安装目录，未覆盖：$scope/$view/$path"}
     $anchor=$true
    }elseif($path -eq $cat){
     if([string]$k.GetValue('CLSID') -ine $codecId){throw '同名解码器类别注册不符合预期，未覆盖。'}
    }else{
     $command=Get-Old $scope $view ($pg+'\shell\open\command') ''
     $viewer=Join-Path $env:ProgramFiles 'Windows Photo Viewer\PhotoViewer.dll'
     $expected='"'+(Join-Path $env:SystemRoot 'System32\rundll32.exe')+'" "'+$viewer+'", ImageView_Fullscreen "%1"'
     if(-not $command.Exists -or [string]$command.Data -ine $expected -or $k.GetValue('') -ne 'Windows 照片查看器（HEIC）'){throw '同名查看器入口不符合本工具特征，未覆盖。'}
     $anchor=$true
    }
    $owned.Add(@{View=$view;Path=$path})
   }finally{if($k){$k.Dispose()};$b.Dispose()}
  }
  if(@($owned | Where-Object View -eq $view).Count -gt 0 -and -not $anchor){throw '仅找到解码器类别残留，无法确认归属，未自动更改。'}
 }
 if($owned.Count -eq 0){return $null}
 $changes=[Collections.Generic.List[object]]::new()
 foreach($view in $views){foreach($ext in @('.heic','.heif')){
  $path='Software\Classes\'+$ext+'\OpenWithProgids'
  $value=Get-Old $scope $view $path $progid
  if($value.Exists -and [string]$value.Data -eq ''){$changes.Add(@{View=$view;Path=$path;Name=$progid;Kind='String';Data='';Old=@{Exists=$false;Kind='String';Data=$null}})}
 }}
 return @{Schema=1;Version='1.1.16';Scope=$scope;Status='Prepared';Recovery=$true;Changes=@($changes.ToArray());OwnTrees=@($owned.ToArray());Created=(Get-Date -Format o)}
}
function Find-OrphanState($admin){
 $candidates=@()
 foreach($candidateScope in @('CurrentUser','LocalMachine')){
  $candidate=Get-OrphanState $candidateScope
  if($candidate){$candidates+=,$candidate}
 }
 if($candidates.Count -gt 1){throw '当前账户和整台电脑均有本工具残留，无法确定原安装范围，请先分别检查，未自动覆盖。'}
 if($candidates.Count -eq 1){
  if($candidates[0].Scope -eq 'LocalMachine' -and -not $admin){throw '发现原安装为管理员安装，请右键以管理员身份运行同一个入口恢复或撤销。'}
  return $candidates[0]
 }
 return $null
}
function Show-RecoveryWarning{
 Write-Warning '原始撤销备份已丢失；本次只能移除或重新接管确认属于本工具的注册。无法恢复未知的安装前共享设置。'
}
function Rollback($s){
 foreach($change in $s.Changes){Set-Reg $s.Scope $change $true}
 foreach($tree in $s.OwnTrees){
  if($tree.Path -notin @(('Software\Classes\CLSID\'+$codecId),('Software\Classes\CLSID\{7ED96837-96F0-4812-B211-F13C24117ED3}\Instance\'+$codecId),('Software\Classes\'+$progid))){throw '撤销目标校验失败。'}
  $b=Base $s.Scope $tree.View
  try{$b.DeleteSubKeyTree([string]$tree.Path,$false)}finally{$b.Dispose()}
 }
 $s.Status='RolledBack';Save-State $s
}
function Notify{
 if(-not ('HeicNotify' -as [type])){Add-Type 'using System;using System.Runtime.InteropServices;public static class HeicNotify{[DllImport("shell32.dll")]public static extern void SHChangeNotify(uint e,uint f,IntPtr a,IntPtr b); }'}
 [HeicNotify]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)
}
function Choose-Image{
 if($ImagePath){return (Get-Item -LiteralPath $ImagePath -ErrorAction Stop).FullName}
 Add-Type -AssemblyName System.Windows.Forms
 $d=New-Object Windows.Forms.OpenFileDialog;$d.Title='选择需要打开的 HEIC 原图';$d.Filter='HEIC / HEIF|*.heic;*.heif|所有文件|*.*'
 try{if($d.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){return $d.FileName};return $null}finally{$d.Dispose()}
}
function Check-Image($path){
 $verify=Join-Path $root 'Verify.exe'
 if(-not(Test-Path -LiteralPath $verify)){throw '请先运行一键安装。'}
 $text=@(& $verify $path 2>&1);$code=$LASTEXITCODE;$text | ForEach-Object{Write-Host $_}
 if($code -ne 0){throw 'Windows 图片接口解码仍失败，请先截取本窗口报错，再关闭窗口。'}
 if(($text -join "`n") -notmatch [regex]::Escape($codecId)){throw '当前程序未选中兼容解码器，请使用日常看图的账户安装，或注销再登录。'}
 Write-Host '原始 HEIC 的完整像素读取通过。' -ForegroundColor Green
}
try{
 if(-not[Environment]::Is64BitOperatingSystem -or -not[Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw '本包适用于 Intel/AMD 64 位 Windows 10/11，请使用包内的 CMD 入口。'}
 if($Mode -eq 'Install'){New-Item -ItemType Directory -Path $root -Force | Out-Null}
 Write-Host 'HEIC 系统兼容修复 v4 — WicHeic 1.1.16' -ForegroundColor Cyan
 Write-Host '原始 HEIC 文件不会转换或改写。显示为普通8位画面，不提供HDR显示。'
 $id=[Security.Principal.WindowsIdentity]::GetCurrent();$admin=([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 if($Mode -eq 'Uninstall'){
  if(Test-Path -LiteralPath $statePath){$s=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json}
  else{
   $s=Find-OrphanState $admin
   if(-not $s){Write-Host '没有安装备份，也未发现可确认属于本工具的残留注册。';exit 0}
   New-Item -ItemType Directory -Path $root -Force | Out-Null
   Save-State $s
  }
  if($s.Recovery){Show-RecoveryWarning}
  if($s.Status -eq 'RolledBack'){Write-Host '修复已经撤销。'}else{
   Rollback $s;Notify
   if($s.Recovery){Write-Host '已移除本工具的解码器及专用打开入口；无法确定原值的共享设置已保留。' -ForegroundColor Green}
   else{Write-Host '已恢复安装前的注册信息。' -ForegroundColor Green}
   Write-Host '请关闭看图窗口并注销再登录，使已加载的组件退出。'
  }
  Write-Host '已停止注册兼容解码器；保留组件文件及撤销备份，不会删除照片或微软扩展。'
 }elseif($Mode -eq 'Install'){
  $hashes=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $sources=@(@{Source='codec\x64\wic_heic.dll';Hash=$hashes.x64},@{Source='codec\x86\wic_heic.dll';Hash=$hashes.x86},@{Source='Verify.exe';Hash=$hashes.'Verify.exe'},@{Source='自检样本.heic';Hash=$hashes.'自检样本.heic'})
  foreach($file in $sources){$src=Join-Path $PSScriptRoot $file.Source;if((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne $file.Hash){throw "文件校验失败：$($file.Source)"}}
  $scope=if($admin){'LocalMachine'}else{'CurrentUser'}
  $s=$null
  if(Test-Path -LiteralPath $statePath){$old=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json;if($old.Status -in @('Installed','Prepared')){$s=$old;$scope=$s.Scope}}
  if(-not $s -and -not(Test-Path -LiteralPath $statePath)){$s=Find-OrphanState $admin;if($s){$scope=$s.Scope}}
  if($s -and $s.Recovery){Show-RecoveryWarning;Write-Host '已识别本工具残留，将补回缺失文件并重新注册。'}
  if($scope -eq 'LocalMachine' -and -not $admin){throw '原安装需要管理员权限，请右键以管理员身份运行。'}
  $plan=[Collections.Generic.List[object]]::new();$trees=[Collections.Generic.List[object]]::new()
  function Add($view,$path,$name,$kind,$data){$plan.Add(@{View=$view;Path=$path;Name=$name;Kind=$kind;Data=$data;Old=(Get-Old $scope $view $path $name)})}
  $viewer=Join-Path $env:ProgramFiles 'Windows Photo Viewer\PhotoViewer.dll'
  foreach($view in $views){
   $c='Software\Classes\CLSID\'+$codecId;$cat='Software\Classes\CLSID\{7ED96837-96F0-4812-B211-F13C24117ED3}\Instance\'+$codecId;$pg='Software\Classes\'+$progid
   foreach($path in @($c,$cat,$pg)){
    $b=Base $scope $view;$k=$null
    try{$k=$b.OpenSubKey($path);if($k -and -not $s){throw "已有同名组件或程序注册，未覆盖：$path"}}finally{if($k){$k.Dispose()};$b.Dispose()}
    $trees.Add(@{View=$view;Path=$path})
   }
   Add $view $cat 'CLSID' 'String' $codecId;Add $view $cat 'FriendlyName' 'String' 'HEIC Decoder'
   foreach($name in @('ArbitrationPriority','SupportAnimation','SupportChromaKey','SupportLossless')){Add $view $c $name 'DWord' 0}
   Add $view $c 'SupportMultiframe' 'DWord' 1
   $values=@{Author='prsyahmi@github';ContainerFormat='{98ce31dd-5435-41bd-a1af-29c387c20135}';Description='HEIC Image Decoder';FriendlyName='HEIC Image Decoder';FileExtensions='.heic,.heif';MimeTypes='image/heic,image/heif';SpecVersion='1.0.0.0';Vendor='{d01102c8-6108-41dd-bd60-1f3a8e7f2447}';Version='1.1.16.0'}
   foreach($name in $values.Keys){Add $view $c $name 'String' $values[$name]}
   $arch=if($view -eq 'Registry64'){'x64'}else{'x86'}
   Add $view ($c+'\InprocServer32') '' 'String' (Join-Path $root ('codec\'+$arch+'\wic_heic.dll'))
   Add $view ($c+'\InprocServer32') 'ThreadingModel' 'String' 'Both'
   Add $view ($c+'\Formats\{6fddc324-4e03-4bfe-b185-3d77768dc90d}') '' 'String' ''
   $patterns=@('ftypheic','ftypheix','ftyphevc','ftypheim','ftypheis','ftyphevm','ftyphevs')
   for($i=0;$i -lt $patterns.Count;$i++){
    $p=$c+'\Patterns\'+$i
    Add $view $p 'Mask' 'Binary' ([Convert]::ToBase64String([byte[]](255,255,255,255,255,255,255,255)))
    Add $view $p 'Pattern' 'Binary' ([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($patterns[$i])))
    Add $view $p 'Length' 'DWord' 8;Add $view $p 'Position' 'DWord' 4
   }
   foreach($ext in @('.heic','.heif')){
    Add $view ('Software\Classes\'+$ext) 'Content Type' 'String' ('image/'+$ext.Substring(1))
    Add $view ('Software\Classes\'+$ext) 'PerceivedType' 'String' 'image'
    Add $view ('Software\Classes\SystemFileAssociations\'+$ext+'\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}') '' 'String' '{C7657C4A-9F68-40fa-A4DF-96BC08EB3551}'
    if(Test-Path -LiteralPath $viewer){Add $view ('Software\Classes\'+$ext+'\OpenWithProgids') $progid 'String' ''}
   }
   if(Test-Path -LiteralPath $viewer){
    Add $view $pg '' 'String' 'Windows 照片查看器（HEIC）'
    Add $view ($pg+'\shell\open') 'FriendlyAppName' 'String' 'Windows 照片查看器（HEIC）'
    Add $view ($pg+'\shell\open\command') '' 'String' ('"'+(Join-Path $env:SystemRoot 'System32\rundll32.exe')+'" "'+$viewer+'", ImageView_Fullscreen "%1"')
    Add $view ($pg+'\shell\open\DropTarget') 'Clsid' 'String' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}'
    $app='Software\Classes\Applications\photoviewer.dll'
    Add $view ($app+'\shell\open') 'MuiVerb' 'String' '@photoviewer.dll,-3043'
    Add $view ($app+'\shell\open\command') '' 'String' ('"'+(Join-Path $env:SystemRoot 'System32\rundll32.exe')+'" "'+$viewer+'", ImageView_Fullscreen "%1"')
    Add $view ($app+'\shell\open\DropTarget') 'Clsid' 'String' '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}'
    Add $view ($app+'\SupportedTypes') '.heic' 'String' ''
    Add $view ($app+'\SupportedTypes') '.heif' 'String' ''
   }
  }
  foreach($file in $sources){
   $dest=Join-Path $root $file.Source;$parent=Split-Path -Parent $dest;New-Item -ItemType Directory -Path $parent -Force | Out-Null
   if(Test-Path -LiteralPath $dest){if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $file.Hash){throw "已有不同版本文件：$dest。请先撤销旧版并关闭看图程序。"}}
   else{Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file.Source) -Destination $dest}
  }
  foreach($name in @('Manage.ps1','hashes.json','3-撤销修复.cmd')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $root $name) -Force}
  if(-not $s){$s=@{Schema=1;Version='1.1.16';Scope=$scope;Status='Prepared';Changes=@($plan.ToArray());OwnTrees=@($trees.ToArray());Created=(Get-Date -Format o)}}
  else{
   $existing=@{};foreach($c in $s.Changes){$existing[($c.View+'|'+$c.Path+'|'+$c.Name)]=$true}
   $extra=@($plan | Where-Object {-not $existing.ContainsKey($_.View+'|'+$_.Path+'|'+$_.Name)})
   if($extra.Count){$s.Changes=@($s.Changes)+$extra}
   $s.OwnTrees=@($trees.ToArray())
  }
  Save-State $s
  try{
   foreach($change in $plan){Set-Reg $scope $change}
   Notify
   Check-Image (Join-Path $root '自检样本.heic')
   if($ImagePath){Check-Image ((Get-Item -LiteralPath $ImagePath).FullName)}
   $s.Status='Installed';Save-State $s
  }catch{Rollback $s;Notify;throw}
  Write-Host '兼容修复已安装，并通过Windows默认图片接口的完整解码自检。' -ForegroundColor Green
  Write-Host ('安装范围：'+$(if($scope -eq 'CurrentUser'){'当前账户'}else{'整台电脑（管理员运行）'}))
  Write-Host '接下来运行“2-用Windows照片查看器打开.cmd”，选择原始HEIC。已有看图程序请先退出再重新打开。'
  Write-Host '原来的默认看图程序保持不变；没有卸载微软HEIF/HEVC扩展。'
 }else{
  $image=Choose-Image
  if($image){
   Check-Image $image
   if($Mode -eq 'Open'){
    $viewer=Join-Path $env:ProgramFiles 'Windows Photo Viewer\PhotoViewer.dll'
    if(-not(Test-Path -LiteralPath $viewer)){throw '这台电脑缺少旧版Windows照片查看器，请先用其他支持WIC的程序测试。'}
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\rundll32.exe') -ArgumentList ('"'+$viewer+'", ImageView_Fullscreen "'+$image+'"') -WindowStyle Normal
   }
  }else{Write-Host '已取消选择图片。'}
 }
}catch{
 $exitCode=1;Write-Host ('未完成：'+$_.Exception.Message) -ForegroundColor Red;Write-Host ($_ | Out-String)
}finally{
 Clear-Logs
}
exit $exitCode
