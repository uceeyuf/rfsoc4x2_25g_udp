# Print the NIC receive / transmit rate (Gbps) once per second during a stream test.
#   powershell -ExecutionPolicy Bypass -File tests\nic_rate.ps1 [-Match Mellanox] [-Seconds 30]
param([string] $Match = "Mellanox", [int] $Seconds = 30)

$inst = (Get-Counter -ListSet "Network Interface").PathsWithInstances |
    Where-Object { $_ -like "*$Match*Bytes Received/sec" } | Select-Object -First 1
if (-not $inst) { throw "no network interface matching '$Match'" }
$rx = $inst
$tx = $inst -replace 'Bytes Received/sec', 'Bytes Sent/sec'
Write-Host "Interface counter: $rx"
for ($i = 1; $i -le $Seconds; $i++) {
    $s = Get-Counter -Counter $rx, $tx -SampleInterval 1 -MaxSamples 1
    $r = $s.CounterSamples[0].CookedValue * 8 / 1e9
    $t = $s.CounterSamples[1].CookedValue * 8 / 1e9
    Write-Host ("{0}  {1,3}s   RX {2,7:N2} Gbps   TX {3,7:N3} Gbps" -f (Get-Date -Format HH:mm:ss), $i, $r, $t)
}
