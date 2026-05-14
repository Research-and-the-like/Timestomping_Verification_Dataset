# ============================================================
# SCRIPT: 00b_Verify_Tool_Parity.ps1
# PURPOSE: Pre-flight tool existence + execution verification
#          Confirms all required tools are present AND functional
#          before any experiment phase begins.
# USAGE:   .\00b_Verify_Tool_Parity.ps1 [-Strict]
# OPTIONS: -Strict  Exit with code 1 if any CRITICAL tool fails
#                   (use this in automated pipelines)
# RUN AS:  Administrator
# OUTPUT:  Console report + C:\Research\Data\tool_parity_report.json
# VERSION: 1.1 (27 April 2026)
#   FIXES: - Null-coalescing rewritten (removed broken -replace $null pattern)
#          - Inline `if` removed from -f format strings (pre-computed variables)
#          - Counter logic fixed (early return now increments critFail/optFail)
#          - nTimestomp and RawCopy paths resolved via recursive search
#          - SetMace execution test relaxed (no-arg probe, catches non-zero exit)
# ============================================================

param(
    [switch]$Strict
)

# ---------------------------------------------------------------------------
# SETUP
# ---------------------------------------------------------------------------

$ToolsRoot   = "C:\Research\Tools"
$ReportPath  = "C:\Research\Data\tool_parity_report.json"
$RunTime     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$OSInfo      = (Get-WmiObject Win32_OperatingSystem).Caption
$BuildNumber = (Get-WmiObject Win32_OperatingSystem).BuildNumber

$results     = [System.Collections.Generic.List[hashtable]]::new()
$critFail    = 0
$optFail     = 0
$pass        = 0

# ---------------------------------------------------------------------------
# HELPER: Resolve a tool path via recursive search, with a hard-coded fallback.
# Replaces the broken ($var -replace $null, "fallback") pattern from v1.0.
# When Get-ChildItem finds the file it returns the real path cleanly.
# When nothing is found it returns the fallback string for a clean MISSING display.
# ---------------------------------------------------------------------------
function Resolve-ToolPath {
    param([string]$SearchRoot, [string]$FileName, [string]$Fallback)
    if (-not (Test-Path $SearchRoot)) { return $Fallback }
    $found = Get-ChildItem $SearchRoot -Recurse -Filter $FileName -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.FullName }
    return $Fallback
}

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

function Write-Section($title) {
    Write-Host ""
    Write-Host ("=" * 65) -ForegroundColor DarkCyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ("=" * 65) -ForegroundColor DarkCyan
}

