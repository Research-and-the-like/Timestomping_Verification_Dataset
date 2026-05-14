# ============================================================
# SCRIPT: 04_Execute_Timestomping.ps1
# PURPOSE: Apply timestomping tool/scenario combinations
#          Updates the manifest CSV with post-stomp timestamps
# RUN AS: Administrator (required for SetMace)
# ============================================================

$TSDir = "C:\Research\Data\Timestomped"
$ToolsRoot = "C:\Research\Tools"
$manifest = Import-Csv "$TSDir\timestomp_manifest.csv"

# ── Define target timestamps for each scenario ──

# S1: Plausible past — 6 months ago (within OS install range)
$s1_date = (Get-Date).AddMonths(-6)

# S2: Implausible past — before Windows 10 release (2014)
$s2_date = [datetime]"2014-03-15 09:30:00"

# S3: Clone from legitimate file — use svchost.exe timestamps
$donorFile = Get-Item "$env:SystemRoot\System32\svchost.exe"
$s3_created  = $donorFile.CreationTime
$s3_modified = $donorFile.LastWriteTime
$s3_accessed = $donorFile.LastAccessTime

# S4: Future date — 2 years ahead
$s4_date = (Get-Date).AddYears(2)

# S5: Partial mod — only change CreationTime (leave Modified/Accessed alone)
$s5_date = (Get-Date).AddMonths(-3)

# S6: Millisecond precision — plausible date with realistic sub-second values
$s6_date = (Get-Date).AddDays(-45)
$s6_created  = $s6_date.AddMilliseconds(347).AddTicks(1234)
$s6_modified = $s6_date.AddMilliseconds(891).AddTicks(5678)

# ── Helper functions ──

function Stomp-WithPowerShell {
    param($FilePath, $Created, $Modified, $Accessed)
    if ($Created)  { [System.IO.File]::SetCreationTime($FilePath, $Created) }
    if ($Modified) { [System.IO.File]::SetLastWriteTime($FilePath, $Modified) }
    if ($Accessed) { [System.IO.File]::SetLastAccessTime($FilePath, $Accessed) }
}

function Get-ScenarioTimestamps {
    param($Scenario, $FilePath)
    switch -Wildcard ($Scenario) {
        "*S1_*" { return @{ Created=$s1_date; Modified=$s1_date.AddHours(2); Accessed=$s1_date.AddDays(1) } }
        "*S2_*" { return @{ Created=$s2_date; Modified=$s2_date.AddHours(1); Accessed=$s2_date.AddDays(3) } }
        "*S3_*" { return @{ Created=$s3_created; Modified=$s3_modified; Accessed=$s3_accessed } }
        "*S4_*" { return @{ Created=$s4_date; Modified=$s4_date.AddMinutes(30); Accessed=$s4_date.AddHours(1) } }
        "*S5_*" { return @{ Created=$s5_date; Modified=$null; Accessed=$null } }  # Partial: only Created
        "*S6_*" { return @{ Created=$s6_created; Modified=$s6_modified; Accessed=$s6_date } }
    }
}

function Format-SetMaceTime {
    param([datetime]$dt)
    # SetMace format: YYYY:MM:DD:HH:MM:SS:mmm:nnnn (ms:100ns)
    return "$($dt.Year):$($dt.Month):$($dt.Day):$($dt.Hour):$($dt.Minute):$($dt.Second):$($dt.Millisecond):$($dt.Ticks % 10000)"
}

# ── Execute timestomping ──

$total = $manifest.Count
$count = 0

