# ============================================================
# extract_baseline_labels.py   (evaluation-population redesign, optional)
# ============================================================
# Higher-fidelity negative labelling for build_eval_population.py.
#
# Directory-scope labelling only sees files under C:\Research\Data\Baseline.
# Several baselines write elsewhere (L2/L3 installers drop into Program Files,
# L1 touches WinSxS/SoftwareDistribution, etc.). This script recovers those by
# DIFFING each operation's pre/post MFT captures (already produced by
# 02_Legitimate_Operations.ps1) and recording every record that was created or
# modified during the operation window.
#
# A record is attributed to category L<n> if it is new in post-L<n> relative to
# pre-L<n>, or its $SI Created/Modified changed between the two captures.
#
# INPUT  : C:\Research\Data\Artifacts\{pre,post}-L<n>-<os>_<ts>\MFT_parsed.csv
# OUTPUT : eval-pop_redux\baseline_labels.csv
#          columns: FullPath, FileName, BaselineCategory, OSTag, ChangeType
#
# USAGE  : python extract_baseline_labels.py
#          python extract_baseline_labels.py --keep-system   (don't drop OS churn)
# ============================================================

import argparse
import re
import pandas as pd
from pathlib import Path

print("============== extract_baseline_labels.py ==============\n")

DATA_ROOT = Path(r"C:\Research\Data")
ARTIFACTS = DATA_ROOT / "Artifacts"

# pre-L4-w10_20260626_031521  /  post-L12-w11_...
TAG_RE = re.compile(r"^(?P<phase>pre|post)-(?P<code>L\d{1,2})-(?P<os>[^_]+)_\d{8}_\d{6}$",
                    re.IGNORECASE)

SYSTEM_NOISE = (r"\windows\\", r"\$extend", r"\system volume information",
                r"pagefile.sys", r"hiberfil.sys", r"swapfile.sys",
                r"\programdata\microsoft\windows defender")


def find_col(df, candidates):
    norm = {str(c).strip().lower().replace(" ", "").replace("_", ""): c for c in df.columns}
    for cand in candidates:
        k = cand.strip().lower().replace(" ", "").replace("_", "")
        if k in norm:
            return norm[k]
    return None


def load_capture(capture_dir):
    csv = capture_dir / "MFT_parsed.csv"
    if not csv.exists():
        return None
    df = pd.read_csv(csv, low_memory=False)
    # active records only
    inuse = find_col(df, ["InUse"])
    if inuse:
        df = df[df[inuse].astype(str).str.strip().str.lower().isin(["true", "1"])].copy()
    parent = find_col(df, ["ParentPath"])
    fname = find_col(df, ["FileName"])
    entry = find_col(df, ["EntryNumber"])
    seq = find_col(df, ["SequenceNumber"])
    created = find_col(df, ["Created0x10"])
    modified = find_col(df, ["LastModified0x10"])
    if fname is None or parent is None:
        return None
    df["_full"] = (df[parent].fillna("").astype(str).str.rstrip("\\")
                   + "\\" + df[fname].fillna("").astype(str)).str.lower()
    # stable identity: MFT record number if available, else full path
    if entry is not None:
        df["_key"] = df[entry].astype(str) + "-" + (df[seq].astype(str) if seq else "")
    else:
        df["_key"] = df["_full"]
    df["_sig"] = (df[created].astype(str) if created else "") + "|" + \
                 (df[modified].astype(str) if modified else "")
    df["_fname"] = df[fname]
    return df[["_key", "_full", "_fname", "_sig"]]


def latest(phase, code, os_tag):
    """Most recent capture dir for a phase/code/os."""
    best = None
    for d in ARTIFACTS.iterdir():
        if not d.is_dir():
            continue
        m = TAG_RE.match(d.name)
        if not m:
            continue
        if (m.group("phase").lower() == phase and m.group("code").upper() == code
                and m.group("os").lower() == os_tag.lower()):
            if best is None or d.name > best.name:
                best = d
    return best


def discover_ops():
    """Return sorted set of (code, os) pairs that have any capture."""
    pairs = set()
    if not ARTIFACTS.exists():
        return pairs
    for d in ARTIFACTS.iterdir():
        m = TAG_RE.match(d.name) if d.is_dir() else None
        if m:
            pairs.add((m.group("code").upper(), m.group("os").lower()))
    return sorted(pairs)


def is_system_noise(full_lower):
    return any(re.search(p, full_lower) for p in SYSTEM_NOISE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-system", action="store_true",
                    help="Do not drop OS churn (Windows\\, pagefile, Defender, ...).")
    ap.add_argument("--out", default=str(Path(__file__).parent / "baseline_labels.csv"))
    args = ap.parse_args()

    ops = discover_ops()
    if not ops:
        raise SystemExit(f"[!] No pre/post-L*-<os> captures under {ARTIFACTS}. "
                         f"Run 02_Legitimate_Operations.ps1 with capture enabled.")

    rows = []
    for code, os_tag in ops:
        pre_dir, post_dir = latest("pre", code, os_tag), latest("post", code, os_tag)
        if pre_dir is None or post_dir is None:
            print(f"[skip] {code}-{os_tag}: missing pre or post capture")
            continue
        pre, post = load_capture(pre_dir), load_capture(post_dir)
        if pre is None or post is None:
            print(f"[skip] {code}-{os_tag}: MFT_parsed.csv missing/unreadable")
            continue

        pre_sig = dict(zip(pre["_key"], pre["_sig"]))
        for _, r in post.iterrows():
            full = r["_full"]
            if not full or full.endswith("\\"):
                continue
            if not args.keep_system and is_system_noise(full):
                continue
            prev = pre_sig.get(r["_key"], None)
            if prev is None:
                change = "new"
            elif prev != r["_sig"]:
                change = "modified"
            else:
                continue
            rows.append({"FullPath": r["_full"], "FileName": r["_fname"],
                         "BaselineCategory": code, "OSTag": os_tag, "ChangeType": change})
        print(f"[+] {code}-{os_tag}: pre={pre_dir.name}  post={post_dir.name}  "
              f"touched={sum(1 for x in rows if x['BaselineCategory']==code and x['OSTag']==os_tag)}")

    if not rows:
        raise SystemExit("[!] No created/modified files found across operation diffs.")

    out = pd.DataFrame(rows)
    # one label per (path, os); first category wins if a file shows up in two ops
    out = out.drop_duplicates(subset=["FullPath", "OSTag"], keep="first")
    out.to_csv(args.out, index=False)
    print(f"\n[+] Wrote {len(out):,} baseline labels to {args.out}")
    print(out.groupby(["OSTag", "BaselineCategory"]).size().to_string())


if __name__ == "__main__":
    main()
