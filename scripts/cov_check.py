#!/usr/bin/env python3
"""
Parses IMC's report_metrics output (a JSON-fragment .report file inside
<out_dir>/report_data/) and checks every covergroup (cg_), coverpoint (cp_),
and cross (cx_) entry against COV_THRESHOLD.

The .report format is NOT valid standalone JSON - it's a JS-embedded
fragment (leading byte-count header, comma-first continuation lines) - so
this uses regex extraction on the "title"/"All Cov" key pairs rather than
a JSON parser. Confirmed against real IMC 26.05-a010 output on 2026-08-01:
lines look like:
    {"title":"mmu_coverage::cg_dim", ..., "All Cov":"1 / 3 (33.33%)", ...}
    {"title":"cp_dim", ..., "All Cov":"1 / 3 (33.33%)", ...}

Usage:
    python3 cov_check.py <report_data_dir> <threshold_pct> <merged_ucd_path>
"""
import re
import sys
import glob


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <report_data_dir> <threshold_pct> <merged_ucd_path>")
        sys.exit(2)

    report_data_dir, threshold_str, merged_ucd_path = sys.argv[1:4]
    threshold = float(threshold_str)

    files = glob.glob(f"{report_data_dir}/*.report")
    if not files:
        print(f"No .report file found under {report_data_dir}/ - cov-report may have failed.")
        sys.exit(1)

    text = open(files[0]).read()

    # Extract every (title, percentage) pair. Non-greedy .*? so each title
    # binds to its own immediately-following "All Cov" field.
    pairs = re.findall(r'"title":"([^"]+)".*?"All Cov":"[^(]*\(([\d.]+)%\)', text)

    seen = {}
    for name, pct in pairs:
        short = name.split("::")[-1]
        if short.startswith(("cg_", "cp_", "cx_")):
            seen[short] = float(pct)

    if not seen:
        print(f"No cg_/cp_/cx_ entries found in {files[0]} - check the report format hasn't changed.")
        sys.exit(1)

    below = {k: v for k, v in seen.items() if v < threshold}

    print("############################################################")
    if below:
        print(f"###   COVERAGE CHECK: FAIL - below {threshold:g}% threshold:")
        for k, v in sorted(below.items()):
            print(f"###     - {k}: {v:g}%")
        print("###")
        print("###   These need either directed tests targeting the specific")
        print(f"###   missing bins (see: imc -gui -load {merged_ucd_path})")
        print("###   or an explicit, reviewed waiver if unreachable.")
        print("############################################################")
        sys.exit(1)
    else:
        print(f"###   COVERAGE CHECK: PASS - all groups >= {threshold:g}%")
        print("############################################################")


if __name__ == "__main__":
    main()