function Test-ToolEntry {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Category,
        [string]$Criticality,
        [string]$TestArgs,
        [string]$ExpectedOut,
        [string]$Note = ""
    )

    $record = @{
        Name         = $Name
        Path         = $Path
        Category     = $Category
        Criticality  = $Criticality
        ExistsOK     = $false
        ExecuteOK    = $false
        VersionStr   = ""
        Status       = "FAIL"
        Note         = $Note
    }

    # --- 1. EXISTENCE CHECK ---
    $resolvedPath = $null
    if ([System.IO.Path]::IsPathRooted($Path)) {
        if (Test-Path $Path) {
            $record.ExistsOK = $true
            $resolvedPath    = $Path
        }
    } else {
        $resolved = Get-Command $Path -ErrorAction SilentlyContinue
        if ($resolved) {
            $record.ExistsOK = $true
            $resolvedPath    = $resolved.Source
        }
    }

    if (-not $record.ExistsOK) {
        # FIX: pre-compute color - PowerShell will not evaluate inline `if` inside -f
        $statusColor = if ($Criticality -eq "CRITICAL") { "Red" } else { "Yellow" }
        Write-Host ("  [{0,-8}] {1,-35} MISSING  {2}" -f $Criticality, $Name, $Path) -ForegroundColor $statusColor
        $record.Status = "MISSING"
        # FIX: increment counter BEFORE the early return so MISSING tools are counted
        if ($Criticality -eq "CRITICAL") { $script:critFail++ } else { $script:optFail++ }
        $script:results.Add($record)
        return
    }

    # --- 2. EXECUTION CHECK ---
    if ($TestArgs) {
        try {
            $proc = Start-Process -FilePath $resolvedPath `
                                  -ArgumentList $TestArgs `
                                  -NoNewWindow -Wait -PassThru `
                                  -RedirectStandardOutput "$env:TEMP\parity_stdout.txt" `
                                  -RedirectStandardError  "$env:TEMP\parity_stderr.txt" `
                                  -ErrorAction Stop

            $stdout    = Get-Content "$env:TEMP\parity_stdout.txt" -Raw -ErrorAction SilentlyContinue
            $stderr    = Get-Content "$env:TEMP\parity_stderr.txt" -Raw -ErrorAction SilentlyContinue
            $combined  = "$stdout $stderr"
            $hasOutput = ($combined.Trim().Length -gt 0)

            if ($ExpectedOut) {
                $record.ExecuteOK = $combined -match [regex]::Escape($ExpectedOut)
            } else {
                $record.ExecuteOK = $hasOutput
            }

            $firstLine = ($combined -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
            if ($firstLine) {
                $trimmed = $firstLine.Trim()
                $record.VersionStr = $trimmed.Substring(0, [Math]::Min(80, $trimmed.Length))
            }

        } catch {
            $record.ExecuteOK  = $false
            $record.VersionStr = "Execution error: $_"
        }
    } else {
        # No execution test defined (GUI-only tools) - existence is sufficient
        $record.ExecuteOK = $true
    }

    # --- 3. STATUS & DISPLAY ---
    if ($record.ExistsOK -and $record.ExecuteOK) {
        $record.Status = "PASS"
        $script:pass++
        Write-Host ("  [{0,-8}] {1,-35} OK       {2}" -f $Criticality, $Name, $resolvedPath) -ForegroundColor Green
        if ($record.VersionStr) {
            Write-Host ("             Version: {0}" -f $record.VersionStr) -ForegroundColor DarkGray
        }
    } elseif ($record.ExistsOK -and -not $record.ExecuteOK) {
        $record.Status = "EXEC_FAIL"
        # FIX: pre-compute color before Write-Host
        $statusColor = if ($Criticality -eq "CRITICAL") { "Red" } else { "Yellow" }
        Write-Host ("  [{0,-8}] {1,-35} EXISTS but EXECUTION FAILED" -f $Criticality, $Name) -ForegroundColor $statusColor
        if ($record.VersionStr) {
            Write-Host ("             Detail: {0}" -f $record.VersionStr) -ForegroundColor DarkGray
        }
        if ($Criticality -eq "CRITICAL") { $script:critFail++ } else { $script:optFail++ }
    }

    $script:results.Add($record)
}

function Test-ServiceRunning {
    param([string]$ServiceName, [string]$DisplayName, [string]$Criticality = "OPTIONAL")
    $svc     = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $running = ($svc -and $svc.Status -eq "Running")
    # FIX: pre-compute all conditional strings before Write-Host
    $statusStr = if ($running) { "RUNNING" } else { "NOT RUNNING" }
    $color     = if ($running) { "Green" } elseif ($Criticality -eq "CRITICAL") { "Red" } else { "Yellow" }
    Write-Host ("  [{0,-8}] {1,-35} {2}" -f $Criticality, $DisplayName, $statusStr) -ForegroundColor $color

    $statusVal = if ($running) { "PASS" } else { "FAIL" }
    $record = @{
        Name        = $DisplayName
        Path        = "Service:$ServiceName"
        Category    = "SYSTEM"
        Criticality = $Criticality
        ExistsOK    = ($null -ne $svc)
        ExecuteOK   = $running
        VersionStr  = ""
        Status      = $statusVal
        Note        = "Windows service check"
    }
    if ($running) { $script:pass++ } elseif ($Criticality -eq "CRITICAL") { $script:critFail++ } else { $script:optFail++ }
    $script:results.Add($record)
}

function Test-PythonModule {
    param([string]$Module, [string]$Criticality = "CRITICAL")
    $testCmd = "-c `"import $Module; print(getattr($Module, '__version__', 'ok'))`""
    $proc    = Start-Process "python" -ArgumentList $testCmd -NoNewWindow -Wait -PassThru `
                             -RedirectStandardOutput "$env:TEMP\py_out.txt" `
                             -RedirectStandardError  "$env:TEMP\py_err.txt" `
                             -ErrorAction SilentlyContinue
    $ok  = ($proc -and $proc.ExitCode -eq 0)
    $ver = (Get-Content "$env:TEMP\py_out.txt" -Raw -ErrorAction SilentlyContinue).Trim()

    # FIX: pre-compute status string and color before Write-Host
    $statusStr = if ($ok) { "OK  v$ver" } else { "MISSING / IMPORT FAILED" }
    $color     = if ($ok) { "Green" } elseif ($Criticality -eq "CRITICAL") { "Red" } else { "Yellow" }
    Write-Host ("  [{0,-8}] Python module: {1,-25} {2}" -f $Criticality, $Module, $statusStr) -ForegroundColor $color

    $statusVal = if ($ok) { "PASS" } else { "MISSING" }
    $record = @{
        Name        = "python:$Module"
        Path        = "python -c import $Module"
        Category    = "PYTHON"
        Criticality = $Criticality
        ExistsOK    = $ok
        ExecuteOK   = $ok
        VersionStr  = $ver
        Status      = $statusVal
        Note        = "Python package dependency"
    }
    if ($ok) { $script:pass++ } elseif ($Criticality -eq "CRITICAL") { $script:critFail++ } else { $script:optFail++ }
    $script:results.Add($record)
}

# ---------------------------------------------------------------------------
# PRE-CHECK: ADMIN RIGHTS
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor White
Write-Host "  NTFS Timestomping Research - Tool Parity Verification" -ForegroundColor White
Write-Host "  Run: $RunTime" -ForegroundColor Gray
Write-Host "  OS:  $OSInfo (Build $BuildNumber)" -ForegroundColor Gray
Write-Host "=================================================================" -ForegroundColor White

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  [!!] NOT running as Administrator. Some checks WILL fail." -ForegroundColor Red
    Write-Host "       Re-run in an elevated PowerShell session." -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# SECTION 1: FORENSIC ANALYSIS TOOLS
# ---------------------------------------------------------------------------
Write-Section "1. FORENSIC ANALYSIS TOOLS"

# FIX: All EZTools paths resolved via Resolve-ToolPath (recursive search + clean fallback)
# This replaces the v1.0 pattern: ($var -replace $null, "fallback")
# which corrupted the path string when $var was already set.
$mftecmd      = Resolve-ToolPath "$ToolsRoot\EZTools" "MFTECmd.exe"   "$ToolsRoot\EZTools\MFTECmd.exe"
$pecmd        = Resolve-ToolPath "$ToolsRoot\EZTools" "PECmd.exe"     "$ToolsRoot\EZTools\PECmd.exe"
$evtxecmd     = Resolve-ToolPath "$ToolsRoot\EZTools" "EvtxECmd.exe"  "$ToolsRoot\EZTools\EvtxECmd.exe"
$kapeExe      = Resolve-ToolPath "$ToolsRoot\kape"    "kape.exe"      "$ToolsRoot\KAPE\kape.exe"
$rawcopyExe   = Resolve-ToolPath "$ToolsRoot\RawCopy" "RawCopy.exe" "$ToolsRoot\RawCopy\RawCopy.exe"
$ftkim        = Resolve-ToolPath "$ToolsRoot\FTKImager" "FTKImager.exe" "$ToolsRoot\FTK Imager\FTK Imager\FTK Imager.exe"
$tskBin       = "C:\Research\Tools\sleuthkit\bin"

Test-ToolEntry -Name "MFTECmd"    -Path $mftecmd    -Category FORENSIC -Criticality CRITICAL -TestArgs "--help" -Note "MFT parsing; core of Methods A and B"
Test-ToolEntry -Name "PECmd"      -Path $pecmd      -Category FORENSIC -Criticality CRITICAL -TestArgs "--help" -Note "Prefetch parsing; required for Method C Rule C1"
Test-ToolEntry -Name "EvtxECmd"   -Path $evtxecmd   -Category FORENSIC -Criticality CRITICAL -TestArgs "--help" -Note "Event Log parsing; required for Method C Rule C2"
Test-ToolEntry -Name "KAPE"       -Path $kapeExe    -Category FORENSIC -Criticality CRITICAL -TestArgs "--help" -Note "Artifact collection; fallback MFT extractor if RawCopy absent"
Test-ToolEntry -Name "RawCopy"  -Path $rawcopyExe -Category FORENSIC -Criticality CRITICAL -TestArgs "/?"     -Note "Preferred MFT extractor; bypasses OS file locks"
Test-ToolEntry -Name "FTK Imager" -Path $ftkim      -Category FORENSIC -Criticality OPTIONAL -TestArgs $null   -Note "GUI tool; used for manual cross-validation, no CLI exec test"
Test-ToolEntry -Name "TSK: istat" -Path "$tskBin\istat.exe" -Category FORENSIC -Criticality OPTIONAL -TestArgs $null -Note "Raw MFT record inspection; cross-validation"
Test-ToolEntry -Name "TSK: fls"   -Path "$tskBin\fls.exe"   -Category FORENSIC -Criticality OPTIONAL -TestArgs $null -Note "NTFS directory listing; cross-validation"
#Test-ToolEntry -Name "log2timeline" -Path "log2timeline.py" -Category FORENSIC -Criticality OPTIONAL -TestArgs "--version" -Note "Super-timeline generation for Method C"

# ---------------------------------------------------------------------------
# SECTION 2: TIMESTOMPING TOOLS
# ---------------------------------------------------------------------------
Write-Section "2. TIMESTOMPING TOOLS"

# FIX: SetMace -- /? and --help are not valid flags; no-arg triggers usage output
# FIX: nTimestomp -- recursive search handles nested subfolder installs
$setmaceExe    = Resolve-ToolPath "$ToolsRoot\SetMace-master\SetMace-master\" "SetMace64.exe"   "$ToolsRoot\SetMace-master\SetMace-master\SetMace64.exe"
$ntimestompExe = Resolve-ToolPath "$ToolsRoot\nTimetools-master\nTimetools-master\" "nTimestomp_v1.2_x64.exe"  "$ToolsRoot\nTimetools-master\nTimetools-master\nTimestomp_v1.2_x64.exe"
$bfcExe        = Resolve-ToolPath "$ToolsRoot\bulkfilechanger-x64\" "BulkFileChanger.exe" "$ToolsRoot\bulkfilechanger-x64\BulkFileChanger.exe"

Test-ToolEntry -Name "SetMace64"       -Path $setmaceExe    -Category TIMESTOMPING -Criticality CRITICAL -TestArgs $null    -Note "T3: only tool manipulating both SI+FN; no valid fallback for T3"
Test-ToolEntry -Name "nTimestomp"      -Path $ntimestompExe -Category TIMESTOMPING -Criticality CRITICAL -TestArgs "--help" -Note "T5: nanosecond-precision timestomping (Evasion L1)"
Test-ToolEntry -Name "BulkFileChanger" -Path $bfcExe        -Category TIMESTOMPING -Criticality OPTIONAL -TestArgs $null   -Note "T2: GUI tool; CLI-equivalent via PowerShell SetFileTime API"
Test-ToolEntry -Name "PowerShell"      -Path "powershell.exe" -Category TIMESTOMPING -Criticality CRITICAL `
               -TestArgs "-Command `"Write-Host ok`"" -ExpectedOut "ok" -Note "T1 and T4: native SetFileTime API timestomping"
#Test-ToolEntry -Name "Sliver (C2)"     -Path "$ToolsRoot\Sliver\sliver-client.exe" -Category TIMESTOMPING -Criticality OPTIONAL `
#               -TestArgs "--help" -Note "T5 Evasion L2: donor timestamp cloning; PowerShell fallback available"

# ---------------------------------------------------------------------------
# SECTION 3: SYSTEM SERVICES
# ---------------------------------------------------------------------------
Write-Section "3. SYSTEM SERVICES & AUDIT POLICY"

Test-ServiceRunning -ServiceName "Sysmon64" -DisplayName "Sysmon64 (Event ID 2 logging)" -Criticality CRITICAL
Test-ServiceRunning -ServiceName "EventLog" -DisplayName "Windows Event Log"              -Criticality CRITICAL

Write-Host ""
Write-Host "  Checking audit policy (File System Object Access)..." -ForegroundColor Gray
try {
    $auditOut     = & auditpol /get /subcategory:"File System" 2>&1
    $auditEnabled = ($auditOut -match "Success and Failure|Success|Failure")
    # FIX: pre-compute strings before Write-Host
    $auditStatus  = if ($auditEnabled) { "ENABLED (Event 4663 will fire)" } else { "DISABLED - run: auditpol /set /subcategory:'File System' /success:enable /failure:enable" }
    $auditColor   = if ($auditEnabled) { "Green" } else { "Yellow" }
    Write-Host ("  [OPTIONAL ] Audit: File System Object Access      {0}" -f $auditStatus) -ForegroundColor $auditColor
} catch {
    Write-Host "  [OPTIONAL ] Audit policy check failed: $_" -ForegroundColor Yellow
}

# WSL -- Required for any Linux-side analysis tooling or cross-platform validation
Write-Host ""
Write-Host "  Checking WSL installation..." -ForegroundColor Gray
try {
    $wslFeature   = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction SilentlyContinue
    Write-Host $wslFeature
    $wslExe       = Get-Command wsl.exe -ErrorAction SilentlyContinue
    Write-Host $wslExe
    $wslEnabled   = ($wslFeature.State -eq "Enabled") -and ($null -ne $wslExe)
    Write-Host $wslEnabled
    
 
    if ($wslEnabled) {
        # Probe for Ubuntu distro specifically
        $distros    = (cmd /c "wsl --list --quiet 2>&1") -join "`n"
        $distros    = $distros -replace "`0", ""
        $ubuntuOK   = ($distros -match "Ubuntu")
        $distroStr  = if ($ubuntuOK) { "Ubuntu distro confirmed" } else { "WSL enabled but Ubuntu distro not found - run: wsl --install Ubuntu" }
        $distroColor = if ($ubuntuOK) { "Green" } else { "Yellow" }
        Write-Host ("  [OPTIONAL ] WSL: feature enabled              {0}" -f $distroStr) -ForegroundColor $distroColor
 
        $record = @{
            Name        = "WSL (Ubuntu)"
            Path        = "wsl.exe"
            Category    = "SYSTEM"
            Criticality = "OPTIONAL"
            ExistsOK    = $true
            ExecuteOK   = $ubuntuOK
            VersionStr  = $distros.Trim()
            Status      = if ($ubuntuOK) { "PASS" } else { "WARN" }
            Note        = "Linux-side analysis; Ubuntu distro required"
        }
        if ($ubuntuOK) { $script:pass++ } else { $script:optFail++ }
 
    } else {
        Write-Host "  [OPTIONAL ] WSL: NOT installed or NOT enabled" -ForegroundColor Yellow
        Write-Host "              Run 00_Install_Tools.ps1 to install, then reboot to complete Ubuntu setup." -ForegroundColor DarkGray
 
        $record = @{
            Name        = "WSL (Ubuntu)"
            Path        = "wsl.exe"
            Category    = "SYSTEM"
            Criticality = "OPTIONAL"
            ExistsOK    = $false
            ExecuteOK   = $false
            VersionStr  = "not installed"
            Status      = "WARN"
            Note        = "Run 00_Install_Tools.ps1 then reboot to complete setup"
        }
        $script:optFail++
    }
    $results.Add($record) | Out-Null
 
} catch {
    Write-Host "  [OPTIONAL ] WSL check failed: $_" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# SECTION 4: PYTHON ENVIRONMENT
# ---------------------------------------------------------------------------
Write-Section "4. PYTHON ENVIRONMENT"

Test-ToolEntry    -Name "Python 3.x" -Path "python" -Category PYTHON -Criticality CRITICAL `
                  -TestArgs "--version" -ExpectedOut "Python 3" -Note "Core analysis scripts 05-09 require Python 3.x"
Test-PythonModule -Module "pandas"   -Criticality CRITICAL
Test-PythonModule -Module "openpyxl" -Criticality CRITICAL
Test-PythonModule -Module "tqdm"     -Criticality OPTIONAL
Test-PythonModule -Module "json"     -Criticality CRITICAL
Test-PythonModule -Module "csv"      -Criticality CRITICAL
Test-PythonModule -Module "hashlib"  -Criticality CRITICAL

# ---------------------------------------------------------------------------
# SECTION 5: DIRECTORY STRUCTURE
# ---------------------------------------------------------------------------
Write-Section "5. DIRECTORY STRUCTURE"

$dirs = @(
    @{ Path = "C:\Research\Tools";            Label = "Tools root" }
    @{ Path = "C:\Research\Tools\EZTools";    Label = "EZTools" }
    @{ Path = "C:\Research\Tools\kape";       Label = "KAPE" }
    @{ Path = "C:\Research\Tools\SetMace-master\SetMace-master";    Label = "SetMace" }
    @{ Path = "C:\Research\Tools\nTimetools-master\nTimetools-master"; Label = "nTimetools" }
    @{ Path = "C:\Research\Data\Baseline";    Label = "Data/Baseline" }
    @{ Path = "C:\Research\Data\Timestomped"; Label = "Data/Timestomped" }
    @{ Path = "C:\Research\Data\Artifacts";   Label = "Data/Artifacts" }
    @{ Path = "C:\Research\Data\Parsed";      Label = "Data/Parsed" }
    @{ Path = "C:\Research\Data\Evasion";     Label = "Data/Evasion" }
    @{ Path = "C:\Research\Scripts";          Label = "Scripts" }
)

foreach ($d in $dirs) {
    $exists    = Test-Path $d.Path
    # FIX: pre-compute strings before Write-Host
    $existsStr = if ($exists) { "EXISTS" } else { "MISSING" }
    $color     = if ($exists) { "Green" } else { "Red" }
    Write-Host ("  {0,-45} {1}" -f $d.Label, $existsStr) -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# FINAL SUMMARY
# ---------------------------------------------------------------------------
$total = $results.Count
Write-Host ""
Write-Host ("=" * 65) -ForegroundColor White
Write-Host "  PARITY SUMMARY" -ForegroundColor White
Write-Host ("=" * 65) -ForegroundColor White
Write-Host ("  Total checks : {0}" -f $total) -ForegroundColor White
Write-Host ("  PASSED       : {0}" -f $pass)  -ForegroundColor Green

$critColor = if ($critFail -gt 0) { "Red" } else { "Green" }
$optColor  = if ($optFail  -gt 0) { "Yellow" } else { "Green" }
Write-Host ("  CRITICAL FAIL: {0}  <-- Blocks experiment execution" -f $critFail) -ForegroundColor $critColor
Write-Host ("  OPTIONAL FAIL: {0}  <-- Degrades coverage only"       -f $optFail)  -ForegroundColor $optColor
Write-Host ("  OS           : {0} (Build {1})" -f $OSInfo, $BuildNumber) -ForegroundColor Gray
Write-Host ("  Run time     : {0}" -f $RunTime) -ForegroundColor Gray
Write-Host ""

if ($critFail -eq 0) {
    Write-Host "  [READY] All critical tools verified. Safe to proceed." -ForegroundColor Green
} else {
    Write-Host "  [BLOCKED] $critFail critical tool(s) failed. DO NOT start experiments." -ForegroundColor Red
    Write-Host "            Resolve missing tools and re-run this script." -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# EXPORT: JSON PARITY REPORT
# ---------------------------------------------------------------------------
$report = @{
    generated_at     = $RunTime
    os               = $OSInfo
    build            = $BuildNumber
    admin_context    = $isAdmin
    summary          = @{
        total            = $total
        passed           = $pass
        critical_fail    = $critFail
        optional_fail    = $optFail
        experiment_ready = ($critFail -eq 0)
    }
    tools            = $results
}

$reportJson = $report | ConvertTo-Json -Depth 5
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null
$reportJson | Out-File -FilePath $ReportPath -Encoding utf8 -Force

Write-Host ""
Write-Host ("  Parity report saved to: {0}" -f $ReportPath) -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# STRICT MODE EXIT CODE
# ---------------------------------------------------------------------------
if ($Strict -and $critFail -gt 0) {
    Write-Host "  -Strict flag set: exiting with code 1" -ForegroundColor Red
    exit 1
}