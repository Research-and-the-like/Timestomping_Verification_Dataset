# Thesis Context: NTFS Timestomping Detection

> Reference summary of the MSc interim submission, plus post-interim
> corrections discovered during code audit. Use this as background context
> when reviewing the pipeline. **The interim's headline metrics are known to
> be contaminated — see "Post-Interim Corrections" before trusting any number.**

## Meta

- **Title:** Evaluating the Reliability and Admissibility of NTFS Timestomping Detection Methods (A Benchmark-Driven Validation Study)
- **Author:** Namal Gunapala Karunaratne (IIT 20211341 / UoW W1898964)
- **Supervisor:** Mr. Sithira Hewaarachchi
- **Programme:** MSc Cyber Security and Digital Forensics, IIT / University of Westminster
- **Interim submitted:** 14 May 2026. **Final due:** 30 July 2026.

## One-paragraph thesis

Timestomping (MITRE ATT&CK T1070.006) is the deliberate manipulation of NTFS
file timestamps to hide malicious activity. Detection via discrepancies between
the $SI and $FN timestamp attributes is well known to practitioners, but no
peer-reviewed study has produced the quantified reliability metrics (false
positive rates, evasion resilience) that courts require for expert evidence.
This research builds a labelled benchmark dataset (~10,500 MFT entries target)
and evaluates three detection methods of escalating sophistication against it,
producing court-admissibility framing across four common-law jurisdictions.

## Research questions

- **RQ1:** What are the false positive rates of $SI vs $FN discrepancy analysis
  across 15+ categories of legitimate Windows operations?
- **RQ2:** How does accuracy change when static MFT analysis is augmented with
  $UsnJrnl correlation and additional artefact cross-referencing?
- **RQ3:** At what sophistication level do detection methods fail, and which
  evasion techniques defeat each?
- **RQ4:** What evidence standards must detection meet for admissibility across
  US (Rule 702/Daubert), UK (CrimPD 19A.5/FSR Code), Australia (s79/Makita),
  and NZ (Evidence Act s25)?

## Methodology (Saunders' onion)

Positivist, deductive, experimental. Controlled experiments in isolated Windows
VMs with known ground-truth inputs. Quantitative detection metrics plus
qualitative legal analysis. Cross-sectional. Tools: raw MFT extraction
(FTK Imager / RawCopy), parsing (MFTECmd, KAPE), correlation (custom Python),
10% manual cross-validation (Autopsy, TSK).

## The three detection methods

| Method | Basis | Rules |
|--------|-------|-------|
| A | Static $SI/$FN discrepancy | A1-A5 |
| B | $UsnJrnl correlation | B1-B3 |
| C | Multi-artefact hybrid (Prefetch + Event Log) | C1-C2 |

### Rule specifications

**Method A (static):**
- A1: $SI Created < $FN Created
- A2: $SI Modified < $SI Created
- A3: $SI Entry Modified < $SI Created
- A4: $SI sub-second precision = .0000000 (created and/or modified)
- A5: all four $SI timestamps identical

**Method B ($UsnJrnl):**
- B1: CLOSE entry but no CREATE entry (and not a system/temp file)
- B2: BASIC_INFO_CHANGE reason code at/near $SI Entry Modified time
- B3: gap between earliest $UsnJrnl activity and $SI timestamps exceeds journal coverage

**Method C (multi-artefact):**
- C1: Prefetch execution time contradicts $SI timestamps
- C2: Sysmon Event ID 2 (or Security 4663) inconsistent with $SI timestamps

## Experimental design

- **Timestomping tools (T1-T5):** T1 Meterpreter, T2 BulkFileChanger, T3 SetMace,
  T4 PowerShell native, T5 Cobalt Strike/nTimestomp.
- **Scenarios (S1-S6):** S1 Plausible past, S2 Implausible past, S3 Clone from
  legit, S4 Future date, S5 Partial mod, S6 Millisecond precision.
- **Legitimate baselines (L1-L15):** Windows Update, MSI/EXE/ZIP installs,
  file copy/move, browser downloads, OneDrive sync, System Restore, AV scan,
  search indexing, defrag, WSL ops, auto-update, hibernation.
