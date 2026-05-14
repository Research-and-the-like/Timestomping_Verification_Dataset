# ============================================================
# 01_Capture_Artifacts.ps1
# Extract MFT, $UsnJrnl, Prefetch, Event Logs
# Usage: .\01_Capture_Artifacts.ps1 -Tag "pre-baseline"
# RUN AS Administrator
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$Tag,
    [string]$Drive = "C:",
    [string]$OutDir = "C:\Research\Data\Artifacts"
)

Write-Host "============== 01_Capture_Artifacts.ps1 ==============" -ForegroundColor Black -BackgroundColor Yellow

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$captureDir = "$OutDir\${Tag}_${timestamp}"
New-Item -ItemType Directory -Path $captureDir -Force | Out-Null

$ToolsRoot = "C:\Research\Tools"
$kape = "$ToolsRoot\kape\KAPE\kape.exe"


Write-Host "=== Artifact Capture: $Tag ($timestamp) ===" -ForegroundColor Cyan

# --- 1. Extract $MFT ---
Write-Host "[1/6] Extracting `$MFT..." -ForegroundColor Yellow
$rawcopy = "$ToolsRoot\RawCopy\RawCopy.exe"
if (Test-Path $rawcopy) {
    & $rawcopy /FileNamePath:"${Drive}\`$MFT" /OutputPath:"$captureDir"
    Rename-Item "$captureDir\`$MFT" -NewName "MFT_raw" -ErrorAction SilentlyContinue
} else {
    Write-Host "Error extracting `$MFT using RawCopy" -ForegroundColor Red
#    Write-Host "Using KAPE for MFT extraction" -ForegroundColor Yellow
    # KAPE fallback
#    $kape = "$ToolsRoot\kape\KAPE\kape.exe"
#    if (Test-Path $kape) {
#        & $kape --tsource $Drive --tdest "$captureDir\KAPE_MFT" --target `$MFT
#    }
}

# --- 2. Extract $UsnJrnl ---
Write-Host "[2/6] Extracting `$UsnJrnl..." -ForegroundColor Yellow
# Extract via fsutil
fsutil usn readjournal $Drive csv > "$captureDir\UsnJrnl_raw.csv"
# Also extract the raw $J file
if (Test-Path $rawcopy) {
#    & $rawcopy /FileNamePath:"${Drive}\`$Extend\`$UsnJrnl:`$J" /OutputPath:"$captureDir"
     & $kape --tsource $Drive --tdest "$captureDir\UsnJrnl" --target `$J
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

# --- 5. Parse MFT ---
Write-Host "[5/6] Parsing MFT with MFTECmd..." -ForegroundColor Yellow
$mftecmd = Get-ChildItem "$ToolsRoot\EZTools" -Recurse -Filter "MFTECmd.exe" | Select-Object -First 1
if ($mftecmd) {
    & $mftecmd.FullName -f "$captureDir\MFT_raw" --csv "$captureDir" --csvf "MFT_parsed.csv"
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
