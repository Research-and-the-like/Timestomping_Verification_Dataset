# ============================================================
# SCRIPT: 02_Legitimate_Operations.ps1
# PURPOSE: Execute all 15 baseline legitimate operations (L1-L15)
#          with automated pre/post artifact captures per operation.
#          Operations that cannot be fully scripted will pause
#          and prompt the user for manual execution.
# RUN AS: Administrator
# USAGE:  .\02_Legitimate_Operations.ps1                  (run all)
#         .\02_Legitimate_Operations.ps1 -Operations L4    (run one)
#         .\02_Legitimate_Operations.ps1 -Operations L1,L2,L3 (run subset)
#         .\02_Legitimate_Operations.ps1 -SkipCapture      (skip artifact capture, for testing)
#         .\02_Legitimate_Operations.ps1 -OSTag "w10"      (tag artifacts with OS version)
# VERSION: 1.0 (April 2026)
# ============================================================

param(
    [string[]]$Operations,
    [string]$OSTag = "w10",
    [switch]$SkipCapture,
    [string]$CaptureScript = "C:\Research\Scripts\01_Capture_Artifacts.ps1",
    [int]$IdleWaitSeconds = 300
)

$ErrorActionPreference = "Continue"
$DataRoot   = "C:\Research\Data"
$BaselineDir = "$DataRoot\Baseline"
$TestDir    = "$BaselineDir\TestFiles"
$ToolsRoot  = "C:\Research\Tools"
$LogFile    = "$BaselineDir\baseline_operations_log.csv"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-OpHeader {
    param([string]$Code, [string]$Name, [string]$Type)
    $color = switch ($Type) {
        "AUTO"   { "Green" }
        "SEMI"   { "Yellow" }
        "MANUAL" { "Red" }
        default  { "Cyan" }
    }
    Write-Host "`n$('='*70)" -ForegroundColor $color
    Write-Host "  [$Code] $Name  ($Type)" -ForegroundColor $color
    Write-Host "$('='*70)" -ForegroundColor $color
}

function Invoke-ArtifactCapture {
    param([string]$Tag)
    if ($SkipCapture) {
        Write-Host "  [SKIP] Artifact capture skipped (-SkipCapture)" -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path $CaptureScript)) {
        Write-Host "  [ERROR] Capture script not found: $CaptureScript" -ForegroundColor Red
        Write-Host "  [ERROR] Copy 01_Capture_Artifacts.ps1 to C:\Research\Scripts\" -ForegroundColor Red
        return
    }
    Write-Host "  [CAPTURE] Running artifact capture: $Tag" -ForegroundColor Cyan
    & $CaptureScript -Tag $Tag
}

function Wait-SystemIdle {
    param([int]$Seconds = $IdleWaitSeconds)
    Write-Host "  [WAIT] Waiting $Seconds seconds for system idle..." -ForegroundColor DarkGray
    $interval = 30
    $elapsed = 0
    while ($elapsed -lt $Seconds) {
        $remaining = $Seconds - $elapsed
        $chunk = [math]::Min($interval, $remaining)
        Write-Progress -Activity "System Idle Wait" -Status "$remaining seconds remaining" -PercentComplete (($elapsed / $Seconds) * 100)
        Start-Sleep -Seconds $chunk
        $elapsed += $chunk
    }
    Write-Progress -Activity "System Idle Wait" -Completed
}

function Pause-ForManualStep {
    param([string]$Instruction)
    Write-Host "`n  [MANUAL STEP REQUIRED]" -ForegroundColor Red
    Write-Host "  $Instruction" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press ENTER when you have completed the manual step"
}

function Log-Operation {
    param(
        [string]$Code,
        [string]$Name,
        [string]$Status,
        [string]$Notes = ""
    )
    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date -Format 'o')
        OSTag     = $OSTag
        OpCode    = $Code
        OpName    = $Name
        Status    = $Status
        Notes     = $Notes
    }
    if (-not (Test-Path $LogFile)) {
        $entry | Export-Csv $LogFile -NoTypeInformation
    } else {
        $entry | Export-Csv $LogFile -Append -NoTypeInformation
    }
}

function Invoke-FullOperation {
    param(
        [string]$Code,
        [string]$Name,
        [string]$Type,
        [scriptblock]$Action
    )
    Write-OpHeader -Code $Code -Name $Name -Type $Type
    $tag = "$Code-$OSTag"

    Invoke-ArtifactCapture -Tag "pre-$tag"

    try {
        & $Action
        Wait-SystemIdle
        Log-Operation -Code $Code -Name $Name -Status "OK"
    } catch {
        Write-Host "  [ERROR] $Code failed: $_" -ForegroundColor Red
        Log-Operation -Code $Code -Name $Name -Status "ERROR" -Notes "$_"
    }

    Invoke-ArtifactCapture -Tag "post-$tag"
    Write-Host "  [DONE] $Code complete.`n" -ForegroundColor Green
}

# ============================================================
# SETUP
# ============================================================

New-Item -ItemType Directory -Path $BaselineDir -Force | Out-Null
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null

