$out = "F:\Workbuddy-workspace\USB-Reconnect-40Round-20261106\host-monitor-PCA.log"
$end = (Get-Date).AddMinutes(16)
"ts_utc,rndis_present,rndis_name,ipv4,dhcp_ok,mtp_present,mtp_status" | Out-File -FilePath $out -Encoding utf8
while ((Get-Date) -lt $end) {
  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
  $rndisPresent = $false; $rndisName = ""; $ip = ""; $dhcp = $false
  $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Remote NDIS|RNDIS' }
  if ($adapters) {
    $a = $adapters | Select-Object -First 1
    $rndisPresent = $true; $rndisName = $a.Name
    $addr = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($addr -and $addr.IPAddress) { $ip = $addr.IPAddress }
    if ($ip -and ($ip -notmatch '^169\.254\.')) { $dhcp = $true }
  }
  $mtpPresent = $false; $mtpStatus = ""
  $wpd = Get-PnpDevice -Class WPD -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq 'RG353PS' -or $_.InstanceId -match 'VID_2207&PID_0008' }
  if ($wpd) { $mtpPresent = $true; $mtpStatus = ($wpd | Select-Object -First 1).Status }
  "$now,$rndisPresent,$rndisName,$ip,$dhcp,$mtpPresent,$mtpStatus" | Add-Content -Path $out -Encoding utf8
  Start-Sleep -Milliseconds 1000
}
