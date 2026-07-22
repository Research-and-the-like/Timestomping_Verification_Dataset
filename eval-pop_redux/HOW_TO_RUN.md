# How and When to Run the Redux Scripts

## Short answer

The redux scripts **do not replace the numbered pipeline**. They replace the
role of **script `09` only** (the metrics stage). Everything `00`-`08` (and
`05`-`07`) runs exactly as before. The redux scripts slot in **after `07`** and
consume what it produced.

## Where they fit

```
00 Install - 00b Verify - 01 Capture - 02 Baselines - 03 Targets - 04 Stomp
                                          |
                              (01 -Tag post-timestomping)
                                          |
            05 Build dataset - 06 Method B - 07 Method C
                                          |
                          Parsed\analysis_dataset.csv   <- the handoff file
                                          |
        +---------------------------------+-----------------------------------+
   09 (original)                                          eval-pop_redux (NEW)
   whole-MFT metrics                                 1. extract_baseline_labels.py
   (legacy / base-rate)                              2. build_eval_population.py
                                                     3. compute_scoped_metrics.py
```

`09` and the redux both read the same `analysis_dataset.csv`. The only
difference is the **population** they score over:

| | Population | Can answer RQ1? |
|---|---|---|
| `09` (original) | the whole ~516k-row MFT (base-rate dominated) | No |
| redux | controlled positives (300 targets) + L1-L15 negatives | Yes |

You can still run `09` for the whole-MFT contrast in the writeup, but the redux
is the one to cite for RQ1.

## What each redux script does

1. **`extract_baseline_labels.py`** *(optional, higher fidelity)*
   Diffs each baseline operation's `pre-`/`post-` MFT captures (produced by `02`)
   to recover files created/modified **anywhere**, including install artefacts
   outside `C:\Research\Data\Baseline` (e.g. `C:\Program Files`, and L1/L8 which
   only touch system/cloud paths). Writes `baseline_labels.csv`.

2. **`build_eval_population.py`**
   Restricts the metric population to a controlled, labelled set:
   - `positive` = the 300 timestomped targets (`timestomp_manifest` `Label==1`)
   - `negative` = files touched by the L1-L15 baselines (directory-scope under
     `...\Baseline\L<n>_...`, unioned with `baseline_labels.csv` if present)
   - everything else is dropped from the metric population

   Asserts `positives == 300` and `negatives > 0`, tags rows with the OS, and
   writes `Parsed\eval_population_<os>.csv`.

3. **`compute_scoped_metrics.py`**
   Computes metrics over the controlled population and writes
   `Parsed\metrics_report_scoped.json`:
   - overall + per-OS precision/recall/F1/FPR/FNR
   - **per-category (L1-L15) FPR per method and per rule** (the RQ1 deliverable)
   - per-rule TPR (over positives) vs FPR (over controlled negatives)
   - per-tool / per-scenario recall against the shared controlled negatives

## When to run, per VM

On **each** OS VM, after its pipeline has already produced
`analysis_dataset.csv` (i.e. `00`-`08` and `05`-`07` are done):

```powershell
python extract_baseline_labels.py          # optional; needs 02's pre/post captures
python build_eval_population.py --os w10    # writes Parsed\eval_population_w10.csv
```

Then on the Win11 VM, the same with `--os w11` -> `eval_population_w11.csv`.

## Producing the final report

`compute_scoped_metrics.py` globs **all** `Parsed\eval_population_*.csv` and does
the per-OS split itself. The catch: each VM only has its own file, because
`analysis_dataset.csv` is overwritten per OS run. So before the final run,
**gather both `eval_population_w10.csv` and `eval_population_w11.csv` into one
machine's `C:\Research\Data\Parsed\`**, then:

```powershell
python compute_scoped_metrics.py            # writes Parsed\metrics_report_scoped.json
```

If you only ever work on one OS, just run all three on that VM and you are done.

## Dependency summary

| Redux script | Needs |
|---|---|
| `extract_baseline_labels.py` | `02`'s `pre-*`/`post-*` MFT captures in `Artifacts\`. Skip it if you did not capture per-operation; directory-scope labelling still works without it. |
| `build_eval_population.py` | `analysis_dataset.csv` (from `05`-`07`) + `timestomp_manifest.csv` (from `03`/`04`); optionally `baseline_labels.csv` from step 1. |
| `compute_scoped_metrics.py` | one or more `eval_population_*.csv` from step 2. |

## The one routine change

After `07`, run the three redux scripts **instead of (or in addition to) `09`**.
Nothing else about your existing flow changes.
