# ============================================================
# 05_Build_Analysis_Dataset.py
# MFT parsed data with ground-truth manifest
#    to create the labelled detection dataset
# ============================================================

import pandas as pd
import os
from pathlib import Path
from datetime import datetime

print("============== 05_Build_Analysis_Dataset.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")
ARTIFACTS_DIR = DATA_ROOT / "Artifacts"
OUTPUT_DIR = DATA_ROOT / "Parsed"

def load_mft_csv(tag_pattern):
    """Find and load MFT_parsed.csv from an artifact capture."""
    for d in sorted(ARTIFACTS_DIR.iterdir(), reverse=True):
        if tag_pattern in d.name:
            mft_csv = d / "MFT_parsed.csv"
            if mft_csv.exists():
                print(f"[+] Loading MFT from {mft_csv}")
                return pd.read_csv(mft_csv, low_memory=False)
    print(f"[!] No MFT CSV found matching '{tag_pattern}'")
    return None

def extract_timestamps(mft_df):
    """Extract and pair $SI and $FN timestamps from MFTECmd output."""
    # MFTECmd column names (may vary slightly by version)
    si_cols = {
        'si_created':  'Created0x10',
        'si_modified': 'LastModified0x10',
        'si_accessed': 'LastAccess0x10',
        'si_entry_mod': 'LastRecordChange0x10'
    }
    fn_cols = {
        'fn_created':  'Created0x30',
        'fn_modified': 'LastModified0x30',
        'fn_accessed': 'LastAccess0x30',
        'fn_entry_mod': 'LastRecordChange0x30'
    }
    
    # Rename for consistency
    rename_map = {}
    for new_name, old_name in {**si_cols, **fn_cols}.items():
        if old_name in mft_df.columns:
            rename_map[old_name] = new_name
    
    df = mft_df.rename(columns=rename_map)
    
    # Parse timestamps
    ts_cols = list(si_cols.keys()) + list(fn_cols.keys())
    for col in ts_cols:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors='coerce')
    
    return df

def compute_detection_features(df):
    """Compute detection rule features (Method A)."""
    
    # A1: $SI Created < $FN Created (strong indicator)
    df['A1_SI_Created_LT_FN'] = df['si_created'] < df['fn_created']
    
    # A2: $SI Modified < $SI Created (M before C anomaly)
    df['A2_SI_Mod_LT_SI_Created'] = df['si_modified'] < df['si_created']
    
    # A3: $SI Entry Modified < $SI Created
    df['A3_SI_Entry_LT_SI_Created'] = df['si_entry_mod'] < df['si_created']
    
    # A4: Sub-second precision = .0000000 (all zeros)
    for ts_col in ['si_created', 'si_modified']:
        if ts_col in df.columns:
            col_name = f'A4_ZeroSubSec_{ts_col}'
            df[col_name] = df[ts_col].apply(
                lambda x: x.microsecond == 0 and x.nanosecond == 0 
                if pd.notna(x) else False
            )
    
    # A5: All four $SI timestamps identical
    df['A5_All_SI_Identical'] = (
        (df['si_created'] == df['si_modified']) &
        (df['si_modified'] == df['si_accessed']) &
        (df['si_accessed'] == df['si_entry_mod'])
    )
    

    # Naive OR of all six rule-features (the strawman baseline).
    # Explicit list rather than a startswith('A') regex, which could silently absorb any
    # future MFT column shaped like "A<digit>...".
    a_flag_cols = ['A1_SI_Created_LT_FN', 'A2_SI_Mod_LT_SI_Created',
                   'A3_SI_Entry_LT_SI_Created', 'A4_ZeroSubSec_si_created',
                   'A4_ZeroSubSec_si_modified', 'A5_All_SI_Identical']
    a_flag_cols = [c for c in a_flag_cols if c in df.columns]
    df['MethodA_Score'] = df[a_flag_cols].sum(axis=1)
    df['MethodA_Flagged'] = df['MethodA_Score'] > 0

    # Pruned ruleset: drop A2 (TPR 0.000, FPR 0.475) and A4-modified
    # (TPR 0.067, FPR 0.426). Both generate the noise floor without detection value.
    pruned_cols = ['A1_SI_Created_LT_FN', 'A3_SI_Entry_LT_SI_Created',
                   'A4_ZeroSubSec_si_created', 'A5_All_SI_Identical']
    pruned_cols = [c for c in pruned_cols if c in df.columns]
    df['MethodA_Pruned_Flagged'] = df[pruned_cols].sum(axis=1) > 0

    return df

