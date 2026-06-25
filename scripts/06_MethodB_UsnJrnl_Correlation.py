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

def _find_column(df, candidates):
    """Return the first column in `df` matching any candidate (case/space insensitive)."""
    norm = {str(c).strip().lower().replace(' ', '').replace('_', ''): c for c in df.columns}
    for cand in candidates:
        key = cand.strip().lower().replace(' ', '').replace('_', '')
        if key in norm:
            return norm[key]
    return None


def _normalize_reasons(series):
    """Collapse a Reason column to uppercase alphanumerics so token tests match any
    producer's spelling: fsutil ('File create'), MFTECmd $J ('FileCreate'), and the raw
    USN_REASON_* constants ('FILE_CREATE') all become 'FILECREATE'."""
    return (series.astype(str)
                  .str.upper()
                  .str.replace(r'[^A-Z]', '', regex=True))


def add_empty_methodB(analysis_df, note):
    """Create all-False Method B columns so downstream scripts never KeyError."""
    print(f"[!] {note} Method B columns set to all-False.")
    for col in ['B1_Close_No_Create', 'B2_BasicInfoChange', 'B3_Timestamp_Gap']:
        analysis_df[col] = False
    analysis_df['MethodB_Score'] = 0
    analysis_df['MethodB_Flagged'] = False
    analysis_df['MethodAB_Flagged'] = analysis_df['MethodA_Flagged']
    return analysis_df


def compute_methodB_features(analysis_df, usn_df):
    """
    B1: File has CLOSE but no CREATE in $UsnJrnl (strong)
    B2: BASIC_INFO_CHANGE reason code present (strong)
    B3: Timestamp/journal coverage gap (moderate)
    """

    # Resolve producer-specific column names. fsutil's CSV header differs from a parsed
    # $J (MFTECmd/Velociraptor); resolve both rather than hard-coding 'FileName'/'Reason'.
    fname_col  = _find_column(usn_df, ['FileName', 'File Name', 'Name'])
    reason_col = _find_column(usn_df, ['Reason', 'Reasons', 'UpdateReasons', 'Update Reasons'])
    ts_col     = _find_column(usn_df, ['Timestamp', 'TimeStamp', 'Time Stamp',
                                       'UpdateTimestamp', 'Update Timestamp'])

    if fname_col is None:
        return add_empty_methodB(
            analysis_df,
            f"UsnJrnl CSV has no recognizable filename column (saw {list(usn_df.columns)}).")
    if reason_col is None:
        print("[!] UsnJrnl CSV has no recognizable Reason column; B1/B2 will be False.")

    # Pre-normalize the reason column once for the whole journal.
    if reason_col is not None:
        usn_df = usn_df.copy()
        usn_df['_reason_norm'] = _normalize_reasons(usn_df[reason_col])
    usn_by_file = usn_df.groupby(fname_col)

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

        try:
            file_usn = usn_by_file.get_group(fname)
        except KeyError:
            # No UsnJrnl entries for this file. This is NOT inherently suspicious: the
            # journal only covers recent activity and wraps, so most of a full MFT has no
            # entry. Defaulting these to True floods the FPR to ~1, so they are False here.
            b1_results.append(False)
            b2_results.append(False)
            b3_results.append(False)
            continue

        if reason_col is not None:
            reasons = file_usn['_reason_norm']
            has_close   = reasons.str.contains('CLOSE', na=False).any()
            has_create  = reasons.str.contains('FILECREATE', na=False).any()
            has_basic   = reasons.str.contains('BASICINFOCHANGE', na=False).any()
            b1_results.append(bool(has_close and not has_create))
            b2_results.append(bool(has_basic))
        else:
            b1_results.append(False)
            b2_results.append(False)

        # B3: SI Created claims file is older than earliest UsnJrnl entry
        si_created = pd.to_datetime(row.get('si_created'), errors='coerce')
        if ts_col is not None and pd.notna(si_created):
            earliest_usn = pd.to_datetime(file_usn[ts_col], errors='coerce').min()
            if pd.notna(earliest_usn):
                b3_results.append(bool(si_created < earliest_usn - timedelta(days=1)))
            else:
                b3_results.append(False)
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
    if usn_df is None:
        # Still emit all-False B columns so 07/09 don't KeyError on MethodB_Flagged.
        df = add_empty_methodB(df, "No UsnJrnl CSV found.")
        df.to_csv(analysis_path, index=False)
    else:
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
