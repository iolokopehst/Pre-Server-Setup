<#
.SYNOPSIS
Prepares a fresh Windows Server for Active Directory, DNS, and DHCP installations.
.DESCRIPTION
- Checks for administrative privileges
- Configures a static IP address
- Renames the server
- Sets the time zone
- Enables remote management (optional)
- Verifies network connectivity
- Includes error handling and logging
#>

# ----------------------------
# Self-elevation
# ----------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "This script requires administrative privileges. Restarting with elevation..."
    Start-Process powershell.exe "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "`n=== Pre-Server Setup ===`n"

# ----------------------------
# Logging
# ----------------------------
$LogDir = "C:\Setup-Server"
$LogFile = "$LogDir\pre-server-setup.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Force

# ----------------------------
# Function for mandatory input
# ----------------------------
function ReadMandatory($prompt) {
    do {
        $input = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-Host "This field is required. Please enter a value." -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($input))
    return $input
}

# ----------------------------
# Function to convert subnet mask to prefix length
# ----------------------------
function Convert-SubnetToPrefix($subnet) {
    switch ($subnet) {
        '255.0.0.0' { return 8 }
        '255.255.0.0' { return 16 }
        '255.255.255.0' { return 24 }
        '255.255.255.128' { return 25 }
        '255.255.255.192' { return 26 }
        '255.255.255.224' { return 27 }
        '255.255.255.240' { return 28 }
        '255.255.255.248' { return 29 }
        '255.255.255.252' { return 30 }
        default { throw "Unsupported subnet mask: $subnet" }
    }
}

try {
    # ----------------------------
    # Configure static IP
    # ----------------------------
    Write-Host "`n=== Configure Static IP ===`n"

    # List network adapters
    $adapters = Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback'}
    if ($adapters.Count -eq 0) {
        throw "No active network adapters found. Please check network connectivity."
    }

    Write-Host "Active network adapters:"
    $adapters | ForEach-Object {Write-Host "$($_.InterfaceIndex): $($_.Name) - $($_.InterfaceDescription)"}

    $adapterIndex = ReadMandatory "Enter the InterfaceIndex of the adapter to configure"

    $adapter = $adapters | Where-Object {$_.InterfaceIndex -eq [int]$adapterIndex}
    if (-not $adapter) { throw "Invalid adapter selected." }

    # Prompt for IP configuration
    $IP = ReadMandatory "Enter the static IPv4 address (e.g., 192.168.10.10)"
    $Subnet = ReadMandatory "Enter the subnet mask (e.g., 255.255.255.0)"
    $Gateway = ReadMandatory "Enter the default gateway (e.g., 192.168.10.1)"
    $DNS = ReadMandatory "Enter the preferred DNS server (usually the server itself or your network DNS)"

    # Convert subnet mask to prefix length
    $PrefixLength = Convert-SubnetToPrefix $Subnet

    # Apply static IP
    Try {
        New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -IPAddress $IP -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $DNS -ErrorAction Stop
        Write-Host "Static IP configured successfully."
    } Catch {
        Write-Error "Failed to set static IP: $_"
    }

    # ----------------------------
    # Rename server
    # ----------------------------
    Write-Host "`n=== Rename Server ===`n"
    $newName = ReadMandatory "Enter the new hostname for this server"
    Rename-Computer -NewName $newName -Force -ErrorAction Stop
    Write-Host "Server renamed to $newName. A reboot is required to apply the name change."

    # ----------------------------
    # Set time zone
    # ----------------------------
    Write-Host "`n=== Set Time Zone ===`n"
    $tz = ReadMandatory "Enter the time zone (e.g., 'Pacific Standard Time')"
    try {
        Set-TimeZone -Id $tz -ErrorAction Stop
        Write-Host "Time zone set to $tz."
    } catch {
        Write-Error "Failed to set time zone: $_"
    }

    # ----------------------------
    # Enable remote management (optional)
    # ----------------------------
    Write-Host "`n=== Enable Remote Management (WinRM) ===`n"
    Enable-PSRemoting -Force -ErrorAction SilentlyContinue
    Write-Host "Remote management enabled."

    # ----------------------------
    # Test network connectivity
    # ----------------------------
    Write-Host "`n=== Test Network Connectivity ===`n"
    try {
        if (Test-Connection -ComputerName $Gateway -Count 2 -Quiet) {
            Write-Host "Gateway $Gateway is reachable."
        } else {
            Write-Warning "Cannot reach gateway $Gateway. Check network settings."
        }
    } catch {
        Write-Warning "Error testing connectivity: $_"
    }

} catch {
    Write-Error "A fatal error occurred: $_"
} finally {
    Stop-Transcript
    Write-Host "`nPre-server setup completed. Reboot the server if prompted (especially after renaming)."
    Read-Host "Press Enter to exit"
}
