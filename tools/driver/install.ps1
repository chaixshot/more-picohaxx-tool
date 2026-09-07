# Self-elevate to Administrator if not already running as Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $proc = Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -PassThru -Wait
    exit $proc.ExitCode
}

# Find all .inf drivers in script's folder and subfolders
Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "*.inf" | ForEach-Object {
    $infFile = $_
    $infName = $infFile.Name

    Write-Host "Checking for existing installations of $infName..." -ForegroundColor Cyan

    # Fetch output from pnputil
    $enumOutput = (pnputil /enum-drivers) -join "`n"
    
    # Split output into individual driver entry blocks (handles double newlines)
    $driverBlocks = $enumOutput -split "(?m)\r?\n\r?\n"

    foreach ($block in $driverBlocks) {
        # Check if the block contains the INF file name
        if ($block -match "(?i)$([regex]::Escape($infName))") {
            # Extract the oem*.inf name using regex matching regardless of language label
            if ($block -match "(?i)(oem\d+\.inf)") {
                $publishedName = $Matches[1]
                Write-Host " Removing existing driver: $publishedName ($infName)..." -ForegroundColor Yellow
                
                # Delete the driver package
                $null = pnputil /delete-driver $publishedName /uninstall /force
                
                # Fallback for older Windows 10 builds if /uninstall switch fails
                if ($LASTEXITCODE -ne 0) {
                    $null = pnputil /delete-driver $publishedName /force
                    $null = pnputil -d $publishedName
                }
            }
        }
    }

    Write-Host "Installing: $($infFile.FullName)" -ForegroundColor Green
    pnputil /add-driver "`"$($infFile.FullName)`"" /install
}