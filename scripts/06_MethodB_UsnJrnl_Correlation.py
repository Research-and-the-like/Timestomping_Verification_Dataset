# ============================================================
# 06_MethodB_UsnJrnl_Correlation.py
# Correlate MFT timestamps with $UsnJrnl entries
#      Implements detection rules B1, B2, B3
# ============================================================

import pandas as pd
from pathlib import Path
from datetime import timedelta

print("============== 06_MethodB_UsnJrnl_Correlation.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")

def load_usnjrnl(artifacts_dir, tag_pattern="post-timestomping"):
    """Load parsed UsnJrnl data."""
    for d in sorted(artifacts_dir.iterdir(), reverse=True):
        if tag_pattern in d.name:
            usn_csv = d / "UsnJrnl_raw.csv"
            if usn_csv.exists():
                print(f"[+] Loading UsnJrnl from {usn_csv}")
                return pd.read_csv(usn_csv, low_memory=False)
    return None

def compute_methodB_features(analysis_df, usn_df):
    """
    B1: File has CLOSE but no CREATE in $UsnJrnl (strong)
    B2: BASIC_INFO_CHANGE reason code present (strong)
    B3: Timestamp/journal coverage gap (moderate)
    """
    
    # Index UsnJrnl by filename for lookup
    if 'FileName' in usn_df.columns:
        usn_by_file = usn_df.groupby('FileName')
    else:
        print("[!] UsnJrnl CSV doesn't have expected columns. Check format.")
        return analysis_df
    
    b1_results = []
    b2_results = []
    b3_results = []
    
    for idx, row in analysis_df.iterrows():
        fname = row.get('FileName', '')
        if not fname:
            b1_results.append(False)
            b2_results.append(False)
            b3_results.append(False)
            continue
        
        # Get UsnJrnl entries for this file
        try:
            file_usn = usn_by_file.get_group(fname)
        except KeyError:
            # No UsnJrnl entries at all — suspicious for an existing file
            b1_results.append(True)  # No CREATE = suspicious
            b2_results.append(False)
            b3_results.append(True)  # Gap in coverage
            continue
        
        reasons = file_usn['Reason'].str.upper() if 'Reason' in file_usn.columns else pd.Series()
        
        # B1: CLOSE exists but no CREATE
        has_close = reasons.str.contains('CLOSE', na=False).any()
        has_create = reasons.str.contains('FILE_CREATE', na=False).any()
        b1_results.append(has_close and not has_create)
        
        # B2: BASIC_INFO_CHANGE present
        has_basic_info = reasons.str.contains('BASIC_INFO_CHANGE', na=False).any()
        b2_results.append(has_basic_info)
        
        # B3: SI Created claims file is older than earliest UsnJrnl entry
        si_created = pd.to_datetime(row.get('si_created'), errors='coerce')
        if 'Timestamp' in file_usn.columns and pd.notna(si_created):
            earliest_usn = pd.to_datetime(file_usn['Timestamp']).min()
            b3_results.append(si_created < earliest_usn - timedelta(days=1))
        else:
            b3_results.append(False)
    
    analysis_df['B1_Close_No_Create'] = b1_results
    analysis_df['B2_BasicInfoChange'] = b2_results
    analysis_df['B3_Timestamp_Gap'] = b3_results
    
    b_cols = ['B1_Close_No_Create', 'B2_BasicInfoChange', 'B3_Timestamp_Gap']
    analysis_df['MethodB_Score'] = analysis_df[b_cols].sum(axis=1)
    analysis_df['MethodB_Flagged'] = analysis_df['MethodB_Score'] > 0
    
    # Combined A+B
    analysis_df['MethodAB_Flagged'] = analysis_df['MethodA_Flagged'] | analysis_df['MethodB_Flagged']
    
    return analysis_df

def main():
    analysis_path = DATA_ROOT / "Parsed" / "analysis_dataset.csv"
    df = pd.read_csv(analysis_path, low_memory=False)
    
    usn_df = load_usnjrnl(DATA_ROOT / "Artifacts")
    if usn_df is not None:
        df = compute_methodB_features(df, usn_df)
        df.to_csv(analysis_path, index=False)
        print(f"[+] Method B features added to {analysis_path}")
        
        if 'GroundTruth_Timestomped' in df.columns:
            for method in ['MethodA_Flagged', 'MethodB_Flagged', 'MethodAB_Flagged']:
                tp = ((df[method]) & (df['GroundTruth_Timestomped'] == 1)).sum()
                fp = ((df[method]) & (df['GroundTruth_Timestomped'] == 0)).sum()
                fn = ((~df[method]) & (df['GroundTruth_Timestomped'] == 1)).sum()
                p = tp / (tp + fp) if (tp + fp) > 0 else 0
                r = tp / (tp + fn) if (tp + fn) > 0 else 0
                f1 = 2*p*r / (p+r) if (p+r) > 0 else 0
                print(f"  {method}: P={p:.4f} R={r:.4f} F1={f1:.4f} (TP={tp} FP={fp} FN={fn})")

if __name__ == "__main__":
    main()