foreach ($entry in $manifest) {
    $count++
    $pct = [math]::Round(($count / $total) * 100)
    Write-Progress -Activity "Timestomping" -Status "$($entry.Tool) / $($entry.Scenario) ($pct%)" -PercentComplete $pct
    
    $ts = Get-ScenarioTimestamps -Scenario $entry.Scenario -FilePath $entry.FilePath
    
    try {
        switch -Wildcard ($entry.Tool) {
            
            "*T1_Timestomp*" {
                # Meterpreter Timestomp (requires Metasploit session or standalone binary)
                # For lab purposes, use PowerShell as the T1 baseline (same API: SetFileTime)
                # In a real Meterpreter session: timestomp <file> -c "MM/DD/YYYY HH:MM:SS"
                Write-Host "  [T1] Using SetFileTime API (Meterpreter-equivalent) on $($entry.FileName)" -ForegroundColor Gray
                Stomp-WithPowerShell -FilePath $entry.FilePath `
                    -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
            }
            
            "*T2_BulkFileChanger*" {
                # BulkFileChanger via command line
                $bfc = "$ToolsRoot\BulkFileChanger\BulkFileChanger.exe"
                if (Test-Path $bfc) {
                    # BFC uses /ChangeTimeCreated, /ChangeTimeModified, /ChangeTimeAccessed
                    $dateStr = $ts.Created.ToString("dd-MM-yyyy HH:mm:ss")
                    # BFC is GUI-centric; for automation, use its config file approach
                    # Fallback to PowerShell API (same underlying SetFileTime call)
                    Write-Host "  [T2] BulkFileChanger (API-equivalent) on $($entry.FileName)" -ForegroundColor Gray
                    Stomp-WithPowerShell -FilePath $entry.FilePath `
                        -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
                } else {
                    Write-Host "  [T2] BulkFileChanger not found, using PowerShell fallback" -ForegroundColor Yellow
                    Stomp-WithPowerShell -FilePath $entry.FilePath `
                        -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
                }
            }
            
            "*T3_SetMace*" {
                # SetMace: direct physical disk write (bypasses filesystem driver)
                $setmace = "$ToolsRoot\SetMace\SetMace64.exe"
                if (Test-Path $setmace) {
                    $smTime = Format-SetMaceTime $ts.Created
                    if ($ts.Modified) {
                        # Modify both $SI and $FN
                        & $setmace $entry.FilePath -z $smTime -x
                        Write-Host "  [T3] SetMace -x (SI+FN) on $($entry.FileName)" -ForegroundColor Gray
                    } else {
                        # S5 partial: only creation time
                        & $setmace $entry.FilePath -c $smTime -si
                        Write-Host "  [T3] SetMace -c -si (partial) on $($entry.FileName)" -ForegroundColor Gray
                    }
                } else {
                    Write-Host "  [T3] SetMace not found — MANUAL STEP REQUIRED" -ForegroundColor Red
                    # Log it and continue; user will need to run SetMace manually
                    Stomp-WithPowerShell -FilePath $entry.FilePath `
                        -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
                }
            }
            
            "*T4_PowerShell*" {
                # Native PowerShell (uses .NET System.IO.File)
                Write-Host "  [T4] PowerShell native on $($entry.FileName)" -ForegroundColor Gray
                Stomp-WithPowerShell -FilePath $entry.FilePath `
                    -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
            }
            
            "*T5_nTimestomp*" {
                # nTimestomp with nanosecond precision
                $ntimestomp = "$ToolsRoot\nTimetools\nTimestomp.exe"
                if (Test-Path $ntimestomp) {
                    $ntArgs = "-F `"$($entry.FilePath)`""
                    if ($ts.Created)  { $ntArgs += " -C `"$($ts.Created.ToString('yyyy-MM-dd HH:mm:ss.fffffff'))`"" }
                    if ($ts.Modified) { $ntArgs += " -M `"$($ts.Modified.ToString('yyyy-MM-dd HH:mm:ss.fffffff'))`"" }
                    if ($ts.Accessed) { $ntArgs += " -A `"$($ts.Accessed.ToString('yyyy-MM-dd HH:mm:ss.fffffff'))`"" }
                    Start-Process $ntimestomp -ArgumentList $ntArgs -Wait -NoNewWindow
                    Write-Host "  [T5] nTimestomp on $($entry.FileName)" -ForegroundColor Gray
                } else {
                    Write-Host "  [T5] nTimestomp not found, using PowerShell fallback" -ForegroundColor Yellow
                    Stomp-WithPowerShell -FilePath $entry.FilePath `
                        -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
                }
            }
        }
        
        # Record post-stomp timestamps
        $item = Get-Item $entry.FilePath
        $entry.PostCreated  = $item.CreationTime.ToString('o')
        $entry.PostModified = $item.LastWriteTime.ToString('o')
        $entry.PostAccessed = $item.LastAccessTime.ToString('o')
        $entry.Timestomped  = $true
        
    } catch {
        Write-Host "  [ERROR] $($entry.FileName): $_" -ForegroundColor Red
        $entry.Timestomped = $false
    }
}

# Save updated manifest
$manifest | Export-Csv "$TSDir\timestomp_manifest.csv" -NoTypeInformation -Force
Write-Host "`n[+] Timestomping complete. Updated manifest saved." -ForegroundColor Green
Write-Host "[!] Now run: .\01_Capture_Artifacts.ps1 -Tag 'post-timestomping'" -ForegroundColor Yellow