def main():
    # Load post-timestomping MFT
    mft_post = load_mft_csv("post-timestomping")
    if mft_post is None:
        print("[!] Run artifact capture first: .\\01_Capture_Artifacts.ps1 -Tag 'post-timestomping'")
        return
    
    # Extract and compute features
    df = extract_timestamps(mft_post)

    # Restrict to ACTIVE (in-use) MFT records before anything else. MFTECmd emits deleted
    # records too; leaving them in (a) bloats the negative class and deflates FPR via an
    # inflated TN denominator, and (b) can let a stale deleted record sharing a target's
    # filename inflate the positive count and trip the assert below.
    if 'InUse' in df.columns:
        before = len(df)
        mask = df['InUse'].astype(str).str.strip().str.lower().isin(['true', '1'])
        df = df[mask].copy()
        print(f"[i] InUse filter: {before:,} -> {len(df):,} active MFT records")
    else:
        print("[!] No 'InUse' column in MFT CSV; cannot filter deleted records. "
              "Negative-class counts may include deleted entries.")

    df = compute_detection_features(df)
    
    # Load ground-truth manifest
    manifest_path = DATA_ROOT / "Timestomped" / "timestomp_manifest.csv"
    if manifest_path.exists():
        manifest = pd.read_csv(manifest_path)

        # Ground truth = the 300 manifest targets, keyed on Label==1.
        # NOT 'Timestomped' (that drops any row where a tool threw an exception,
        # silently shrinking the positive class).
        target_names = set(
            manifest[manifest['Label'] == 1]['FileName']
            .astype(str).str.lower().str.strip()
        )

        # Always build FullPath (Script 07/C2 expects it; old elif never ran).
        if 'ParentPath' in df.columns and 'FileName' in df.columns:
            df['FullPath'] = (
                df['ParentPath'].fillna('').astype(str).str.rstrip('\\')
                + '\\' + df['FileName'].fillna('').astype(str)
            )

        # EXACT filename match. Filenames are globally unique, so this is
        # equivalent to a full-path join with none of the prefix mismatch risk.
        df['GroundTruth_Timestomped'] = (
            df['FileName'].astype(str).str.lower().str.strip()
            .isin(target_names).astype(int)
        )

        n_pos = int(df['GroundTruth_Timestomped'].sum())
        n_expected = len(target_names)
        print(f"[i] manifest targets: {n_expected} | MFT rows labelled positive: {n_pos}")
        assert n_pos == n_expected, (
            f"GROUND TRUTH MISMATCH: expected {n_expected}, got {n_pos}. "
            f"Pipeline halted to prevent contaminated metrics."
        )

    # Save analysis dataset
    output_path = OUTPUT_DIR / "analysis_dataset.csv"
    df.to_csv(output_path, index=False)
    
    # Summary stats
    print(f"\n{'='*60}")
    print(f"Analysis Dataset: {output_path}")
    print(f"Total MFT entries:    {len(df):,}")
    if 'GroundTruth_Timestomped' in df.columns:
        ts_count = df['GroundTruth_Timestomped'].sum()
        print(f"Timestomped (ground truth): {ts_count:,}")
        print(f"Baseline:                   {len(df) - ts_count:,}")
    if 'MethodA_Flagged' in df.columns:
        flagged = df['MethodA_Flagged'].sum()
        print(f"\nMethod A flagged:  {flagged:,}")
        if 'GroundTruth_Timestomped' in df.columns:
            tp = ((df['MethodA_Flagged']) & (df['GroundTruth_Timestomped'] == 1)).sum()
            fp = ((df['MethodA_Flagged']) & (df['GroundTruth_Timestomped'] == 0)).sum()
            fn = ((~df['MethodA_Flagged']) & (df['GroundTruth_Timestomped'] == 1)).sum()
            tn = ((~df['MethodA_Flagged']) & (df['GroundTruth_Timestomped'] == 0)).sum()
            precision = tp / (tp + fp) if (tp + fp) > 0 else 0
            recall = tp / (tp + fn) if (tp + fn) > 0 else 0
            f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0
            print(f"  TP: {tp}  FP: {fp}  FN: {fn}  TN: {tn}")
            print(f"  Precision: {precision:.4f}  Recall: {recall:.4f}  F1: {f1:.4f}")
    print(f"{'='*60}")

if __name__ == "__main__":
    main()