- **Evasion levels (E1-E5):** E1 ms precision correction, E2 donor-file cloning,
  E3 $FN manipulation (SetMace), E4 $UsnJrnl clearing, E5 selective evidence
  destruction.
- **Corpus:** 10 files x 6 scenarios x 5 tools = 300 ground-truth targets per OS.
- **OS versions:** Windows 10 22H2 and Windows 11 23H2/24H2.

## Script pipeline

| Script | Role |
|--------|------|
| 00 | Tool install / version pinning |
| 01 | Artefact capture (MFT, $UsnJrnl, Prefetch, Event Logs) |
| 02 | Run L1-L15 legitimate operations |
| 03 | Create 300 timestomp target files + manifest |
| 04 | Execute timestomping (T1-T5 x S1-S6) |
| 05 | Build labelled analysis dataset, compute Method A features |
| 06 | Method B ($UsnJrnl correlation) |
| 07 | Method C (Prefetch + Sysmon) |
| 08 | Evasion levels E1-E5 |
| 09 | Compute metrics (precision/recall/F1/FPR/FNR, per-tool/scenario/rule) |

## Scope

**In:** NTFS only; Win10 22H2 + Win11 23H2/24H2; 5 tools, 6 scenarios, 15 baselines,
5 evasion levels; three detection methods; court-ready validation report;
public dataset (GitHub + Zenodo DOI).

**Out:** other OS/filesystems; ML-based detection (dataset is ML-ready but no
classifier built); real-world case images; artefacts beyond Prefetch/Event Logs;
evasion beyond the 5 defined levels.

## Status at interim (14 May 2026, as submitted)

- Phase 0 (environment): complete, both VMs.
- Phase 1A (baselines L1-L15): partial, Win10 only.
- Phase 1B (timestomping corpus): "complete" on Win10 (300 entries).
- Phase 2 (detection): Method A executed; B and C implemented but not run.
- Phase 3 (evasion): designed only.

---

## Post-Interim Corrections (NOT in the submitted document)

The interim reported provisional Method A results that have since been found
contaminated. Do not cite the original figures. Current state:

1. **Ground-truth labelling was broken (Script 05).** A substring match labelled
   56,746 MFT entries as timestomped instead of 300. Fixed to exact filename
   match with an `assert == 300` guard.

2. **Corrected Method A aggregate (clean labels):**
   - Recall 0.843 (was reported 0.284), FPR 0.710 (was 0.762),
     Precision 0.0007 (was 0.044 — contamination was inflating it).
   - Full-MFT precision is base-rate dominated and should not be a headline.

3. **A2 and A4-modified are anti-rules.** A2: TPR 0.000, FPR 0.475 (zero
   detections, flags 47% of baseline). A4-modified: TPR 0.067, FPR 0.426.
   Pruning both drops FPR from 0.710 to 0.294 with recall unchanged at 0.843.
   The real RQ1 finding is per-rule FP quantification, not an aggregate strawman.

4. **"Five tools" is really ~3 mechanisms (Script 04).** T1/T2 call the
   PowerShell SetFileTime path even when their named binaries exist. Unless the
   SetMace and nTimestomp binaries genuinely ran, T1=T2=T4=T5 are the same API.
   The interim's per-tool table (T1 1.0 / T4 0.717, same code path) is not
   internally consistent and must be reframed or rerun.

5. **Stomps had a write-back + timezone bug (Script 04).** Post-timestamp values
   were not written to the manifest for T3/T4/T5, and observed stomps landed on
   the wrong dates (timezone drift, e.g. +05:45 vs +08:00) rather than the
   intended scenario dates. Stomps must be re-run with UTC handling and verified
   on disk before any per-tool/per-scenario metric is trusted.

6. **Method B not yet safe to run (Script 06).** Its "no $UsnJrnl entry =
   suspicious" default flags most of a 516k-row MFT. Evaluation population must
   be restricted before B is meaningful.

7. **Method C rule C1 is inert (Script 07).** C1 only evaluates `.EXE` files;
   all 300 targets are `.txt`, so C1 cannot fire on the corpus. C2 (Sysmon)
   can catch API-level stomps but is blind to SetMace raw-disk writes.

**Verification discipline going forward:** trust no metric that has not been
traced back to disk or the manifest. Every metric-bearing join asserts its
expected row count.
