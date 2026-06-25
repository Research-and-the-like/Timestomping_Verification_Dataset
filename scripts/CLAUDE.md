# NTFS Timestomping Detection — Validation Pipeline

## What this is
MSc thesis pipeline. PowerShell scripts (00-08) generate a labelled MFT
dataset of timestomped vs legitimate files on Windows VMs; Python scripts
(05-09) compute detection metrics for three methods (A static $SI/$FN,
B $UsnJrnl, C multi-artefact). Ground truth = 300 manipulated target files.

## Your job in this session
Audit scripts 00-09 for correctness bugs that corrupt metrics. Trust nothing.
Trace every number to disk/manifest ground truth. Flag, don't auto-fix.

## Known bugs already found (do NOT just re-report these — verify they're fixed
## and look for SIBLINGS of the same class elsewhere)
1. Script 05: ground-truth labelling used substring `in` match → 56,746
   false positives instead of 300. Fixed to exact FileName match + assert==300.
   CHECK: does any other script (07 C2, 09 per-tool) still use substring matching?
2. Script 04: Post-timestamp write-back sits after the switch but a throw in
   the switch skips it → manifest Post columns empty for T3/T4/T5 despite disk
   being modified. Also timezone drift (+05:45 vs +08:00) — stomps land on wrong
   dates. CHECK: are timestamps set/compared in UTC consistently end to end?
3. Script 04: T1/T2 call Stomp-WithPowerShell even when the named tool binary
   exists → "five tools" are really ~3 mechanisms (PowerShell, SetMace, nTimestomp).
   CHECK: does any file actually invoke the T3/T5 binaries, or always fall back?
4. Method A: rules A2 and A4-modified have TPR ~0 and FPR ~0.45 — anti-rules.
   The aggregate FPR is an OR-of-all-rules strawman.
5. Script 06 (Method B): KeyError branch sets B1=True, B3=True for any file with
   no UsnJrnl entry → floods FPR when run over full 516k-row MFT. NOT yet fixed.
6. Script 07 (Method C): C1 only evaluates *.EXE; all targets are .txt → C1 can
   never fire on the corpus. NOT yet fixed.

## Rules
- Never trust the manifest's own flags; verify against disk or parsed MFT.
- Any metric-bearing join must assert expected row counts.
- Flag silent failures (no-op stomps, skipped write-backs, empty matches).
- Never use em dashes.