function Get-CompatibleExtensionPackages {
    param(
        [Parameter(Mandatory=$true)][object[]]$Records,
        [Parameter(Mandatory=$true)][version]$WindowsVersion
    )
    foreach ($name in @('Microsoft.HEIFImageExtension','Microsoft.HEVCVideoExtension')) {
        $selected = $Records | Where-Object {
            $_.Name -eq $name -and [version]$_.MinVersion -le $WindowsVersion
        } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        if (-not $selected) { throw "没有适用于系统 $WindowsVersion 的组件：$name" }
        $selected
    }
}
