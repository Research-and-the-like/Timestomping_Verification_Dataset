# ============================================================
# 07_MethodC_MultiArtifact.py
# Add Prefetch and Event Log cross-referencing
#     Implements detection rules C1 (Prefetch) and C2 (Event Log)
# ============================================================

import pandas as pd
from pathlib import Path
from datetime import datetime, timedelta
import json
import re
import csv

print("============== 07_MethodC_MultiArtifact.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")

def _normalize_path(p):
    """Normalize a path for cross-source comparison: lowercase, forward->back slashes,
    strip a leading drive letter (Sysmon 'C:\\...') and MFTECmd's volume-relative '.\\'
    prefix so both collapse to 'research\\data\\...\\file.txt'."""
    s = str(p).strip().lower().replace('/', '\\')
    if len(s) >= 2 and s[1] == ':':       # drop leading drive letter, e.g. "c:"
        s = s[2:]
    return s.lstrip('.').lstrip('\\')

def _extract_target_filename(row):
    """EvtxECmd doesn't expose Sysmon Event 2's TargetFilename as its own column, it's
    embedded as 'TargetFilename: <path>' inside whichever PayloadDataN column happens to
    hold it (position isn't stable across schema versions). Prefer the raw Payload JSON
    blob instead, since its field names are stable regardless of PayloadDataN ordering;
    fall back to regex over PayloadData1-6 only if JSON parsing fails."""
    payload = row.get('Payload')
    if pd.notna(payload):
        try:
            data = json.loads(payload)
            for item in data.get('EventData', {}).get('Data', []):
                if item.get('@Name') == 'TargetFilename':
                    return item.get('#text', '')
        except (json.JSONDecodeError, AttributeError, TypeError):
            pass

    for col in ['PayloadData1', 'PayloadData2', 'PayloadData3',
                'PayloadData4', 'PayloadData5', 'PayloadData6']:
        val = row.get(col)
        if pd.notna(val) and 'TargetFilename:' in str(val):
            m = re.search(r'TargetFilename:\s*(.+?)(?:\s{2,}\w[\w ]*:|$)', str(val))
            if m:
                return m.group(1).strip()
    return None

def _latest_capture_dir(artifacts_dir):
    """Most recently modified capture folder, regardless of its -Tag name. Using
    mtime instead of name-sorting matters because evasion captures are tagged
    'evasion-level1-w10' etc, which a tag_pattern='post-timestomping' filter (or an
    alphabetical sort) would silently never match."""
    dirs = [d for d in artifacts_dir.iterdir() if d.is_dir()]
    if not dirs:
        return None
    return max(dirs, key=lambda d: d.stat().st_mtime)

def load_prefetch_data(artifacts_dir):
    """Load PECmd parsed Prefetch data from the most recent capture."""
    d = _latest_capture_dir(artifacts_dir)
    if d is None:
        print(f"[!] No capture folders found under {artifacts_dir}")
        return None
    pf_csv = d / "Prefetch_parsed.csv"
    if pf_csv.exists():
        print(f"[+] Loading Prefetch from {pf_csv}")
        return pd.read_csv(pf_csv, low_memory=False)
    print(f"[!] No Prefetch_parsed.csv found in {d}")
    return None

def load_sysmon_events(artifacts_dir):
    """Load Sysmon Event ID 2 (FileCreateTime changed) from the most recent capture."""
    d = _latest_capture_dir(artifacts_dir)
    if d is None:
        print(f"[!] No capture folders found under {artifacts_dir}")
        return None

    sysmon_evtx = d / "EventLogs" / "Sysmon.evtx"
    if not sysmon_evtx.exists():
        print(f"[!] No Sysmon.evtx found in {d}")
        return None

    parsed_csv = d / "Sysmon_parsed.csv"
    if not parsed_csv.exists():
        import subprocess
        evtxecmd = list(Path(r"C:\Research\Tools\EZTools").rglob("EvtxECmd.exe"))
        if not evtxecmd:
            print("[!] EvtxECmd.exe not found under C:\\Research\\Tools\\EZTools")
            return None
        result = subprocess.run(
            [str(evtxecmd[0]), "-f", str(sysmon_evtx), "--csv", str(d), "--csvf", "Sysmon_parsed.csv"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"[!] EvtxECmd failed (exit {result.returncode}): {result.stderr[:300]}")
            return None

    if not parsed_csv.exists():
        print(f"[!] EvtxECmd ran but {parsed_csv} was not produced")
        return None

    df = pd.read_csv(parsed_csv, low_memory=False)
    eid_col = 'EventId' if 'EventId' in df.columns else ('Id' if 'Id' in df.columns else None)
    if eid_col is None:
        print(f"[!] Sysmon CSV has no recognizable EventId column (saw {list(df.columns)}).")
        return None

    filtered = df[df[eid_col] == 2]
    print(f"[+] Loaded {len(filtered)} Sysmon Event ID 2 entries from {parsed_csv}")
    return filtered

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
            
            # No hard-coded '.EXE' gate: C1 applies to any file that actually has a
            # Prefetch entry (executables). On a .txt-only corpus nothing matches, which
            # is an inherent property of the method, not an artificial extension filter.
            if fname in pf_lookup and pd.notna(si_created):
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
        # Build a set of NORMALIZED target paths from Sysmon Event 2. Previously this used
        # a substring test (`fpath in sf`) which both risked false positives and, because
        # MFT paths are '.\...'-prefixed while Sysmon paths are absolute 'C:\...', never
        # actually matched. Normalize both sides and compare for exact equality.
        sysmon_paths = set()
        for _, row in sysmon_df.iterrows():
            target = _extract_target_filename(row)
            if target:
                sysmon_paths.add(_normalize_path(target))

        for _, row in analysis_df.iterrows():
            fpath = _normalize_path(row.get('FullPath', row.get('FileName', '')))
            c2_results.append(bool(fpath) and fpath in sysmon_paths)
    else:
        c2_results = [False] * len(analysis_df)
    
    analysis_df['C2_Sysmon_SetCreationTime'] = c2_results
    
    # Combined scores
    c_cols = ['C1_Prefetch_Contradiction', 'C2_Sysmon_SetCreationTime']
    analysis_df['MethodC_Score'] = analysis_df[c_cols].sum(axis=1)
    analysis_df['MethodC_Flagged'] = analysis_df['MethodC_Score'] > 0
    # Guard against Method B having been skipped (no UsnJrnl); treat a missing column as
    # all-False rather than raising KeyError.
    if 'MethodB_Flagged' in analysis_df.columns:
        method_b = analysis_df['MethodB_Flagged']
    else:
        print("[!] MethodB_Flagged absent; treating Method B as all-False for A|B|C.")
        method_b = pd.Series(False, index=analysis_df.index)
    analysis_df['MethodABC_Flagged'] = (
        analysis_df['MethodA_Flagged'] |
        method_b |
        analysis_df['MethodC_Flagged']
    )
    
    return analysis_df

def main():
    analysis_path = DATA_ROOT / "Parsed" / "analysis_dataset.csv"
    df = pd.read_csv(analysis_path, low_memory=False)
    print("[DIAG] path-ish columns:", [c for c in df.columns if 'ath' in c.lower() or 'ame' in c.lower()])
    
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
