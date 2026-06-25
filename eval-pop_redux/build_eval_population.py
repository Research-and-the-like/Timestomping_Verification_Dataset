# ============================================================
# build_eval_population.py   (evaluation-population redesign)
# ============================================================
# PROBLEM THIS FIXES
#   The original pipeline treated EVERY non-target MFT row (~516k) as a
#   negative. That makes FPR base-rate dominated, precision meaningless, and
#   leaves RQ1 ("FPR across 15+ categories of legitimate Windows operations")
#   unanswerable, because the negatives were never labelled by category.
#
# WHAT THIS DOES
#   Restricts the metric population to a CONTROLLED, LABELLED set:
#     EvalClass = 'positive'  -> the 300 timestomped targets (manifest Label==1)
#     EvalClass = 'negative'  -> files produced/touched by the L1-L15 baselines
#     (everything else is dropped from the metric population)
#   Each negative carries a BaselineCategory (L1..L15) so RQ1 FPR can be
#   reported per category instead of as one strawman aggregate.
#
# NEGATIVE LABELLING SOURCES (unioned, in order of fidelity)
#   1. baseline_labels.csv  -- optional, produced by extract_baseline_labels.py
#      from per-operation pre/post MFT diffs. Captures install artefacts that
#      land OUTSIDE C:\Research\Data\Baseline (e.g. C:\Program Files\Git).
#   2. Directory scope       -- always available: any MFT FullPath under
#      ...\Baseline\L<n>_... is labelled category L<n>. Reproducible with no
#      extra captures, but cannot see L1 (Windows Update) or L8 (OneDrive),
#      which write only to system/cloud locations.
#
# OUTPUT
#   C:\Research\Data\Parsed\eval_population_<os>.csv
#
# USAGE
#   python build_eval_population.py --os w10
#   python build_eval_population.py --os w11 --expect-positives 300
# ============================================================

import argparse
import re
import pandas as pd
from pathlib import Path

print("============== build_eval_population.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")

# Readable names for the L1-L15 baselines (see thesis-context.md).
CATEGORY_NAMES = {
    "L1": "Windows Update", "L2": "MSI install", "L3": "EXE/NSIS install",
    "L4": "ZIP extraction", "L5": "File copy", "L6": "File move",
    "L7": "Browser download", "L8": "OneDrive sync", "L9": "System Restore",
    "L10": "AV scan", "L11": "Search indexing", "L12": "Defrag",
    "L13": "WSL ops", "L14": "Auto-update", "L15": "Hibernation/Sleep",
    "SEED": "Seed test files", "OTHER_BASELINE": "Other baseline file",
}

_CAT_RE = re.compile(r"\\baseline\\(l\d{1,2})_", re.IGNORECASE)


def normalize_path(p):
    return str(p).strip().lower().replace("/", "\\")


def infer_category_from_path(full_path):
    """Map an MFT FullPath to an L-category via the directory directly under
    ...\\Baseline\\. Returns None for paths outside the baseline tree."""
    s = normalize_path(full_path)
    m = _CAT_RE.search(s)
    if m:
        return m.group(1).upper()
    if "\\baseline\\testfiles\\" in s:
        return "SEED"
    if "\\baseline\\" in s:
        return "OTHER_BASELINE"
    return None


