# ============================================================
# 01_Capture_Artifacts.ps1
# Extract MFT, $UsnJrnl, Prefetch, Event Logs
# Usage: .\01_Capture_Artifacts.ps1 -Tag "pre-baseline"
# RUN AS Administrator
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$Tag,
    [string[]]$Drives = @("C:", "E:"),      # capture both: baselines on C:, timestomp targets on E:
    [string[]]$UsnDrives = @("C:", "E:"),   # journal correlation needs both, positives live on E:
    [string]$OutDir = "C:\Research\Data\Artifacts"
)


Write-Host "============== 01_Capture_Artifacts.ps1 ==============" -ForegroundColor Black -BackgroundColor Yellow

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$captureDir = "$OutDir\${Tag}_${timestamp}"
New-Item -ItemType Directory -Path $captureDir -Force | Out-Null

$ToolsRoot = "C:\Research\Tools"
$kape = "$ToolsRoot\kape\KAPE\kape.exe"


Write-Host "=== Artifact Capture: $Tag ($timestamp) ===" -ForegroundColor Cyan

# --- 1. Extract $MFT for each target volume ---
$rawcopy = "$ToolsRoot\RawCopy\RawCopy.exe"
$mftRawFiles = @{}   # driveLetter -> raw MFT path
foreach ($drv in $Drives) {
    $letter = $drv.TrimEnd(':').TrimEnd('\')   # "C:" -> "C"
    Write-Host "[1/6] Extracting `$MFT from ${drv}..." -ForegroundColor Yellow
    if (Test-Path $rawcopy) {
        & $rawcopy /FileNamePath:"${drv}\`$MFT" /OutputPath:"$captureDir"
        $rawName = "MFT_${letter}_raw"
        Rename-Item "$captureDir\`$MFT" -NewName $rawName -ErrorAction SilentlyContinue
        if (Test-Path "$captureDir\$rawName") {
            $mftRawFiles[$letter] = "$captureDir\$rawName"
        } else {
            Write-Host "  [!] Raw MFT for ${drv} not found after RawCopy" -ForegroundColor Red
        }
    } else {
        Write-Host "Error extracting `$MFT using RawCopy (not found at $rawcopy)" -ForegroundColor Red
    }
}

# --- 2. Extract $UsnJrnl (per volume: positives live on E:, must capture both) ---
foreach ($drv in $UsnDrives) {
    $letter = $drv.TrimEnd(':').TrimEnd('\')
    Write-Host "[2/6] Extracting `$UsnJrnl from ${drv}..." -ForegroundColor Yellow
    fsutil usn readjournal $drv csv > "$captureDir\UsnJrnl_${letter}_raw.csv"
    if (Test-Path $rawcopy) {
        & $kape --tsource $drv --tdest "$captureDir\UsnJrnl_${letter}" --target `$J
    }
}

# --- 3. Collect Prefetch ---
Write-Host "[3/6] Collecting Prefetch files..." -ForegroundColor Yellow
$pfDest = "$captureDir\Prefetch"
New-Item -ItemType Directory -Path $pfDest -Force | Out-Null
Copy-Item "$env:SystemRoot\Prefetch\*" -Destination $pfDest -Force -ErrorAction SilentlyContinue

# --- 4. Export Event Logs ---
Write-Host "[4/6] Exporting Event Logs..." -ForegroundColor Yellow
$evtDest = "$captureDir\EventLogs"
New-Item -ItemType Directory -Path $evtDest -Force | Out-Null
wevtutil epl Security "$evtDest\Security.evtx"
wevtutil epl System "$evtDest\System.evtx"
wevtutil epl "Microsoft-Windows-Sysmon/Operational" "$evtDest\Sysmon.evtx"

# --- 5. Parse each MFT with MFTECmd (one CSV per volume) ---
Write-Host "[5/6] Parsing MFT(s) with MFTECmd..." -ForegroundColor Yellow
$mftecmd = Get-ChildItem "$ToolsRoot\EZTools" -Recurse -Filter "MFTECmd.exe" | Select-Object -First 1
if ($mftecmd) {
    foreach ($letter in $mftRawFiles.Keys) {
        & $mftecmd.FullName -f $mftRawFiles[$letter] --csv "$captureDir" --csvf "MFT_${letter}_parsed.csv"
        Write-Host "  [+] Parsed ${letter}: -> MFT_${letter}_parsed.csv" -ForegroundColor Gray
    }
} else {
    Write-Host "  [!] MFTECmd not found" -ForegroundColor Red
}

# --- 6. Parse Prefetch ---
Write-Host "[6/6] Parsing Prefetch with PECmd..." -ForegroundColor Yellow
$pecmd = Get-ChildItem "$ToolsRoot\EZTools" -Recurse -Filter "PECmd.exe" | Select-Object -First 1
if ($pecmd) {
    & $pecmd.FullName -d "$pfDest" --csv "$captureDir" --csvf "Prefetch_parsed.csv"
}

Write-Host "`n=== Capture Complete: $captureDir ===" -ForegroundColor Green
Write-Host "Files:" -ForegroundColor Gray
Get-ChildItem $captureDir -Recurse -File | ForEach-Object {
    Write-Host "  $($_.FullName) ($([math]::Round($_.Length/1KB, 1)) KB)" -ForegroundColor Gray
}
