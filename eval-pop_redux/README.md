# Evaluation-Population Redesign (`eval-pop_redux`)

This directory contains the redesign that makes **RQ1** answerable. It is
**additive**: it consumes the `analysis_dataset.csv` produced by the (already
fixed) scripts `05`/`06`/`07` and writes new outputs. It does not modify the
existing pipeline.

## The problem it fixes

The original pipeline labelled **300** timestomped targets as positives and
then treated **every other MFT row (~516k)** as a negative. Consequences:

- FPR was base-rate dominated and not attributable to any legitimate operation.
- Precision was meaningless (~0.0007).
- RQ1 ("FPR across 15+ categories of legitimate Windows operations") could not
  be computed at all, because the negatives were never labelled by category.
- `09`'s per-tool/per-scenario tables were degenerate (all-positive subsets ->
  Precision pinned to 1.0, FPR to 0.0).

## The redesign

Restrict the metric population to a **controlled, labelled** set:

| `EvalClass` | Meaning |
|-------------|---------|
| `positive`  | the 300 timestomped targets (`timestomp_manifest` `Label==1`) |
| `negative`  | files produced/touched by the **L1-L15** legitimate baselines |
| *(excluded)*| every other MFT row is dropped from the metric population |

Each negative carries a `BaselineCategory` (`L1`..`L15`), so FPR is reported
**per category of legitimate operation** rather than as one strawman aggregate.

### Two labelling sources (unioned, by fidelity)

1. **Directory scope** (always available, no extra captures): any MFT
   `FullPath` under `...\Baseline\L<n>_...` is category `L<n>`. Reproducible,
   but blind to **L1** (Windows Update) and **L8** (OneDrive), which write only
   to system/cloud locations.
2. **Pre/post MFT diff** (`extract_baseline_labels.py`, optional, higher
   fidelity): diffs each operation's `pre-L<n>` vs `post-L<n>` capture to recover
   files created/modified **anywhere**, including install artefacts in
   `C:\Program Files`. Produces `baseline_labels.csv`, which the builder merges.

## Files

| File | Role |
|------|------|
| `build_eval_population.py` | Labels + restricts the population. Writes `Parsed\eval_population_<os>.csv`. Asserts `positives == 300` and `negatives > 0`. |
| `compute_scoped_metrics.py` | Metrics over the controlled population: overall, per-OS, **per-category FPR (RQ1)**, per-rule × per-category matrix, per-tool/scenario recall vs shared negatives. Writes `Parsed\metrics_report_scoped.json`. |
| `extract_baseline_labels.py` | Optional pre/post-diff labeller for artefacts outside `Baseline\`. Writes `baseline_labels.csv`. |

## Run order

```powershell
# 0. Per OS, the fixed pipeline must already have produced analysis_dataset.csv
#    (scripts 01 -> 05 -> 06 -> 07 on the post-timestomping capture).

# 1. (optional, recommended) recover install artefacts via per-operation diffs
python extract_baseline_labels.py

# 2. build the controlled, labelled population for this OS
python build_eval_population.py --os w10
#    (run again on the Win11 VM's data:  --os w11)

# 3. compute scoped metrics across all eval_population_*.csv
python compute_scoped_metrics.py
```

## How this maps to the research questions

- **RQ1** is now the `PerCategory_MethodFPR` and `PerCategory_RuleFPR` tables:
  the FPR of each rule/method on each of the 15 legitimate categories.
- **RQ2** (does B/C correlation help) is read from `Overall` and `PerCategory`
  comparing `MethodA_*` vs `MethodAB_*`/`MethodABC_*` on the same population.
- **RQ3** (where detection fails) is `PerScenario`/`PerTool` recall plus the
  evasion captures (`eval_population_evasion-level*` if you extend `--os`/glob).

## Known limitations (state these in the writeup)

- Directory-scope negatives exclude L1/L8; use the diff labeller to include them.
- The diff labeller attributes any file changed in an operation's window to that
  category; `--keep-system` is off by default to drop OS churn (`Windows\`,
  pagefile, Defender). Review `baseline_labels.csv` before trusting edge cases.
- Per-tool precision/FPR are now meaningful but share the controlled negative
  pool; **recall** remains the per-tool/per-scenario signal to read.
- Negatives are evaluated in the post-timestomping MFT. This is valid because
  the baselines run before timestomping and their `$SI`/`$FN` values are not
  altered by it, so their Method A/B/C features are identical to their
  post-operation state.
