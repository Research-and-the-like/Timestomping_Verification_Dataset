# ============================================================
# 08_Evasion_Levels.ps1
# Implement evasion Levels 1-5 with escalating sophistication
# RUN AS Administrator
# REMINDER: Restore to POST-TIMESTOMPING snapshot before each level
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [ValidateRange(1,5)]
    [int]$Level
)

Write-Host "============== 08_Evasion_Levels.ps1 ==============" -ForegroundColor Black -BackgroundColor Yellow

$EvasionDir = "C:\Research\Data\Evasion\Level$Level"
$ToolsRoot = "C:\Research\Tools"
New-Item -ItemType Directory -Path $EvasionDir -Force | Out-Null

# Create 20 fresh target files for evasion testing
$targets = @()
1..20 | ForEach-Object {
    $f = "$EvasionDir\evasion_target_$( '{0:D3}' -f $_ ).txt"
    Set-Content $f -Value "Evasion Level $Level target file $_ $(Get-Date -Format 'o') $([guid]::NewGuid())"
    $targets += $f
}
Write-Host "[+] Created $($targets.Count) target files for Level $Level" -ForegroundColor Green

# Donor file for plausible timestamps
$donor = Get-Item "$env:SystemRoot\System32\notepad.exe"
$donorCreated = $donor.CreationTime
$donorModified = $donor.LastWriteTime

