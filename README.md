# NTFS Timestomping Detection: Benchmark-Driven Validation Study

MSc Cyber Security and Digital Forensics thesis project.
Informatics Institute of Technology in collaboration with University of Westminster.

## Status

This repository accompanies the interim submission (14 May 2026).
The full benchmark execution and dataset publication are scheduled
for completion by 30 July 2026 per the project plan.

| Phase | Status |
|-------|--------|
| Phase 0: Environment setup | Complete |
| Phase 1A: Baseline operations | Partial (L2, L4, L5, L6, L7 on Win10) |
| Phase 1B: Timestomping corpus | Partial (T1, T2 across S1, S3) |
| Phase 2: Detection methods | Method A executed on partial corpus |
| Phase 3: Evasion resilience | Designed, scheduled W10-W14 |

## Repository structure

Timestomping_Verification_Dataset/
├── README.md
├── LICENSE       
├── scripts/
│   ├── 00_Install_Tools.ps1
│   ├── 01_Capture_Artifacts.ps1
│   ├── 02_Run_Baseline_Operations.ps1
│   ├── 03_Create_Timestomp_Targets.ps1
│   ├── 04_Execute_Timestomping-Interim-Slim-Version.ps1   
│   ├── 04_Execute_Timestomping.ps1
│   ├── 05_Build_Analysis_Dataset.py
│   ├── 06_MethodB_UsnJrnl_Correlation.py
│   ├── 07_MethodC_MultiArtifact.py
│   ├── 08_Evasion_Levels.ps1
│   └── 09_Compute_Metrics.py
├── docs/
│   └── implementation_guide.md   
├── sample_outputs/
│   ├── timestomp_manifest.csv      
│   ├── analysis_dataset_sample.csv 
│   ├── method_a_metrics.txt        
│   └── screenshots/
│       ├── 01_vms_baseline_snapshot.png
│       ├── 02_baseline_capture_run.png
│       ├── 03_timestomping_execution.png
│       ├── 04_mft_parsing_output.png
│       └── 05_method_a_metrics_table.png
└── .gitignore

## How to reproduce

1. Build the VMs per `docs/implementation_guide.md` Section 0.
2. Run `scripts/00_Install_Tools.ps1` in each VM.
3. Take BASELINE-CLEAN snapshot.
4. Execute baseline ops via `scripts/02_Legitimate_Operations.ps1` and capture
   with `scripts/01_Capture_Artifacts.ps1`.
5. Execute timestomping via `scripts/03_Create_Timestomp_Targets.ps1` then `scripts/04_Execute_Timestomping.ps1`.
6. Run analysis via `scripts/05_Build_Analysis_Dataset.py` and `scripts/09_Compute_Metrics.py`.

## Sample results

See `sample_outputs/method_a_metrics.txt` and `sample_outputs/screenshots/`.