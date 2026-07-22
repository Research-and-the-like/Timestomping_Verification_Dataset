# ============================================================
# compute_scoped_metrics.py   (evaluation-population redesign)
# ============================================================
# Computes detection metrics over the CONTROLLED population produced by
# build_eval_population.py (positives = 300 timestomped targets, negatives =
# L1-L15 baselines) instead of the whole 516k-row MFT.
#
# Produces the deliverables the original 09 could not:
#   * Overall precision/recall/F1/FPR/FNR on a controlled population
#   * RQ1: per-category (L1-L15) FPR per method AND per rule
#   * Per-OS breakdown (Win10 vs Win11)
#   * Per-tool / per-scenario recall against the SHARED controlled negatives
#   * Per-rule TPR (over positives) and FPR (over all controlled negatives)
#
# INPUT  : C:\Research\Data\Parsed\eval_population_*.csv  (one per OS)
# OUTPUT : C:\Research\Data\Parsed\metrics_report_scoped.json
#
# USAGE  : python compute_scoped_metrics.py
# ============================================================

import glob
import json
import pandas as pd
from pathlib import Path

print("============== compute_scoped_metrics.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")

METHODS = ["MethodA_Flagged", "MethodA_Pruned_Flagged",
           "MethodB_Flagged", "MethodC_Flagged",
           "MethodAB_Flagged", "MethodABC_Flagged"]

RULE_PREFIXES = ("A1_", "A2_", "A3_", "A4_", "A5_",
                 "B1_", "B2_", "B3_", "C1_", "C2_")


def compute_metrics(y_true, y_pred):
    tp = int(((y_pred == 1) & (y_true == 1)).sum())
    fp = int(((y_pred == 1) & (y_true == 0)).sum())
    fn = int(((y_pred == 0) & (y_true == 1)).sum())
    tn = int(((y_pred == 0) & (y_true == 0)).sum())
    precision = tp / (tp + fp) if (tp + fp) else 0
    recall = tp / (tp + fn) if (tp + fn) else 0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0
    fpr = fp / (fp + tn) if (fp + tn) else 0
    fnr = fn / (fn + tp) if (fn + tp) else 0
    return {"TP": tp, "FP": fp, "FN": fn, "TN": tn,
            "Precision": round(precision, 4), "Recall": round(recall, 4),
            "F1": round(f1, 4), "FPR": round(fpr, 4), "FNR": round(fnr, 4)}


def load_population():
    files = sorted(glob.glob(str(DATA_ROOT / "Parsed" / "eval_population_*.csv")))
    if not files:
        raise SystemExit("[!] No eval_population_*.csv found. Run build_eval_population.py first.")
    frames = []
    for f in files:
        print(f"[+] Loading {Path(f).name}")
        frames.append(pd.read_csv(f, low_memory=False))
    df = pd.concat(frames, ignore_index=True)
    df["_y"] = (df["EvalClass"] == "positive").astype(int)
    return df


def methods_present(df):
    return [m for m in METHODS if m in df.columns]


def rules_present(df):
    return [c for c in df.columns if c.startswith(RULE_PREFIXES)]