# Create a set of seed test files that multiple operations will use
if (-not (Test-Path "$TestDir\seed_complete.flag")) {
    Write-Host "[SETUP] Creating seed test files..." -ForegroundColor Cyan
    $extensions = @("txt","docx","pdf","jpg","exe","dll","log","csv","xml","ini")
    foreach ($ext in $extensions) {
        1..5 | ForEach-Object {
            $f = "$TestDir\testfile_$($_).$ext"
            $content = "Seed file $_ ($ext) generated $(Get-Date -Format 'o') $([guid]::NewGuid())"
            [System.IO.File]::WriteAllText($f, $content)
        }
    }
    "done" | Out-File "$TestDir\seed_complete.flag"
    Write-Host "[SETUP] Created 50 seed test files" -ForegroundColor Green
}

# ============================================================
# OPERATION DEFINITIONS
# ============================================================

$AllOperations = [ordered]@{}

# ----------------------------------------------------------
# L1: Windows Update (AUTO)
# ----------------------------------------------------------
$AllOperations["L1"] = @{
    Name = "Windows Update"
    Type = "AUTO"
    Action = {
        Write-Host "  [L1] Checking for and installing Windows Updates..." -ForegroundColor Gray

        # Try PSWindowsUpdate module first (cleanest automation)
        if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
            Import-Module PSWindowsUpdate
            Write-Host "  [L1] Using PSWindowsUpdate module" -ForegroundColor Gray
            $updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot -Verbose
            if ($updates) {
                Write-Host "  [L1] Found $($updates.Count) updates, installing..." -ForegroundColor Gray
                Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false
            } else {
                Write-Host "  [L1] No updates available. Forcing scan anyway for timestamp activity." -ForegroundColor Yellow
            }
        } else {
            # Fallback: UsoClient (built-in, less control)
            Write-Host "  [L1] PSWindowsUpdate not installed. Using UsoClient (less verbose)." -ForegroundColor Yellow
            Write-Host "  [L1] TIP: Install-Module PSWindowsUpdate -Force for better control" -ForegroundColor Yellow
            UsoClient StartScan
            Start-Sleep -Seconds 10
            UsoClient StartDownload
            Start-Sleep -Seconds 30
            UsoClient StartInstall
        }

        # Even if no updates install, the scan itself generates MFT activity
        # on SoftwareDistribution, WinSxS, catroot2 directories
        Write-Host "  [L1] Update cycle complete. Scan/download/install all generate timestamp activity." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L2: MSI Install (AUTO)
# ----------------------------------------------------------
$AllOperations["L2"] = @{
    Name = "MSI Package Installation"
    Type = "AUTO"
    Action = {
        Write-Host "  [L2] Downloading and installing MSI packages..." -ForegroundColor Gray
        $msiDir = "$BaselineDir\L2_Installers"
        New-Item -ItemType Directory -Path $msiDir -Force | Out-Null

        # 7-Zip (MSI available)
        $sevenZipUrl = "https://www.7-zip.org/a/7z2407-x64.msi"
        $sevenZipMsi = "$msiDir\7z2407-x64.msi"
        Write-Host "  [L2] Downloading 7-Zip MSI..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $sevenZipUrl -OutFile $sevenZipMsi -UseBasicParsing
            Write-Host "  [L2] Installing 7-Zip via msiexec..." -ForegroundColor Gray
            Start-Process msiexec -ArgumentList "/i `"$sevenZipMsi`" /qn /norestart" -Wait
            Write-Host "  [L2] 7-Zip installed" -ForegroundColor Green
        } catch {
            Write-Host "  [L2] 7-Zip download failed: $_. Skipping." -ForegroundColor Yellow
        }

        # Notepad++ (MSI-like silent install available via /S)
        # Using the Notepad++ installer which supports /S for silent
        $nppUrl = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.6.9/npp.8.6.9.Installer.x64.exe"
        $nppExe = "$msiDir\npp_installer.exe"
        Write-Host "  [L2] Downloading Notepad++..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $nppUrl -OutFile $nppExe -UseBasicParsing
            Write-Host "  [L2] Installing Notepad++ (silent)..." -ForegroundColor Gray
            Start-Process $nppExe -ArgumentList "/S" -Wait
            Write-Host "  [L2] Notepad++ installed" -ForegroundColor Green
        } catch {
            Write-Host "  [L2] Notepad++ download failed: $_. Skipping." -ForegroundColor Yellow
        }

        Write-Host "  [L2] MSI installations complete. Installer timestamps are preserved per Windows Installer spec." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L3: EXE/NSIS Install (AUTO)
# ----------------------------------------------------------
$AllOperations["L3"] = @{
    Name = "EXE/NSIS Package Installation"
    Type = "AUTO"
    Action = {
        Write-Host "  [L3] Downloading and installing EXE/NSIS packages..." -ForegroundColor Gray
        $exeDir = "$BaselineDir\L3_Installers"
        New-Item -ItemType Directory -Path $exeDir -Force | Out-Null

        # Git for Windows (NSIS installer, supports /VERYSILENT)
        $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe"
        $gitExe = "$exeDir\Git-installer.exe"
        Write-Host "  [L3] Downloading Git for Windows..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $gitUrl -OutFile $gitExe -UseBasicParsing
            Write-Host "  [L3] Installing Git (silent)..." -ForegroundColor Gray
            Start-Process $gitExe -ArgumentList "/VERYSILENT /NORESTART" -Wait
            Write-Host "  [L3] Git installed" -ForegroundColor Green
        } catch {
            Write-Host "  [L3] Git download failed: $_. Skipping." -ForegroundColor Yellow
        }

        # VS Code (NSIS, supports /VERYSILENT)
        $vscUrl = "https://update.code.visualstudio.com/latest/win32-x64/stable"
        $vscExe = "$exeDir\VSCode-installer.exe"
        Write-Host "  [L3] Downloading VS Code..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $vscUrl -OutFile $vscExe -UseBasicParsing
            Write-Host "  [L3] Installing VS Code (silent)..." -ForegroundColor Gray
            Start-Process $vscExe -ArgumentList "/VERYSILENT /NORESTART /MERGETASKS=!runcode" -Wait
            Write-Host "  [L3] VS Code installed" -ForegroundColor Green
        } catch {
            Write-Host "  [L3] VS Code download failed: $_. Skipping." -ForegroundColor Yellow
        }

        Write-Host "  [L3] EXE/NSIS installations complete. NSIS extractors may preserve original timestamps." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L4: ZIP Extraction (AUTO) ** CRITICAL FP SOURCE **
# ----------------------------------------------------------
$AllOperations["L4"] = @{
    Name = "ZIP Extraction (CRITICAL FP SOURCE)"
    Type = "AUTO"
    Action = {
        Write-Host "  [L4] Downloading and extracting ZIP archives..." -ForegroundColor Gray
        Write-Host "  [L4] THIS IS THE MOST IMPORTANT BASELINE CATEGORY." -ForegroundColor Red
        Write-Host "  [L4] ZIP extraction preserves embedded timestamps, which mimics" -ForegroundColor Red
        Write-Host "  [L4] the classic timestomping signature (SI Created < FN Created)." -ForegroundColor Red
        $zipDir = "$BaselineDir\L4_ZipExtraction"
        New-Item -ItemType Directory -Path $zipDir -Force | Out-Null

        # Sysinternals Suite (large, diverse timestamps)
        $sysUrl = "https://download.sysinternals.com/files/SysinternalsSuite.zip"
        $sysZip = "$zipDir\SysinternalsSuite.zip"
        Write-Host "  [L4] Downloading Sysinternals Suite..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $sysUrl -OutFile $sysZip -UseBasicParsing
            Write-Host "  [L4] Extracting Sysinternals (Expand-Archive)..." -ForegroundColor Gray
            Expand-Archive -Path $sysZip -DestinationPath "$zipDir\SysinternalsSuite" -Force
            Write-Host "  [L4] Sysinternals extracted" -ForegroundColor Green
        } catch {
            Write-Host "  [L4] Sysinternals download failed: $_" -ForegroundColor Yellow
        }

        # Also test with 7-Zip extraction (different timestamp handling)
        $sevenZip = "C:\Program Files\7-Zip\7z.exe"
        if (Test-Path $sevenZip) {
            Write-Host "  [L4] Re-extracting with 7-Zip for comparison..." -ForegroundColor Gray
            New-Item -ItemType Directory -Path "$zipDir\SysinternalsSuite_7z" -Force | Out-Null
            & $sevenZip x $sysZip -o"$zipDir\SysinternalsSuite_7z" -y | Out-Null
            Write-Host "  [L4] 7-Zip extraction complete" -ForegroundColor Green
        }

        # Also extract a second archive for variety
        $curlUrl = "https://curl.se/windows/dl-8.8.0_1/curl-8.8.0_1-win64-mingw.zip"
        $curlZip = "$zipDir\curl.zip"
        Write-Host "  [L4] Downloading curl archive..." -ForegroundColor Gray
        try {
            Invoke-WebRequest -Uri $curlUrl -OutFile $curlZip -UseBasicParsing
            Expand-Archive -Path $curlZip -DestinationPath "$zipDir\curl" -Force
            Write-Host "  [L4] curl extracted" -ForegroundColor Green
        } catch {
            Write-Host "  [L4] curl download failed: $_. Non-critical." -ForegroundColor Yellow
        }

        Write-Host "  [L4] ZIP extractions complete. Check for SI Created < FN Created in the diff." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L5: File Copy Operations (AUTO)
# ----------------------------------------------------------
$AllOperations["L5"] = @{
    Name = "File Copy Operations"
    Type = "AUTO"
    Action = {
        Write-Host "  [L5] Executing file copy operations (4 methods)..." -ForegroundColor Gray
        $copyDir = "$BaselineDir\L5_FileCopy"
        New-Item -ItemType Directory -Path $copyDir -Force | Out-Null

        # Method 1: Copy-Item (PowerShell native)
        $m1 = "$copyDir\Method1_CopyItem"
        New-Item -ItemType Directory -Path $m1 -Force | Out-Null
        Write-Host "  [L5] Method 1: Copy-Item..." -ForegroundColor Gray
        Copy-Item "$TestDir\*" -Destination $m1 -Recurse -Force
        # Copy-Item preserves LastWriteTime but sets CreationTime to NOW

        # Method 2: robocopy (preserves timestamps by default)
        $m2 = "$copyDir\Method2_Robocopy"
        New-Item -ItemType Directory -Path $m2 -Force | Out-Null
        Write-Host "  [L5] Method 2: robocopy..." -ForegroundColor Gray
        robocopy $TestDir $m2 /E /COPY:DAT /R:0 /W:0 | Out-Null
        # robocopy with /COPY:DAT preserves Data, Attributes, Timestamps

        # Method 3: robocopy with /DCOPY:T (also preserves directory timestamps)
        $m3 = "$copyDir\Method3_Robocopy_DCOPY"
        New-Item -ItemType Directory -Path $m3 -Force | Out-Null
        Write-Host "  [L5] Method 3: robocopy /DCOPY:T..." -ForegroundColor Gray
        robocopy $TestDir $m3 /E /COPY:DAT /DCOPY:T /R:0 /W:0 | Out-Null

        # Method 4: xcopy (legacy, different timestamp behavior)
        $m4 = "$copyDir\Method4_Xcopy"
        New-Item -ItemType Directory -Path $m4 -Force | Out-Null
        Write-Host "  [L5] Method 4: xcopy..." -ForegroundColor Gray
        xcopy "$TestDir\*.*" "$m4\" /E /I /Y /Q | Out-Null
        # xcopy preserves LastWriteTime, sets CreationTime to NOW

        # Method 5: .NET File.Copy (what many apps use internally)
        $m5 = "$copyDir\Method5_DotNet"
        New-Item -ItemType Directory -Path $m5 -Force | Out-Null
        Write-Host "  [L5] Method 5: .NET File.Copy..." -ForegroundColor Gray
        Get-ChildItem "$TestDir\*" -File | ForEach-Object {
            [System.IO.File]::Copy($_.FullName, "$m5\$($_.Name)", $true)
        }

        Write-Host "  [L5] 5 copy methods complete. Compare timestamp behavior across methods." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L6: File Move Operations (AUTO)
# ----------------------------------------------------------
$AllOperations["L6"] = @{
    Name = "File Move Operations"
    Type = "AUTO"
    Action = {
        Write-Host "  [L6] Executing file move operations..." -ForegroundColor Gray
        $moveDir = "$BaselineDir\L6_FileMove"
        New-Item -ItemType Directory -Path $moveDir -Force | Out-Null

        # Create fresh files for moving (don't consume the seed files)
        $srcDir = "$moveDir\_source"
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        1..10 | ForEach-Object {
            $f = "$srcDir\movefile_$_.txt"
            Set-Content $f -Value "Move test file $_ $(Get-Date -Format 'o') $([guid]::NewGuid())"
        }

        # Method 1: Same-volume move (rename operation, preserves everything)
        $m1 = "$moveDir\Method1_SameVolume"
        New-Item -ItemType Directory -Path $m1 -Force | Out-Null
        Write-Host "  [L6] Method 1: Same-volume move (rename)..." -ForegroundColor Gray
        1..5 | ForEach-Object {
            Move-Item "$srcDir\movefile_$_.txt" -Destination "$m1\movefile_$_.txt"
        }
        # Same-volume move = MFT rename, preserves both $SI and $FN

        # Method 2: Cross-volume move (if second disk exists and is writable)
        $secondDisk = "D:\"
        $crossVolumeDone = $false
        if (Test-Path $secondDisk) {
            try {
                $m2 = "${secondDisk}Research\L6_CrossVolume"
                New-Item -ItemType Directory -Path $m2 -Force -ErrorAction Stop | Out-Null
                Write-Host "  [L6] Method 2: Cross-volume move (to D:)..." -ForegroundColor Gray
                6..10 | ForEach-Object {
                    Move-Item "$srcDir\movefile_$_.txt" -Destination "$m2\movefile_$_.txt"
                }
                $crossVolumeDone = $true
                # Cross-volume = copy + delete. New MFT entry on target, $FN Created = NOW
            } catch {
                Write-Host "  [L6] D: exists but is not writable (PermissionDenied). Skipping cross-volume." -ForegroundColor Yellow
                Write-Host "  [L6] Fix: Open Disk Management, right-click D:, ensure full NTFS permissions for your user." -ForegroundColor Yellow
            }
        }
        if (-not $crossVolumeDone) {
            Write-Host "  [L6] Cross-volume move skipped. Behavior note: cross-volume = copy+delete, FN Created = NOW." -ForegroundColor Yellow
        }

        # Method 3: Rename in place (changes $FN, keeps $SI)
        $m3 = "$moveDir\Method3_Rename"
        New-Item -ItemType Directory -Path $m3 -Force | Out-Null
        Write-Host "  [L6] Method 3: In-place rename..." -ForegroundColor Gray
        1..5 | ForEach-Object {
            $src = "$m1\movefile_$_.txt"
            if (Test-Path $src) {
                Rename-Item $src -NewName "renamed_$_.txt"
            }
        }
        # Rename updates $FN but not $SI

        Write-Host "  [L6] Move operations complete. Same-volume preserves all; cross-volume creates new $FN." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L7: Browser Download (MANUAL)
# ----------------------------------------------------------
$AllOperations["L7"] = @{
    Name = "Browser Download"
    Type = "MANUAL"
    Action = {
        Write-Host "  [L7] This operation MUST be done manually through real browsers." -ForegroundColor Red
        Write-Host "  [L7] PowerShell Invoke-WebRequest does NOT create the same artifact" -ForegroundColor Red
        Write-Host "  [L7] profile (no Zone.Identifier ADS, no browser cache entries)." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Perform the following downloads:" -ForegroundColor Yellow
        Write-Host "    1. Open Microsoft Edge, download https://curl.se/windows/dl-8.8.0_1/curl-8.8.0_1-win64-mingw.zip" -ForegroundColor Yellow
        Write-Host "    2. Open Chrome (if installed), download https://download.sysinternals.com/files/Autoruns.zip" -ForegroundColor Yellow
        Write-Host "    3. Open Firefox (if installed), download https://download.sysinternals.com/files/ProcessMonitor.zip" -ForegroundColor Yellow
        Write-Host "    4. Save all files to C:\Research\Data\Baseline\L7_BrowserDownload\" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Key artifacts to watch:" -ForegroundColor Cyan
        Write-Host "    - Zone.Identifier ADS (Mark of the Web)" -ForegroundColor Cyan
        Write-Host "    - Browser cache and history entries" -ForegroundColor Cyan
        Write-Host "    - Different timestamp behavior per browser" -ForegroundColor Cyan

        New-Item -ItemType Directory -Path "$BaselineDir\L7_BrowserDownload" -Force | Out-Null
        Pause-ForManualStep "Complete all browser downloads listed above, then press ENTER."
    }
}

# ----------------------------------------------------------
# L8: OneDrive Sync (MANUAL)
# ----------------------------------------------------------
$AllOperations["L8"] = @{
    Name = "OneDrive Sync"
    Type = "MANUAL"
    Action = {
        Write-Host "  [L8] This operation MUST be done manually through OneDrive." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Perform the following:" -ForegroundColor Yellow
        Write-Host "    1. Sign into OneDrive (if not already)" -ForegroundColor Yellow
        Write-Host "    2. Create 5 new text files in the OneDrive folder" -ForegroundColor Yellow
        Write-Host "    3. Wait for sync to complete (green checkmarks)" -ForegroundColor Yellow
        Write-Host "    4. Modify 2 of the files from another device or OneDrive web" -ForegroundColor Yellow
        Write-Host "    5. Wait for sync to pull the changes down" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Key artifacts to watch:" -ForegroundColor Cyan
        Write-Host "    - Cloud-origin timestamps (may differ from local clock)" -ForegroundColor Cyan
        Write-Host "    - Sync re-creates files, updating $FN Created" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  If OneDrive is not configured on this VM, type SKIP and press ENTER." -ForegroundColor DarkGray

        $response = Read-Host "  Press ENTER when done, or type SKIP"
        if ($response -eq "SKIP") {
            Write-Host "  [L8] Skipped (OneDrive not configured)." -ForegroundColor Yellow
            Log-Operation -Code "L8" -Name "OneDrive Sync" -Status "SKIPPED" -Notes "OneDrive not configured on this VM"
        }
    }
}

# ----------------------------------------------------------
# L9: System Restore (SEMI-AUTO)
# ----------------------------------------------------------
$AllOperations["L9"] = @{
    Name = "System Restore"
    Type = "SEMI"
    Action = {
        Write-Host "  [L9] Creating System Restore point, modifying files, then restoring..." -ForegroundColor Gray

        # Check if System Protection is enabled
        $srEnabled = (Get-ComputerRestorePoint -ErrorAction SilentlyContinue) -ne $null -or $true
        
        # Enable System Protection on C: if not already
        try {
            Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        } catch {
            Write-Host "  [L9] Could not enable System Protection. May need manual setup." -ForegroundColor Yellow
        }

        # Create restore point
        Write-Host "  [L9] Creating restore point..." -ForegroundColor Gray
        try {
            Checkpoint-Computer -Description "NTFS_Research_L9_Baseline" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            Write-Host "  [L9] Restore point created" -ForegroundColor Green
        } catch {
            Write-Host "  [L9] Restore point creation failed: $_" -ForegroundColor Yellow
            Write-Host "  [L9] Windows limits restore points to 1 per 24 hours by default." -ForegroundColor Yellow
            Write-Host "  [L9] Workaround: Set HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\SystemRestorePointCreationFrequency to 0" -ForegroundColor Yellow
            return
        }

        # Create files that will be affected by restore
        $restoreDir = "$BaselineDir\L9_SystemRestore"
        New-Item -ItemType Directory -Path $restoreDir -Force | Out-Null
        1..10 | ForEach-Object {
            Set-Content "$restoreDir\pre_restore_$_.txt" -Value "Created before restore point $(Get-Date -Format 'o')"
        }

        # Modify some files
        Start-Sleep -Seconds 5
        1..5 | ForEach-Object {
            Add-Content "$restoreDir\pre_restore_$_.txt" -Value "Modified after restore point $(Get-Date -Format 'o')"
        }

        Write-Host "  [L9] Files created and modified post-restore-point." -ForegroundColor Gray
        Write-Host "  [L9] To complete this test, you would need to perform a System Restore" -ForegroundColor Yellow
        Write-Host "  [L9] which requires a reboot. The timestamps on restored files should" -ForegroundColor Yellow
        Write-Host "  [L9] revert to their pre-modification state, which can look like timestomping." -ForegroundColor Yellow
        
        Pause-ForManualStep "Perform System Restore via rstrui.exe if desired, reboot, then re-run capture. Press ENTER to continue without restoring."
    }
}

# ----------------------------------------------------------
# L10: Antivirus Scan (AUTO)
# ----------------------------------------------------------
$AllOperations["L10"] = @{
    Name = "Windows Defender AV Scan"
    Type = "AUTO"
    Action = {
        Write-Host "  [L10] Creating EICAR test file and running Defender scan..." -ForegroundColor Gray
        $avDir = "$BaselineDir\L10_AVScan"
        New-Item -ItemType Directory -Path $avDir -Force | Out-Null

        # Create EICAR test file (standard AV test string)
        # This is NOT malware. It's the industry-standard test string.
        $eicar = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
        try {
            # Temporarily exclude directory so we can write the file
            Add-MpPreference -ExclusionPath $avDir -ErrorAction SilentlyContinue
            Set-Content "$avDir\eicar_test.txt" -Value $eicar -NoNewline
            Write-Host "  [L10] EICAR test file created" -ForegroundColor Gray
        } catch {
            Write-Host "  [L10] Could not create EICAR (Defender may have blocked it). Expected." -ForegroundColor Yellow
        }

        # Create some normal files to scan alongside
        1..20 | ForEach-Object {
            Set-Content "$avDir\clean_file_$_.txt" -Value "Clean file $_ $(Get-Date -Format 'o') $([guid]::NewGuid())"
        }

        # Remove exclusion and trigger scan
        Remove-MpPreference -ExclusionPath $avDir -ErrorAction SilentlyContinue

        Write-Host "  [L10] Running Defender quick scan on test directory..." -ForegroundColor Gray
        Start-MpScan -ScanType QuickScan
        Start-Sleep -Seconds 30

        # Also run a custom scan on the specific directory
        Write-Host "  [L10] Running custom scan on $avDir..." -ForegroundColor Gray
        Start-MpScan -ScanType CustomScan -ScanPath $avDir
        Start-Sleep -Seconds 15

        # Check if EICAR was quarantined
        $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue
        if ($threats) {
            Write-Host "  [L10] Threats detected and quarantined: $($threats.Count)" -ForegroundColor Green
            Write-Host "  [L10] Quarantine alters timestamps. Check the diff for $SI changes on eicar_test.txt" -ForegroundColor Gray
        }

        Write-Host "  [L10] AV scan complete. Quarantine/restore cycle modifies timestamps." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L11: Search Indexing (SEMI-AUTO)
# ----------------------------------------------------------
$AllOperations["L11"] = @{
    Name = "Windows Search Indexing"
    Type = "SEMI"
    Action = {
        Write-Host "  [L11] Triggering Windows Search indexing on test directory..." -ForegroundColor Gray
        $indexDir = "$BaselineDir\L11_SearchIndex"
        New-Item -ItemType Directory -Path $indexDir -Force | Out-Null

        # Create content-rich files for the indexer to chew on
        1..30 | ForEach-Object {
            $content = @"
Document Number: $_
Title: Research Test Document $_
Author: NTFS Timestomping Research
Date: $(Get-Date -Format 'yyyy-MM-dd')
Content: This is a test document with searchable keywords including
forensics, timestamp, NTFS, investigation, evidence, and analysis.
Additional padding: $([guid]::NewGuid().ToString() * 5)
"@
            Set-Content "$indexDir\searchable_doc_$_.txt" -Value $content
        }

        # Add directory to Windows Search index locations
        Write-Host "  [L11] Adding $indexDir to Search index scope..." -ForegroundColor Gray
        try {
            $searchManager = New-Object -ComObject Microsoft.Search.AdminInterface
            $catalogMgr = $searchManager.GetCatalog("SystemIndex")
            $crawlScopeManager = $catalogMgr.GetCrawlScopeManager()
            $crawlScopeManager.AddDefaultScopeRule("file:///$($indexDir.Replace('\','/'))", $true, 3)
            $crawlScopeManager.SaveAll()
            Write-Host "  [L11] Index scope updated. Waiting for indexer..." -ForegroundColor Gray
        } catch {
            Write-Host "  [L11] Could not update index scope via COM. Using alternative method." -ForegroundColor Yellow
            # Alternative: just let the indexer find it naturally
        }

        # Force a re-index
        try {
            $searchService = Get-Service WSearch -ErrorAction Stop
            if ($searchService.Status -ne 'Running') {
                Start-Service WSearch
            }
            # Touch the files to trigger re-indexing
            Get-ChildItem "$indexDir\*" -File | ForEach-Object { $_.LastWriteTime = $_.LastWriteTime }
        } catch {
            Write-Host "  [L11] Windows Search service issue: $_" -ForegroundColor Yellow
        }

        Write-Host "  [L11] Indexer triggered. Last Access timestamps may be updated." -ForegroundColor Gray
        Write-Host "  [L11] Wait time is included in the standard idle period." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L12: Defragmentation (AUTO)
# ----------------------------------------------------------
$AllOperations["L12"] = @{
    Name = "Disk Defragmentation/Optimization"
    Type = "AUTO"
    Action = {
        Write-Host "  [L12] Running disk optimization..." -ForegroundColor Gray
        $defragDir = "$BaselineDir\L12_Defrag"
        New-Item -ItemType Directory -Path $defragDir -Force | Out-Null

        # Create fragmented files by writing small files then expanding them
        Write-Host "  [L12] Creating test files to fragment..." -ForegroundColor Gray
        1..50 | ForEach-Object {
            $f = "$defragDir\frag_$_.bin"
            $randomBytes = New-Object byte[] (Get-Random -Min 4096 -Max 65536)
            (New-Object Random).NextBytes($randomBytes)
            [System.IO.File]::WriteAllBytes($f, $randomBytes)
        }

        # Run defrag analysis first
        Write-Host "  [L12] Analyzing volume fragmentation..." -ForegroundColor Gray
        $analysis = defrag C: /A 2>&1
        $analysis | Out-File "$defragDir\defrag_analysis_pre.txt"

        # Run optimization (uses TRIM on SSD, defrag on HDD)
        Write-Host "  [L12] Running optimization (defrag /O)..." -ForegroundColor Gray
        defrag C: /O 2>&1 | Out-File "$defragDir\defrag_result.txt"

        Write-Host "  [L12] Defrag/optimization complete. Background maintenance may update timestamps." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L13: WSL File Operations (SEMI-AUTO)
# ----------------------------------------------------------
$AllOperations["L13"] = @{
    Name = "WSL File Operations"
    Type = "SEMI"
    Action = {
        Write-Host "  [L13] Executing WSL file operations on NTFS..." -ForegroundColor Gray
        $wslDir = "$BaselineDir\L13_WSL"
        New-Item -ItemType Directory -Path $wslDir -Force | Out-Null

        # Check if WSL is available
        $wslCheck = wsl --list --quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [L13] WSL not installed or no distributions found." -ForegroundColor Yellow
            Write-Host "  [L13] To install: wsl --install" -ForegroundColor Yellow
            Write-Host "  [L13] Skipping WSL operations." -ForegroundColor Yellow
            Log-Operation -Code "L13" -Name "WSL File Operations" -Status "SKIPPED" -Notes "WSL not available"
            return
        }

        # Convert Windows path to WSL path
        $wslPath = "/mnt/c/Research/Data/Baseline/L13_WSL"

        # Create files from WSL
        Write-Host "  [L13] Creating files via WSL touch/echo..." -ForegroundColor Gray
        wsl bash -c "for i in {1..10}; do echo 'WSL-created file `$i' > '$wslPath/wsl_file_`$i.txt'; done"

        # Set timestamps from WSL (touch -t)
        Write-Host "  [L13] Setting timestamps via WSL touch -t..." -ForegroundColor Gray
        wsl bash -c "touch -t 202301150830.00 '$wslPath/wsl_file_1.txt'"
        wsl bash -c "touch -t 202401010000.00 '$wslPath/wsl_file_2.txt'"

        # Create files with specific permissions from WSL
        Write-Host "  [L13] Creating files with WSL chmod..." -ForegroundColor Gray
        wsl bash -c "echo 'chmod test' > '$wslPath/wsl_chmod_test.txt' && chmod 755 '$wslPath/wsl_chmod_test.txt'"

        # Copy files from WSL's root filesystem to NTFS
        Write-Host "  [L13] Copying WSL system files to NTFS..." -ForegroundColor Gray
        wsl bash -c "cp /etc/hostname '$wslPath/wsl_hostname.txt' 2>/dev/null; cp /etc/os-release '$wslPath/wsl_osrelease.txt' 2>/dev/null"

        # Modify existing NTFS files from WSL
        Write-Host "  [L13] Modifying NTFS files via WSL..." -ForegroundColor Gray
        wsl bash -c "echo 'Appended from WSL' >> '$wslPath/wsl_file_5.txt'"
        wsl bash -c "sed -i 's/WSL-created/WSL-MODIFIED/' '$wslPath/wsl_file_6.txt'"

        Write-Host "  [L13] WSL operations complete. WSL filesystem bridge creates unusual timestamp patterns." -ForegroundColor Gray
        Write-Host "  [L13] WSL touch -t can set timestamps that look like timestomping to naive detectors." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L14: Auto-Update (SEMI-AUTO)
# ----------------------------------------------------------
$AllOperations["L14"] = @{
    Name = "Application Auto-Update"
    Type = "SEMI"
    Action = {
        Write-Host "  [L14] Triggering application auto-updates..." -ForegroundColor Gray
        $updateDir = "$BaselineDir\L14_AutoUpdate"
        New-Item -ItemType Directory -Path $updateDir -Force | Out-Null

        # Check for and trigger Defender definition update
        Write-Host "  [L14] Updating Windows Defender definitions..." -ForegroundColor Gray
        try {
            Update-MpSignature -ErrorAction SilentlyContinue
            Write-Host "  [L14] Defender definitions updated" -ForegroundColor Green
        } catch {
            Write-Host "  [L14] Defender update failed (may need internet): $_" -ForegroundColor Yellow
        }

        # Trigger Windows Store app updates (if available)
        Write-Host "  [L14] Checking for Store app updates..." -ForegroundColor Gray
        try {
            Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" -ErrorAction SilentlyContinue | 
                Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction SilentlyContinue
        } catch {
            Write-Host "  [L14] Store update trigger skipped (not available on this edition)" -ForegroundColor Yellow
        }

        # If VS Code was installed (L3), trigger its update check
        $vscExe = "${env:LOCALAPPDATA}\Programs\Microsoft VS Code\Code.exe"
        if (Test-Path $vscExe) {
            Write-Host "  [L14] VS Code is installed. It will auto-check for updates on launch." -ForegroundColor Gray
            Write-Host "  [L14] Launch VS Code briefly and close it for update artifacts." -ForegroundColor Yellow
            Start-Process $vscExe -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 15
            Stop-Process -Name "Code" -Force -ErrorAction SilentlyContinue
        }

        # If Git was installed (L3), it does not auto-update but creates update-check files
        $gitExe = "C:\Program Files\Git\cmd\git.exe"
        if (Test-Path $gitExe) {
            Write-Host "  [L14] Git found. Running git version check (generates timestamp activity)..." -ForegroundColor Gray
            & $gitExe --version | Out-Null
        }

        Write-Host "  [L14] Auto-update cycle complete. Silent updates replace binaries but may preserve timestamps." -ForegroundColor Gray
    }
}

# ----------------------------------------------------------
# L15: Hibernation/Sleep (SEMI-AUTO)
# ----------------------------------------------------------
$AllOperations["L15"] = @{
    Name = "Hibernation/Sleep Cycle"
    Type = "SEMI"
    Action = {
        Write-Host "  [L15] Testing hibernation/sleep timestamp effects..." -ForegroundColor Gray
        $hibDir = "$BaselineDir\L15_Hibernation"
        New-Item -ItemType Directory -Path $hibDir -Force | Out-Null

        # Create timestamp reference files before sleep
        1..10 | ForEach-Object {
            Set-Content "$hibDir\pre_sleep_$_.txt" -Value "Created before sleep $(Get-Date -Format 'o')"
        }

        # Record pre-sleep system time
        Get-Date -Format 'o' | Out-File "$hibDir\pre_sleep_timestamp.txt"

        # Enable hibernation if not already
        powercfg /hibernate on 2>$null

        Write-Host "  [L15] Reference files created. System time recorded." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [L15] To complete this test:" -ForegroundColor Yellow
        Write-Host "    Option A: Sleep the VM (Host menu > ACPI Shutdown > Sleep)" -ForegroundColor Yellow
        Write-Host "    Option B: Run 'rundll32.exe powrprof.dll,SetSuspendState 0,1,0' for sleep" -ForegroundColor Yellow
        Write-Host "    Option C: Run 'shutdown /h' for full hibernation" -ForegroundColor Yellow
        Write-Host "    After waking, run the post-capture manually." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Key artifacts:" -ForegroundColor Cyan
        Write-Host "    - hiberfil.sys timestamps" -ForegroundColor Cyan
        Write-Host "    - System Event Log entries for sleep/wake" -ForegroundColor Cyan
        Write-Host "    - Potential clock skew after resume" -ForegroundColor Cyan

        Pause-ForManualStep "Sleep/hibernate the VM, wake it, then press ENTER to continue."

        # Record post-wake time
        Get-Date -Format 'o' | Out-File "$hibDir\post_wake_timestamp.txt"
        Write-Host "  [L15] Post-wake timestamp recorded." -ForegroundColor Gray
    }
}

# ============================================================
# EXECUTION ENGINE
# ============================================================

# Determine which operations to run
if ($Operations) {
    $toRun = $Operations | ForEach-Object { $_.ToUpper() }
} else {
    $toRun = $AllOperations.Keys
}

# Validate
foreach ($op in $toRun) {
    if (-not $AllOperations.Contains($op)) {
        Write-Host "[ERROR] Unknown operation: $op. Valid: $($AllOperations.Keys -join ', ')" -ForegroundColor Red
        exit 1
    }
}

# Print execution plan
Write-Host "`n$('#'*70)" -ForegroundColor Cyan
Write-Host "  NTFS Timestomping Research - Baseline Operations" -ForegroundColor Cyan
Write-Host "  OS Tag: $OSTag | Operations: $($toRun -join ', ')" -ForegroundColor Cyan
Write-Host "  Idle Wait: ${IdleWaitSeconds}s | Capture: $(if ($SkipCapture) {'DISABLED'} else {'ENABLED'})" -ForegroundColor Cyan
Write-Host "$('#'*70)`n" -ForegroundColor Cyan

$manualOps = $toRun | Where-Object { $AllOperations[$_].Type -in @("MANUAL","SEMI") }
if ($manualOps) {
    Write-Host "[HEADS UP] These operations require manual steps: $($manualOps -join ', ')" -ForegroundColor Yellow
    Write-Host "[HEADS UP] The script will pause and prompt you when manual action is needed.`n" -ForegroundColor Yellow
}

# Execute
$startTime = Get-Date
$completed = 0
$failed = 0

foreach ($op in $toRun) {
    $def = $AllOperations[$op]
    try {
        Invoke-FullOperation -Code $op -Name $def.Name -Type $def.Type -Action $def.Action
        $completed++
    } catch {
        Write-Host "  [FATAL] $op failed completely: $_" -ForegroundColor Red
        Log-Operation -Code $op -Name $def.Name -Status "FATAL" -Notes "$_"
        $failed++
    }
}

# Summary
$elapsed = (Get-Date) - $startTime
Write-Host "`n$('#'*70)" -ForegroundColor Green
Write-Host "  BASELINE OPERATIONS COMPLETE" -ForegroundColor Green
Write-Host "  Completed: $completed | Failed: $failed | Elapsed: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
Write-Host "  Log: $LogFile" -ForegroundColor Green
Write-Host "  Next step: Take snapshot POST-BASELINE-OPS-$($OSTag.ToUpper())" -ForegroundColor Yellow
Write-Host "$('#'*70)" -ForegroundColor Green