def ensure_fullpath(df):
    """Guarantee a FullPath column (fixed 05 builds it, but be defensive)."""
    if "FullPath" in df.columns and df["FullPath"].notna().any():
        return df
    if "ParentPath" in df.columns and "FileName" in df.columns:
        df["FullPath"] = (
            df["ParentPath"].fillna("").astype(str).str.rstrip("\\")
            + "\\" + df["FileName"].fillna("").astype(str)
        )
    else:
        print("[!] No FullPath/ParentPath; directory-scope labelling disabled.")
        df["FullPath"] = ""
    return df


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--os", default="w10",
                    help="OS tag stamped onto the population (e.g. w10, w11).")
    ap.add_argument("--expect-positives", type=int, default=None,
                    help="Override the expected positive count (default: manifest Label==1).")
    ap.add_argument("--analysis", default=str(DATA_ROOT / "Parsed" / "analysis_dataset.csv"))
    ap.add_argument("--manifest", default=str(DATA_ROOT / "Timestomped" / "timestomp_manifest.csv"))
    ap.add_argument("--labels", default=str(Path(__file__).parent / "baseline_labels.csv"),
                    help="Optional baseline_labels.csv from extract_baseline_labels.py.")
    args = ap.parse_args()

    df = pd.read_csv(args.analysis, low_memory=False)
    df = ensure_fullpath(df)

    if "GroundTruth_Timestomped" not in df.columns:
        raise SystemExit("[!] analysis_dataset.csv has no GroundTruth_Timestomped; run 05 first.")

    # --- expected positive count (ground-truth guard) ---
    expected_pos = args.expect_positives
    if expected_pos is None:
        manifest = pd.read_csv(args.manifest)
        expected_pos = int((manifest["Label"] == 1).sum())

    # --- start every row as excluded ---
    df["EvalClass"] = "excluded"
    df["BaselineCategory"] = ""

    # --- positives: the timestomped targets ---
    pos_mask = df["GroundTruth_Timestomped"] == 1
    df.loc[pos_mask, "EvalClass"] = "positive"

    # --- negatives via directory scope ---
    cat = df["FullPath"].apply(infer_category_from_path)
    dir_neg_mask = cat.notna() & (~pos_mask)
    df.loc[dir_neg_mask, "EvalClass"] = "negative"
    df.loc[dir_neg_mask, "BaselineCategory"] = cat[dir_neg_mask]

    # --- negatives via explicit pre/post-diff labels (higher fidelity) ---
    labels_path = Path(args.labels)
    if labels_path.exists():
        labels = pd.read_csv(labels_path, low_memory=False)
        labels["_key"] = labels["FullPath"].apply(normalize_path)
        # restrict to this OS if the labels file carries an OSTag
        if "OSTag" in labels.columns:
            labels = labels[labels["OSTag"].astype(str).str.lower() == args.os.lower()]
        label_map = dict(zip(labels["_key"], labels["BaselineCategory"]))
        df["_key"] = df["FullPath"].apply(normalize_path)
        ext_mask = df["_key"].isin(label_map) & (~pos_mask)
        df.loc[ext_mask, "EvalClass"] = "negative"
        df.loc[ext_mask, "BaselineCategory"] = df.loc[ext_mask, "_key"].map(label_map)
        df.drop(columns=["_key"], inplace=True)
        print(f"[+] Merged {ext_mask.sum():,} negatives from {labels_path.name}")
    else:
        print(f"[i] No {labels_path.name} found; using directory-scope labelling only.")

    # --- restrict to the controlled population ---
    eval_df = df[df["EvalClass"].isin(["positive", "negative"])].copy()
    eval_df["OSTag"] = args.os
    eval_df["BaselineCategoryName"] = eval_df["BaselineCategory"].map(
        lambda c: CATEGORY_NAMES.get(c, c))

    n_pos = int((eval_df["EvalClass"] == "positive").sum())
    n_neg = int((eval_df["EvalClass"] == "negative").sum())

    # --- ground-truth guards (metric-bearing population must be exact) ---
    assert n_pos == expected_pos, (
        f"POSITIVE COUNT MISMATCH: expected {expected_pos}, got {n_pos}. Halting "
        f"to prevent contaminated metrics.")
    assert n_neg > 0, (
        "No negatives labelled. Did the L1-L15 baselines run, and is the MFT the "
        "post-timestomping capture (which still contains the baseline files)?")

    out = DATA_ROOT / "Parsed" / f"eval_population_{args.os}.csv"
    eval_df.to_csv(out, index=False)

    # --- report ---
    print(f"\n{'='*60}")
    print(f"Evaluation population ({args.os}): {out}")
    print(f"  positives (timestomped targets): {n_pos:,}")
    print(f"  negatives (L1-L15 baselines):    {n_neg:,}")
    print(f"  excluded from metrics:           {len(df) - len(eval_df):,}")
    print(f"\n  Negatives per category:")
    counts = (eval_df[eval_df["EvalClass"] == "negative"]
              .groupby("BaselineCategory").size().sort_index())
    for cat_code, n in counts.items():
        print(f"    {cat_code:<16} {CATEGORY_NAMES.get(cat_code, cat_code):<22} {n:>7,}")
    missing = [c for c in [f"L{i}" for i in range(1, 16)]
               if c not in counts.index]
    if missing:
        print(f"\n  [i] No labelled files for: {', '.join(missing)}")
        print(f"      (L1/L8 write only to system/cloud paths; use "
              f"extract_baseline_labels.py to capture those via pre/post diffs.)")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
