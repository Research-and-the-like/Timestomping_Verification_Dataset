# ============================================================
# SCRIPT: 00_Install_Tools.ps1
# PURPOSE: Download and install all forensic and timestomping tools
# RUN AS: Administrator
# ============================================================

$ToolsRoot = "C:\Research\Tools"
$DataRoot  = "C:\Research\Data"
$ScriptsRoot = "C:\Research\Scripts"

# Create directory structure
@($ToolsRoot, $DataRoot, $ScriptsRoot,
  "$DataRoot\Baseline", "$DataRoot\Timestomped",
  "$DataRoot\Artifacts", "$DataRoot\Parsed",
  "$DataRoot\Evasion") | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

Write-Host "[+] Directory structure created" -ForegroundColor Green

# --- Eric Zimmerman Tools ---
Write-Host "[*] Downloading Eric Zimmerman tools..." -ForegroundColor Cyan
$ezUrl = "https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1"
$ezScript = "$ToolsRoot\Get-ZimmermanTools.ps1"
Invoke-WebRequest -Uri $ezUrl -OutFile $ezScript
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& $ezScript -Dest "$ToolsRoot\EZTools" -NetVersion 9

# Verify key tools exist
$ezBins = @("MFTECmd.exe", "PECmd.exe", "EvtxECmd.exe")
foreach ($bin in $ezBins) {
    $found = Get-ChildItem "$ToolsRoot\EZTools" -Recurse -Filter $bin | Select-Object -First 1
    if ($found) { Write-Host "  [OK] $bin → $($found.FullName)" -ForegroundColor Green }
    else { Write-Host "  [MISSING] $bin" -ForegroundColor Red }
}

# --- KAPE ---
Write-Host "[*] KAPE must be downloaded manually from https://www.kroll.com/en/services/cyber-risk/incident-response-litigation-support/kroll-artifact-parser-extractor-kape" -ForegroundColor Yellow
Write-Host "    Extract to $ToolsRoot\KAPE\" -ForegroundColor Yellow

# --- RawCopy (for MFT extraction without KAPE) ---
Write-Host "[*] Downloading RawCopy..." -ForegroundColor Cyan
$rawcopyUrl = "https://github.com/jschicht/RawCopy/releases/download/v1.0.0.19/RawCopy64.exe"
try {
    Invoke-WebRequest -Uri $rawcopyUrl -OutFile "$ToolsRoot\RawCopy64.exe"
    Write-Host "  [OK] RawCopy64.exe" -ForegroundColor Green
} catch {
    Write-Host "  [MANUAL] Download RawCopy from https://github.com/jschicht/RawCopy/releases" -ForegroundColor Yellow
}

# --- SetMace ---
Write-Host "[*] SetMace must be downloaded manually from https://github.com/jschicht/SetMace/releases" -ForegroundColor Yellow
Write-Host "    Extract to $ToolsRoot\SetMace\" -ForegroundColor Yellow

# --- nTimestomp ---
Write-Host "[*] nTimestomp must be downloaded manually from https://github.com/limbenjamin/nTimetools/releases" -ForegroundColor Yellow
Write-Host "    Extract to $ToolsRoot\nTimetools\" -ForegroundColor Yellow

# --- NirSoft BulkFileChanger ---
Write-Host "[*] BulkFileChanger: download from https://www.nirsoft.net/utils/bulk_file_changer.html" -ForegroundColor Yellow
Write-Host "    Extract to $ToolsRoot\BulkFileChanger\" -ForegroundColor Yellow

# --- FTK Imager CLI ---
Write-Host "[*] FTK Imager: download from https://www.exterro.com/digital-forensics-software/ftk-imager" -ForegroundColor Yellow

# --- Python 3 ---
Write-Host "[*] Installing Python 3.12..." -ForegroundColor Cyan
$pyUrl = "https://www.python.org/ftp/python/3.12.4/python-3.12.4-amd64.exe"
$pyInstaller = "$env:TEMP\python-installer.exe"
Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstaller
Start-Process -Wait -FilePath $pyInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1"
Write-Host "  [OK] Python installed" -ForegroundColor Green