def main():
    df = load_population()
    methods = methods_present(df)
    rules = rules_present(df)

    pos = df[df["EvalClass"] == "positive"]
    neg = df[df["EvalClass"] == "negative"]
    print(f"\n[i] Population: {len(pos):,} positives, {len(neg):,} negatives "
          f"across OS tags {sorted(df['OSTag'].unique())}\n")

    results = {"Population": {"positives": int(len(pos)),
                             "negatives": int(len(neg)),
                             "os_tags": sorted(df["OSTag"].astype(str).unique())}}

    # --- Overall (controlled population) ---
    results["Overall"] = {m: compute_metrics(df["_y"], df[m].astype(int)) for m in methods}

    # --- Per-OS ---
    results["PerOS"] = {}
    for os_tag, g in df.groupby("OSTag"):
        results["PerOS"][str(os_tag)] = {
            m: compute_metrics(g["_y"], g[m].astype(int)) for m in methods}

    # --- RQ1: per-category FPR per method (negatives only) ---
    # Every row here is a negative, so FPR == flag-rate within the category.
    results["PerCategory_MethodFPR"] = {}
    for cat, g in neg.groupby("BaselineCategory"):
        name = g["BaselineCategoryName"].iloc[0] if "BaselineCategoryName" in g else cat
        entry = {"name": str(name), "n": int(len(g))}
        for m in methods:
            flagged = int(g[m].astype(int).sum())
            entry[m] = {"FPR": round(flagged / len(g), 4), "Flagged": flagged}
        results["PerCategory_MethodFPR"][str(cat)] = entry

    # --- RQ1 (fine grained): per-rule x per-category FPR matrix ---
    results["PerCategory_RuleFPR"] = {}
    for cat, g in neg.groupby("BaselineCategory"):
        row = {"n": int(len(g))}
        for r in rules:
            row[r] = round(g[r].astype(int).mean(), 4)
        results["PerCategory_RuleFPR"][str(cat)] = row

    # --- Per-rule TPR (positives) and aggregate FPR (all controlled negatives) ---
    results["PerRule"] = {}
    for r in rules:
        results["PerRule"][r] = {
            "TruePositiveRate": round(pos[r].astype(int).mean(), 4) if len(pos) else 0,
            "FalsePositiveRate": round(neg[r].astype(int).mean(), 4) if len(neg) else 0,
            "StompedTriggered": int(pos[r].astype(int).sum()),
            "BaselineTriggered": int(neg[r].astype(int).sum()),
        }

    # --- Per-tool / per-scenario: recall on positives, precision/FPR vs shared negatives ---
    manifest = pd.read_csv(DATA_ROOT / "Timestomped" / "timestomp_manifest.csv")
    df["_fname_lc"] = df["FileName"].astype(str).str.lower()

    def grouped(group_col):
        out = {}
        for key in manifest[group_col].unique():
            grp_files = set(manifest[manifest[group_col] == key]["FileName"].astype(str).str.lower())
            expected = int(((manifest[group_col] == key) & (manifest["Label"] == 1)).sum())
            grp_pos = df[(df["EvalClass"] == "positive") & (df["_fname_lc"].isin(grp_files))]
            assert len(grp_pos) == expected, (
                f"{group_col}={key}: matched {len(grp_pos)} positives, expected {expected}.")
            sub = pd.concat([grp_pos, neg])
            out[str(key)] = {m: compute_metrics(sub["_y"], sub[m].astype(int)) for m in methods}
        return out

    results["PerTool"] = grouped("Tool")
    results["PerScenario"] = grouped("Scenario")

    out_path = DATA_ROOT / "Parsed" / "metrics_report_scoped.json"
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"[+] Scoped metrics saved to {out_path}\n")

    # ---- pretty print the headline tables ----
    print("=" * 78)
    print("OVERALL (controlled population)")
    print("=" * 78)
    print(f"{'Method':<25}{'Prec':>9}{'Recall':>9}{'F1':>9}{'FPR':>9}{'FNR':>9}")
    print("-" * 70)
    for m, v in results["Overall"].items():
        print(f"{m:<25}{v['Precision']:>9.4f}{v['Recall']:>9.4f}"
              f"{v['F1']:>9.4f}{v['FPR']:>9.4f}{v['FNR']:>9.4f}")

    print("\n" + "=" * 78)
    print("RQ1: FALSE POSITIVE RATE PER LEGITIMATE CATEGORY (Method A)")
    print("=" * 78)
    print(f"{'Category':<18}{'Name':<22}{'n':>7}{'A FPR':>9}{'A-Pruned FPR':>14}")
    print("-" * 70)
    for cat, v in sorted(results["PerCategory_MethodFPR"].items()):
        a = v.get("MethodA_Flagged", {}).get("FPR", 0)
        ap = v.get("MethodA_Pruned_Flagged", {}).get("FPR", 0)
        print(f"{cat:<18}{v['name']:<22}{v['n']:>7}{a:>9.4f}{ap:>14.4f}")

    print("\n" + "=" * 78)
    print("PER-RULE: TPR (positives) vs FPR (controlled negatives)")
    print("=" * 78)
    print(f"{'Rule':<30}{'TPR':>10}{'FPR':>10}{'StompHits':>12}{'BaseHits':>10}")
    print("-" * 72)
    for r, v in sorted(results["PerRule"].items()):
        print(f"{r:<30}{v['TruePositiveRate']:>10.4f}{v['FalsePositiveRate']:>10.4f}"
              f"{v['StompedTriggered']:>12}{v['BaselineTriggered']:>10}")


if __name__ == "__main__":
    main()
