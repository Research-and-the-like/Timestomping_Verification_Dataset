# ============================================================
# 09_Compute_Metrics.py
# Compute full precision/recall/F1 breakdown
#          Per-tool, per-scenario, per-OS, per-category
# ============================================================

import pandas as pd
import json
from pathlib import Path

print("============== 07_MethodC_MultiArtifact.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")

def compute_metrics(y_true, y_pred):
    tp = ((y_pred == 1) & (y_true == 1)).sum()
    fp = ((y_pred == 1) & (y_true == 0)).sum()
    fn = ((y_pred == 0) & (y_true == 1)).sum()
    tn = ((y_pred == 0) & (y_true == 0)).sum()
    
    precision = tp / (tp + fp) if (tp + fp) > 0 else 0
    recall    = tp / (tp + fn) if (tp + fn) > 0 else 0
    f1        = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0
    fpr       = fp / (fp + tn) if (fp + tn) > 0 else 0
    fnr       = fn / (fn + tp) if (fn + tp) > 0 else 0
    
    return {
        'TP': int(tp), 'FP': int(fp), 'FN': int(fn), 'TN': int(tn),
        'Precision': round(precision, 4),
        'Recall': round(recall, 4),
        'F1': round(f1, 4),
        'FPR': round(fpr, 4),
        'FNR': round(fnr, 4)
    }

def main():
    df = pd.read_csv(DATA_ROOT / "Parsed" / "analysis_dataset.csv", low_memory=False)
    manifest = pd.read_csv(DATA_ROOT / "Timestomped" / "timestomp_manifest.csv")
    
    methods = ['MethodA_Flagged', 'MethodB_Flagged', 'MethodC_Flagged',
               'MethodAB_Flagged', 'MethodABC_Flagged']
    
    results = {}
    
    # --- Overall metrics ---
    results['Overall'] = {}
    for m in methods:
        if m in df.columns and 'GroundTruth_Timestomped' in df.columns:
            results['Overall'][m] = compute_metrics(
                df['GroundTruth_Timestomped'], df[m].astype(int)
            )
    
    # --- Per-tool breakdown ---
    results['PerTool'] = {}
    for tool in manifest['Tool'].unique():
        tool_files = set(manifest[manifest['Tool'] == tool]['FileName'].str.lower())
        df_tool = df[df['FileName'].str.lower().isin(tool_files)] if 'FileName' in df.columns else pd.DataFrame()
        if len(df_tool) > 0:
            results['PerTool'][tool] = {}
            for m in methods:
                if m in df_tool.columns:
                    results['PerTool'][tool][m] = compute_metrics(
                        df_tool['GroundTruth_Timestomped'], df_tool[m].astype(int)
                    )
    
    # --- Per-scenario breakdown ---
    results['PerScenario'] = {}
    for scenario in manifest['Scenario'].unique():
        scen_files = set(manifest[manifest['Scenario'] == scenario]['FileName'].str.lower())
        df_scen = df[df['FileName'].str.lower().isin(scen_files)] if 'FileName' in df.columns else pd.DataFrame()
        if len(df_scen) > 0:
            results['PerScenario'][scenario] = {}
            for m in methods:
                if m in df_scen.columns:
                    results['PerScenario'][scenario][m] = compute_metrics(
                        df_scen['GroundTruth_Timestomped'], df_scen[m].astype(int)
                    )
    
    # --- Per-rule detection rates ---
    results['PerRule'] = {}
    rule_cols = [c for c in df.columns if c.startswith(('A1_','A2_','A3_','A4_','A5_',
                                                         'B1_','B2_','B3_',
                                                         'C1_','C2_'))]
    if 'GroundTruth_Timestomped' in df.columns:
        stomped = df[df['GroundTruth_Timestomped'] == 1]
        baseline = df[df['GroundTruth_Timestomped'] == 0]
        for rule in rule_cols:
            if rule in df.columns:
                results['PerRule'][rule] = {
                    'TruePositiveRate': round(stomped[rule].mean(), 4) if len(stomped) > 0 else 0,
                    'FalsePositiveRate': round(baseline[rule].mean(), 4) if len(baseline) > 0 else 0,
                    'StompedTriggered': int(stomped[rule].sum()),
                    'BaselineTriggered': int(baseline[rule].sum())
                }
    
    # Save results
    output_path = DATA_ROOT / "Parsed" / "metrics_report.json"
    with open(output_path, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"[+] Metrics saved to {output_path}")
    
    # Pretty print
    print(f"\n{'='*80}")
    print("OVERALL DETECTION RESULTS")
    print(f"{'='*80}")
    print(f"{'Method':<25} {'Prec':>8} {'Recall':>8} {'F1':>8} {'FPR':>8} {'FNR':>8}")
    print("-" * 65)
    for m, vals in results.get('Overall', {}).items():
        print(f"{m:<25} {vals['Precision']:>8.4f} {vals['Recall']:>8.4f} "
              f"{vals['F1']:>8.4f} {vals['FPR']:>8.4f} {vals['FNR']:>8.4f}")
    
    print(f"\n{'='*80}")
    print("PER-RULE DETECTION RATES")
    print(f"{'='*80}")
    print(f"{'Rule':<30} {'TPR':>10} {'FPR':>10} {'Stomped Hits':>14} {'Baseline Hits':>15}")
    print("-" * 80)
    for rule, vals in sorted(results.get('PerRule', {}).items()):
        print(f"{rule:<30} {vals['TruePositiveRate']:>10.4f} {vals['FalsePositiveRate']:>10.4f} "
              f"{vals['StompedTriggered']:>14} {vals['BaselineTriggered']:>15}")

if __name__ == "__main__":
    main()
