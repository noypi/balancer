$Host.UI.RawUI.WindowTitle = "Saif Balancer"

$gateway_mac1 = 'd4-40-f0-8a-3a-ca' # globe
$gateway_mac2 = '8c-4c-ad-06-87-88' # pldt
$source_interface = 'Ethernet'

function GetIPByMAC([string]$mac) {
    return arp -a | select-string $mac |% { $_.ToString().Trim().Split(" ")[0] }
}

function RunningBalancers() {
    return Get-WmiObject Win32_Process -Filter "Name='powershell.exe' AND CommandLine LIKE '%run-balancer.ps1%'"
}

function CountRunning() {
    $val = @(RunningBalancers).Count
    if ($val -eq $null) {
        return 0
    } else {
        return $val
    }
}

function CountRunningForeground() {
    $val = @(Get-Process | Where-Object { $_.MainWindowTitle -like '*Saif Balancer*' }).Count
    if ($val -eq $null) {
        return 0
    } else {
        return $val
    }
}

function PingViaMac([string]$mac) {
    $pingResult = @{
        Lost     = 100
        AvgRtt   = 99999
    }
    
    $resultObj = [pscustomobject]$pingResult
    
    Write-Host "pingViaMac => " $mac
    
    try {
        $result = nping -v0 --hide-sent -icmp --dest-mac $mac 8.8.8.8
        $avgRttLine = $result |  Select-String "Avg rtt"
        $lostLine = $result | Select-String "Lost"

        Write-Host "Rtt => " $avgRttLine
        Write-Host "lost => " $lostLine
        
        if ($lostLine -eq $null) {
            Write-Host "null lostline"
            return $resultObj
        }

        $maxRttPair, $minRttPair, $avgRttPair = $avgRttLine -split "\|", 3
        $sentPair, $receivedPair, $lostPair = $lostLine -split "\|", 3

        $_, $lost = ParseColonProperty $lostPair
        $_, $avgRtt = ParseColonProperty $avgRttPair

        # example: 0 (0.00%) 
        #    removes (0.00%)
        $lost, $_ = $lost -split ' ', 2
        $resultObj.Lost = [int]$lost
        if ($avgRtt -eq 'N/A') {
            $resultObj.AvgRtt = 0
        } else {
            $resultObj.AvgRtt = [int]($avgRtt -replace 'ms', '')
        }
    } catch {
    }

    Write-Host "avg => " $avgRtt ", lost => " $lost
    Write-Host "resultObj => " $resultObj

    return $resultObj
}

function ParseColonProperty([string]$pair) {
    # Write-Host "parseColonProperty pair => " $pair
    $key, $value = $pair -split '\:', 2
    $key = $key.Trim()
    $value = $value.Trim()
    # Write-Host "key => " $key  ", value => " $value
    return $key, $value
}

function GetGwMetric([string]$gw) {
    if ($gw -eq $null) {
        return 0
    }
    Write-Host "getGwMetric " $gw 
    return (Get-NetAdapter $source_interface | Get-NetRoute -NextHop $gw).RouteMetric
}

function EnsureGatewayHaveMetric([string]$gw, [int]$metric) {
    if ($gw -eq $null -or $gw -eq "") {
        return
    }
    $currentMetric = GetGwMetric $gw
    if ($metric -ne $currentMetric) {
        Write-Host "ensuring " $gw " have metric " $metric
        Get-NetAdapter $source_interface | Set-NetRoute -NextHop $gw -RouteMetric $metric
    }
}

function SetPrimaryGw([string]$gw, [int]$metric, [int]$nonPrimaryMetric) {
    if ($gw -eq $null -or $gw -eq "") {
        return
    }
    
    $current_interface = Get-NetAdapter $source_interface
    
    $current_interface | Get-NetRoute | ForEach-Object {
        if ($_.RouteMetric -lt 20) {
            if ($_.NextHop -eq $gw) {
                EnsureGatewayHaveMetric $gw $metric
            } else {
                EnsureGatewayHaveMetric $_.NextHop $nonPrimaryMetric
            }
        }
    }
}

function doWork() {
    $ipaddress_mac1 = GetIPByMAC $gateway_mac1;
    $ipaddress_mac2 = GetIPByMAC $gateway_mac2;
    Write-Host "IP Address 1 => " $ipaddress_mac1
    Write-Host "IP Address 2 => " $ipaddress_mac2

    $pingResult1 = PingViaMac $gateway_mac1
    $pingResult2 = PingViaMac $gateway_mac2

    Write-Host "mac1 IP => " $ipaddress_mac1 " , lost => " $pingResult1.Lost ", avgrtt => " $pingResult1.AvgRtt
    Write-Host "mac2 IP => " $ipaddress_mac2 " , lost => " $pingResult2.Lost ", avgrtt => " $pingResult2.AvgRtt

    $echoResult = "do nothing"
    $useMac1 = "use mac1"
    $useMac2 = "use mac2"

    if ($pingResult1.AvgRtt -lt 350 -and $pingResult2.AvgRtt -lt 350) {
        if ($pingResult1.Lost -eq 0 -and $pingResult2.Lost -eq 0) {
            Write-Host $echoResult
            return
        }
    }

    Write-Host "try to switch to default route"

    if ($pingResult1.Lost -ne $pingResult2.Lost) {
        if ($pingResult1.Lost -lt $pingResult2.Lost) {
            # use mac1
            $echoResult = $useMac1
        } else {
            # use mac2
            $echoResult = $useMac2
        }
    } elseif ($pingResult1.AvgRtt -lt $pingResult2.AvgRtt) {
        # use mac1
        $echoResult = $useMac1
    } elseif ($pingResult2.AvgRtt -lt $pingResult1.AvgRtt) {
        # use mac2
        $echoResult = $useMac2
    } else {
        # both are somewhat slow
        Write-Host "both are somewhat slow"
        return
    }
    
    Write-Host "echoResult =>" $echoResult

    if ($echoResult -eq $useMac2) {
        SetPrimaryGw $ipaddress_mac2 5 10
    } else {
        SetPrimaryGw $ipaddress_mac1 5 10
    }
}

try
{
    Write-Host "running => " (CountRunning)
    Write-Host "running foreground => " (CountRunningForeground)

    if (1 -lt (CountRunning) -Or (CountRunningForeground) -gt 1) {
        # enssures only one script is running in the background
        Write-Host "already running"
        return
    }

    While ($true) {
        if ((CountRunning) -gt 0 -And (CountRunningForeground) -gt 0) {
            # if foreground and background are running, will stop any of the two
            Write-Host "foreground started running, stopping current process."
            Write-Host "background Process ID => " (RunningBalancers).ProcessID
            return
        }
        
        if ((CountRunning) -gt 1) {
            # ensures only 1 background is running
            return
        }
        
        Write-Host "starting test"
        doWork
        Start-Sleep  -Second 3
    }
}
finally
{
    Write-Host "Exiting..."
    $Host.UI.RawUI.WindowTitle = "No Title"
}
