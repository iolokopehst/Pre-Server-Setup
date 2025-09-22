<#
.SYNOPSIS
Prepares a Windows Server for Active Directory, DNS, and DHCP installations.
.DESCRIPTION
- Checks for administrative privileges
- Optionally configures a static IP address
- Renames the server (supports Domain Controllers)
- Sets the time zone with a user-friendly selection
- Enables remote management
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

# ----------------------------
# Function to validate hostname
# ----------------------------
function Validate-ComputerName($name) {
    if ($name.Length -lt 1 -or $name.Length -gt 63) { return $false }
    if ($name -match '^[0-9]+$') { return $false } # cannot be all numeric
    if ($name -match '^-|-$') { return $false }   # cannot start/end with hyphen
    if ($name -match '[^a-zA-Z0-9-]') { return $false } # invalid chars
    return $true
}

try {
    # ----------------------------
    # Optional static IP
    # ----------------------------
    $setStatic = Read-Host "Do you want to configure a static IP? (Y/N)"
    if ($setStatic -match '^[Yy]') {
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
            # Disable DHCP on the adapter
            Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Disabled -ErrorAction Stop

            # Remove any existing IPv4 addresses (except loopback)
            Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 |
                Where-Object {$_.IPAddress -ne "127.0.0.1"} |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

            # Add new static IP
            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -IPAddress $IP -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction Stop

            # Set DNS server
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $DNS -ErrorAction Stop

            Write-Host "Static IP configured successfully."
        } Catch {
            Write-Error "Failed to set static IP: $_"
        }
    } else {
        Write-Host "Skipping static IP configuration."
    }

    # ----------------------------
    # Rename server
    # ----------------------------
    Write-Host "`n=== Rename Server ===`n"
    do {
        $newName = ReadMandatory "Enter the new hostname for this server"
        if (-not (Validate-ComputerName $newName)) {
            Write-Host "Invalid hostname. Must be 1-63 characters, letters/numbers/hyphens only, cannot start/end with hyphen, cannot be all numeric." -ForegroundColor Red
            $newName = $null
        }
    } while (-not $newName)

    # Check if server is a domain controller
    $adFeature = Get-WindowsFeature -Name AD-Domain-Services
    $isDC = $false
    if ($adFeature.Installed) {
        try {
            $adRole = Get-ADDomainController -ErrorAction Stop
            if ($adRole) { $isDC = $true }
        } catch { $isDC = $false }
    }

    if ($isDC) {
        Write-Host "Server is a Domain Controller. Renaming using netdom..."
        $OldName = $env:COMPUTERNAME
        try {
            netdom computername $OldName /add:$newName
            netdom computername $OldName /makeprimary:$newName
            netdom computername $OldName /remove:$OldName
            Write-Host "DC renamed to $newName. A reboot is required."
        } catch {
            Write-Error "Failed to rename DC: $_"
        }
    } else {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        Write-Host "Server renamed to $newName. A reboot is required."
    }

    # ----------------------------
    # Set time zone (user-friendly)
    # ----------------------------
    Write-Host "`n=== Set Time Zone ===`n"

    $timeZones = Get-TimeZone -ListAvailable | Sort-Object Id

    for ($i = 0; $i -lt $timeZones.Count; $i++) {
        Write-Host "$i : $($timeZones[$i].DisplayName)"
    }

    do {
        $selection = Read-Host "Enter the number corresponding to your time zone"
        if ($selection -match '^\d+$' -and $selection -ge 0 -and $selection -lt $timeZones.Count) {
            $tz = $timeZones[$selection].Id
            Write-Host "You selected: $($timeZones[$selection].DisplayName)"
            break
        } else {
            Write-Host "Invalid selection. Please enter a number between 0 and $($timeZones.Count - 1)" -ForegroundColor Red
        }
    } while ($true)

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
        if ($setStatic -match '^[Yy]') {
            $pingTarget = $Gateway
        } else {
            $pingTarget = "8.8.8.8"
        }

        if (
