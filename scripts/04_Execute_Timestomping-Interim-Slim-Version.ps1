# ============================================================
# SCRIPT: 04_Execute_Timestomping.ps1 (INTERIM SLIM VERSION)
# PURPOSE: Apply T1 (SetFileTime API) and T2 (BulkFileChanger equivalent)
#          across all scenarios in the manifest
# RUN AS: Administrator (not strictly needed for T1/T2 but harmless)
# ============================================================

$TSDir = "C:\Research\Data\Timestomped"
$ToolsRoot = "C:\Research\Tools"
$manifest = Import-Csv "$TSDir\timestomp_manifest.csv"

# -- Scenario timestamps --
$s1_date = (Get-Date).AddMonths(-6)
$s2_date = [datetime]"2014-03-15 09:30:00"
$donorFile = Get-Item "$env:SystemRoot\System32\svchost.exe"
$s3_created  = $donorFile.CreationTime
$s3_modified = $donorFile.LastWriteTime
$s3_accessed = $donorFile.LastAccessTime
$s4_date = (Get-Date).AddYears(2)
$s5_date = (Get-Date).AddMonths(-3)
$s6_date = (Get-Date).AddDays(-45)
$s6_created  = $s6_date.AddMilliseconds(347).AddTicks(1234)
$s6_modified = $s6_date.AddMilliseconds(891).AddTicks(5678)

# -- Helper functions --

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
        "*S5_*" { return @{ Created=$s5_date; Modified=$null; Accessed=$null } }
        "*S6_*" { return @{ Created=$s6_created; Modified=$s6_modified; Accessed=$s6_date } }
    }
}

# -- Execute --

$total = $manifest.Count
$count = 0
$skipped = 0

foreach ($entry in $manifest) {
    $count++
    $pct = [math]::Round(($count / $total) * 100)
    Write-Progress -Activity "Timestomping" -Status "$($entry.Tool) / $($entry.Scenario) ($pct%)" -PercentComplete $pct

    $ts = Get-ScenarioTimestamps -Scenario $entry.Scenario -FilePath $entry.FilePath

    try {
        switch -Wildcard ($entry.Tool) {
            "*T1_Timestomp*" {
                Write-Host "  [T1] SetFileTime API on $($entry.FileName)" -ForegroundColor Gray
                Stomp-WithPowerShell -FilePath $entry.FilePath -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
            }
            "*T2_BulkFileChanger*" {
                Write-Host "  [T2] BulkFileChanger equivalent on $($entry.FileName)" -ForegroundColor Gray
                Stomp-WithPowerShell -FilePath $entry.FilePath -Created $ts.Created -Modified $ts.Modified -Accessed $ts.Accessed
            }
            default {
                Write-Host "  [SKIP] $($entry.Tool) deferred for post-interim execution" -ForegroundColor DarkYellow
                $skipped++
                continue
            }
        }

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

$manifest | Export-Csv "$TSDir\timestomp_manifest.csv" -NoTypeInformation -Force
Write-Host ""
Write-Host "[+] Timestomping complete. Updated manifest saved." -ForegroundColor Green
Write-Host "[+] Stomped: $($count - $skipped) | Skipped: $skipped" -ForegroundColor Green
Write-Host "[!] Now run: .\01_Capture_Artifacts.ps1 -Tag post-timestomping" -ForegroundColor Yellow