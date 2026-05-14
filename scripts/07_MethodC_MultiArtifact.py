# ============================================================
# 07_MethodC_MultiArtifact.py
# Add Prefetch and Event Log cross-referencing
#     Implements detection rules C1 (Prefetch) and C2 (Event Log)
# ============================================================

import pandas as pd
from pathlib import Path
from datetime import datetime, timedelta
import csv

print("============== 07_MethodC_MultiArtifact.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")

def load_prefetch_data(artifacts_dir, tag_pattern="post-timestomping"):
    """Load PECmd parsed Prefetch data."""
    for d in sorted(artifacts_dir.iterdir(), reverse=True):
        if tag_pattern in d.name:
            pf_csv = d / "Prefetch_parsed.csv"
            if pf_csv.exists():
                print(f"[+] Loading Prefetch from {pf_csv}")
                return pd.read_csv(pf_csv, low_memory=False)
    return None

def load_sysmon_events(artifacts_dir, tag_pattern="post-timestomping"):
    """Load Sysmon Event ID 2 (FileCreateTime changed) from parsed EVTX."""
    for d in sorted(artifacts_dir.iterdir(), reverse=True):
        if tag_pattern in d.name:
            evtx_dir = d / "EventLogs"
            sysmon_evtx = evtx_dir / "Sysmon.evtx"
            if sysmon_evtx.exists():
                # Parse with EvtxECmd if not already done
                parsed_csv = d / "Sysmon_parsed.csv"
                if not parsed_csv.exists():
                    import subprocess
                    evtxecmd = list(Path(r"C:\Research\Tools\EZTools").rglob("EvtxECmd.exe"))
                    if evtxecmd:
                        subprocess.run([
                            str(evtxecmd[0]),
                            "-f", str(sysmon_evtx),
                            "--csv", str(d),
                            "--csvf", "Sysmon_parsed.csv"
                        ])
                if parsed_csv.exists():
                    df = pd.read_csv(parsed_csv, low_memory=False)
                    # Filter for Event ID 2 (FileCreateTime changed)
                    if 'EventId' in df.columns:
                        return df[df['EventId'] == 2]
                    elif 'Id' in df.columns:
                        return df[df['Id'] == 2]
    return None

def compute_methodC_features(analysis_df, prefetch_df, sysmon_df):
    """
    C1: Prefetch execution time contradicts $SI timestamps
    C2: Sysmon Event 2 (SetCreationTime) logged for the file
    """
    
    # --- C1: Prefetch contradiction ---
    c1_results = []
    if prefetch_df is not None and 'ExecutableName' in prefetch_df.columns:
        # Build lookup: executable name → set of last-run times
        pf_lookup = {}
        for _, row in prefetch_df.iterrows():
            exe = str(row.get('ExecutableName', '')).upper()
            run_times = []
            for col in prefetch_df.columns:
                if 'LastRun' in col or 'RunTime' in col:
                    t = pd.to_datetime(row.get(col), errors='coerce')
                    if pd.notna(t):
                        run_times.append(t)
            if exe:
                pf_lookup[exe] = run_times
        
        for _, row in analysis_df.iterrows():
            fname = str(row.get('FileName', '')).upper()
            si_created = pd.to_datetime(row.get('si_created'), errors='coerce')
            
            if fname.endswith('.EXE') and fname in pf_lookup and pd.notna(si_created):
                pf_times = pf_lookup[fname]
                # If prefetch shows execution BEFORE $SI claims file was created
                contradiction = any(t < si_created - timedelta(hours=1) for t in pf_times)
                c1_results.append(contradiction)
            else:
                c1_results.append(False)
    else:
        c1_results = [False] * len(analysis_df)
    
    analysis_df['C1_Prefetch_Contradiction'] = c1_results
    
    # --- C2: Sysmon Event 2 ---
    c2_results = []
    if sysmon_df is not None:
        # Build set of filenames with SetCreationTime events
        sysmon_files = set()
        for col in ['TargetFilename', 'PayloadData1', 'MapDescription']:
            if col in sysmon_df.columns:
                sysmon_files.update(sysmon_df[col].dropna().str.lower().tolist())
        
        for _, row in analysis_df.iterrows():
            fpath = str(row.get('FullPath', row.get('FileName', ''))).lower()
            c2_results.append(any(fpath in sf for sf in sysmon_files))
    else:
        c2_results = [False] * len(analysis_df)
    
    analysis_df['C2_Sysmon_SetCreationTime'] = c2_results
    
    # Combined scores
    c_cols = ['C1_Prefetch_Contradiction', 'C2_Sysmon_SetCreationTime']
    analysis_df['MethodC_Score'] = analysis_df[c_cols].sum(axis=1)
    analysis_df['MethodC_Flagged'] = analysis_df['MethodC_Score'] > 0
    analysis_df['MethodABC_Flagged'] = (
        analysis_df['MethodA_Flagged'] |
        analysis_df['MethodB_Flagged'] |
        analysis_df['MethodC_Flagged']
    )
    
    return analysis_df

def main():
    analysis_path = DATA_ROOT / "Parsed" / "analysis_dataset.csv"
    df = pd.read_csv(analysis_path, low_memory=False)
    
    pf_df = load_prefetch_data(DATA_ROOT / "Artifacts")
    sysmon_df = load_sysmon_events(DATA_ROOT / "Artifacts")
    
    df = compute_methodC_features(df, pf_df, sysmon_df)
    df.to_csv(analysis_path, index=False)
    print(f"[+] Method C features added to {analysis_path}")
    
    # Print comparative results
    if 'GroundTruth_Timestomped' in df.columns:
        print(f"\n{'Method':<25} {'Precision':>10} {'Recall':>10} {'F1':>10} {'TP':>6} {'FP':>6} {'FN':>6}")
        print("-" * 75)
        for method in ['MethodA_Flagged', 'MethodB_Flagged', 'MethodC_Flagged',
                       'MethodAB_Flagged', 'MethodABC_Flagged']:
            if method in df.columns:
                tp = ((df[method]) & (df['GroundTruth_Timestomped'] == 1)).sum()
                fp = ((df[method]) & (df['GroundTruth_Timestomped'] == 0)).sum()
                fn = ((~df[method]) & (df['GroundTruth_Timestomped'] == 1)).sum()
                p = tp / (tp + fp) if (tp + fp) > 0 else 0
                r = tp / (tp + fn) if (tp + fn) > 0 else 0
                f1 = 2*p*r / (p+r) if (p+r) > 0 else 0
                print(f"{method:<25} {p:>10.4f} {r:>10.4f} {f1:>10.4f} {tp:>6} {fp:>6} {fn:>6}")

if __name__ == "__main__":
    main()