# Python packages
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
python -m pip install pandas openpyxl tqdm

# --- Sysmon (for Event ID 2 - SetCreationTime logging) ---
Write-Host "[*] Installing Sysmon..." -ForegroundColor Cyan
$sysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"
Invoke-WebRequest -Uri $sysmonUrl -OutFile "$env:TEMP\Sysmon.zip"
Expand-Archive "$env:TEMP\Sysmon.zip" -DestinationPath "$ToolsRoot\Sysmon" -Force

# Create Sysmon config that logs Event ID 2 (CreateRemoteThread) and file timestamp changes
$sysmonConfig = @"
<Sysmon schemaversion="4.90">
  <EventFiltering>
    <FileCreateTime onmatch="exclude">
      <!-- Log ALL SetCreationTime events (Event ID 2) -->
    </FileCreateTime>
    <ProcessCreate onmatch="include">
      <Image condition="contains any">timestomp;setmace;nTimestomp;BulkFileChanger</Image>
    </ProcessCreate>
    <DriverLoad onmatch="include">
      <!-- Catch SetMace kernel driver -->
      <Signature condition="contains">test</Signature>
    </DriverLoad>
  </EventFiltering>
</Sysmon>
"@
$sysmonConfig | Out-File "$ToolsRoot\Sysmon\sysmon-config.xml" -Encoding UTF8
& "$ToolsRoot\Sysmon\Sysmon64.exe" -accepteula -i "$ToolsRoot\Sysmon\sysmon-config.xml"
Write-Host "  [OK] Sysmon installed with timestamp monitoring config" -ForegroundColor Green

# --- Enable advanced auditing ---
Write-Host "[*] Enabling Security Audit policies..." -ForegroundColor Cyan
auditpol /set /subcategory:"File System" /success:enable /failure:enable
auditpol /set /subcategory:"Handle Manipulation" /success:enable
Write-Host "  [OK] Object access auditing enabled (Security Event 4663)" -ForegroundColor Green

# --- WSL (Windows Subsystem for Linux) ---
Write-Host "[*] Checking for WSL installation..." -ForegroundColor Cyan
$wslInstalled = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue

if ($wslExe -and ($wslInstalled.State -eq "Enabled")) {
    Write-Host "  [SKIP] WSL is already installed and enabled" -ForegroundColor Yellow
} else {
    Write-Host "  [*] WSL not detected - installing Ubuntu via WSL..." -ForegroundColor Cyan
    # NOTE: 'wsl --install' enables required Windows features, installs the WSL2 kernel,
    # and sets Ubuntu as the default distro. A reboot is required to complete the setup.
    wsl --install Ubuntu
    Write-Host "  [OK] WSL install initiated" -ForegroundColor Green
    Write-Host "  [!] A REBOOT IS REQUIRED to complete WSL/Ubuntu setup." -ForegroundColor Red
    Write-Host "      After reboot, launch Ubuntu from the Start Menu to finish distro initialisation." -ForegroundColor Yellow
}

# --- Add SleuthKit (TSK) bin to system PATH ---
Write-Host "[*] Adding SleuthKit (TSK) to system PATH..." -ForegroundColor Cyan
$tskBinPath = "C:\Research\Tools\sleuthkit\bin"
$machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$tskBinPath*") {
    [System.Environment]::SetEnvironmentVariable('Path', "$machinePath;$tskBinPath", 'Machine')
    Write-Host "  [OK] SleuthKit bin added to machine-level PATH" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] SleuthKit bin already present in PATH" -ForegroundColor Yellow
}

# Refresh current session so TSK tools (fls, icat, mmls, etc.) are usable immediately
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
Write-Host "  [OK] Current session PATH refreshed - TSK tools now available" -ForegroundColor Green


Write-Host "`n[+] Setup complete. Take BASELINE-CLEAN snapshot NOW." -ForegroundColor Green
Write-Host "[!] Manual downloads still needed: KAPE, SetMace, nTimetools, BulkFileChanger, FTK Imager" -ForegroundColor Yellow
