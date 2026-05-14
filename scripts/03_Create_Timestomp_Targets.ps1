# ============================================================
# SCRIPT: 03_Create_Timestomp_Targets.ps1
# PURPOSE: Create 30 target files (5 tools × 6 scenarios)
#          Each file gets a unique name encoding its treatment
# ============================================================

$TSDir = "C:\Research\Data\Timestomped"
$TargetDir = "$TSDir\Targets"
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

$tools = @("T1_Timestomp", "T2_BulkFileChanger", "T3_SetMace", "T4_PowerShell", "T5_nTimestomp")
$scenarios = @("S1_PlausiblePast", "S2_ImplausiblePast", "S3_CloneFromLegit",
               "S4_FutureDate", "S5_PartialMod", "S6_MillisecondPrecision")

$manifest = @()
$fileId = 1

foreach ($tool in $tools) {
    foreach ($scenario in $scenarios) {
        $dirPath = "$TargetDir\${tool}\${scenario}"
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        
        # Create 10 target files per combination (for statistical power)
        1..10 | ForEach-Object {
            $fname = "target_${tool}_${scenario}_$( '{0:D3}' -f $fileId ).txt"
            $fpath = "$dirPath\$fname"
            # Write realistic content (not empty — some detection methods check file size)
            $content = @"
Document ID: $fileId
Category: $tool / $scenario
Generated: $(Get-Date -Format 'o')
Content: $(Get-Random -Minimum 100 -Maximum 999) Lorem ipsum dolor sit amet, consectetur adipiscing elit.
Padding: $([guid]::NewGuid().ToString() * 3)
"@
            Set-Content $fpath -Value $content
            
            $manifest += [PSCustomObject]@{
                FileId    = $fileId
                FileName  = $fname
                FilePath  = $fpath
                Tool      = $tool
                Scenario  = $scenario
                PreCreated   = (Get-Item $fpath).CreationTime.ToString('o')
                PreModified  = (Get-Item $fpath).LastWriteTime.ToString('o')
                PreAccessed  = (Get-Item $fpath).LastAccessTime.ToString('o')
                PostCreated  = ""
                PostModified = ""
                PostAccessed = ""
                Timestomped  = $false
                Label        = 1  # 1 = will be timestomped (ground truth)
            }
            $fileId++
        }
    }
}

$manifest | Export-Csv "$TSDir\timestomp_manifest.csv" -NoTypeInformation
Write-Host "[+] Created $($manifest.Count) target files" -ForegroundColor Green
Write-Host "[+] Manifest: $TSDir\timestomp_manifest.csv" -ForegroundColor Green