switch ($Level) {

    1 {
        # ── LEVEL 1: Millisecond precision correction ──
        # Defeats: A4 (zero sub-second)
        # Detectable by: A1, A2, A3, A5, B1, B2, C1, C2
        Write-Host "=== Level 1: Millisecond Precision Timestomping ===" -ForegroundColor Cyan
        
        $targetDate = (Get-Date).AddMonths(-4)
        foreach ($f in $targets) {
            # Set with realistic sub-second precision
            $created  = $targetDate.AddMilliseconds((Get-Random -Min 100 -Max 999)).AddTicks((Get-Random -Min 1000 -Max 9999))
            $modified = $targetDate.AddHours(2).AddMilliseconds((Get-Random -Min 100 -Max 999)).AddTicks((Get-Random -Min 1000 -Max 9999))
            $accessed = $targetDate.AddDays(1).AddMilliseconds((Get-Random -Min 100 -Max 999)).AddTicks((Get-Random -Min 1000 -Max 9999))
            
            [System.IO.File]::SetCreationTime($f, $created)
            [System.IO.File]::SetLastWriteTime($f, $modified)
            [System.IO.File]::SetLastAccessTime($f, $accessed)
        }
    }

    2 {
        # ── LEVEL 2: Donor file cloning + millisecond correction ──
        # Defeats: A4, A5, partially A2/A3
        # Detectable by: A1, B1, B2, C1, C2
        Write-Host "=== Level 2: Donor Timestamp Cloning ===" -ForegroundColor Cyan
        
        foreach ($f in $targets) {
            # Clone timestamps from legitimate system file with small random offset
            $jitter = New-TimeSpan -Seconds (Get-Random -Min 0 -Max 120)
            [System.IO.File]::SetCreationTime($f, $donorCreated + $jitter)
            [System.IO.File]::SetLastWriteTime($f, $donorModified + $jitter)
            [System.IO.File]::SetLastAccessTime($f, $donorModified.AddDays(1) + $jitter)
        }
    }

    3 {
        # ── LEVEL 3: $FN manipulation via move/rename trick ──
        # Defeats: ALL Method A rules (A1-A5)
        # Detectable by: B1, B2, B3, C1, C2 (move generates UsnJrnl entries)
        Write-Host "=== Level 3: Move/Rename Trick ($FN Manipulation) ===" -ForegroundColor Cyan
        
        $tempDir = "$EvasionDir\_temp_move"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        foreach ($f in $targets) {
            $fname = Split-Path $f -Leaf
            
            # Step 1: Timestomp $SI
            [System.IO.File]::SetCreationTime($f, $donorCreated)
            [System.IO.File]::SetLastWriteTime($f, $donorModified)
            [System.IO.File]::SetLastAccessTime($f, $donorModified.AddHours(6))
            
            # Step 2: Move to temp directory → OS copies $SI into $FN
            $tempPath = "$tempDir\$fname"
            Move-Item $f -Destination $tempPath -Force
            
            # Step 3: Move back → $FN now has the stomped values
            Move-Item $tempPath -Destination $f -Force
            
            # Step 4: Re-stomp $SI.EntryModified (updated by the move)
            # Note: EntryModified ($SI.E) can't be set via SetFileTime API
            # This is a known limitation — $SI.E will show the move time
            # SetMace could fix this if available
        }
        
        Remove-Item $tempDir -Force -Recurse -ErrorAction SilentlyContinue
    }

    4 {
        # ── LEVEL 4: Level 3 + $UsnJrnl destruction ──
        # Defeats: ALL Method A + ALL Method B
        # Detectable by: C1, C2, and meta-detection (UsnJrnl gaps)
        Write-Host "=== Level 4: Move/Rename + UsnJrnl Clearing ===" -ForegroundColor Cyan
        
        # First do Level 3 (move/rename trick)
        $tempDir = "$EvasionDir\_temp_move"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        foreach ($f in $targets) {
            $fname = Split-Path $f -Leaf
            [System.IO.File]::SetCreationTime($f, $donorCreated)
            [System.IO.File]::SetLastWriteTime($f, $donorModified)
            [System.IO.File]::SetLastAccessTime($f, $donorModified.AddHours(6))
            Move-Item $f -Destination "$tempDir\$fname" -Force
            Move-Item "$tempDir\$fname" -Destination $f -Force
        }
        Remove-Item $tempDir -Force -Recurse -ErrorAction SilentlyContinue
        
        # Now destroy $UsnJrnl
        Write-Host "  [!] Deleting $UsnJrnl..." -ForegroundColor Red
        fsutil usn deletejournal /d C:
        Start-Sleep -Seconds 2
        # Re-create it (OS does this automatically, but force it)
        fsutil usn createjournal m=1000 a=100 C:
        Write-Host "  [+] $UsnJrnl deleted and recreated" -ForegroundColor Yellow
    }

    5 {
        # ── LEVEL 5: Full cleanup (Level 4 + Prefetch + Event Logs) ──
        # Defeats: ALL Methods A, B, and C
        # META-DETECTABLE: Event 1102, UsnJrnl gaps, missing Prefetch
        Write-Host "=== Level 5: Full Evidence Destruction ===" -ForegroundColor Cyan
        
        # Level 3 first (move/rename trick)
        $tempDir = "$EvasionDir\_temp_move"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        foreach ($f in $targets) {
            $fname = Split-Path $f -Leaf
            [System.IO.File]::SetCreationTime($f, $donorCreated)
            [System.IO.File]::SetLastWriteTime($f, $donorModified)
            [System.IO.File]::SetLastAccessTime($f, $donorModified.AddHours(6))
            Move-Item $f -Destination "$tempDir\$fname" -Force
            Move-Item "$tempDir\$fname" -Destination $f -Force
        }
        Remove-Item $tempDir -Force -Recurse -ErrorAction SilentlyContinue
        
        # Destroy $UsnJrnl
        Write-Host "  [!] Deleting $UsnJrnl..." -ForegroundColor Red
        fsutil usn deletejournal /d C:
        fsutil usn createjournal m=1000 a=100 C:
        
        # Delete Prefetch files
        Write-Host "  [!] Clearing Prefetch..." -ForegroundColor Red
        Remove-Item "$env:SystemRoot\Prefetch\*.pf" -Force -ErrorAction SilentlyContinue
        
        # Clear Event Logs
        Write-Host "  [!] Clearing Event Logs..." -ForegroundColor Red
        wevtutil cl Security
        wevtutil cl System
        wevtutil cl "Microsoft-Windows-Sysmon/Operational"
        
        Write-Host "  [+] Full cleanup complete" -ForegroundColor Yellow
        Write-Host "  [META] Event 1102 (Audit Log Cleared) was generated" -ForegroundColor Magenta
        Write-Host "  [META] $UsnJrnl sequence numbers have gaps" -ForegroundColor Magenta
        Write-Host "  [META] Prefetch files are missing for system utilities" -ForegroundColor Magenta
    }
}

Write-Host "`n[!] Now run: .\01_Capture_Artifacts.ps1 -Tag 'evasion-level$Level'" -ForegroundColor Yellow
Write-Host "[!] Then run detection scripts to measure surviving detection capability" -ForegroundColor Yellow
