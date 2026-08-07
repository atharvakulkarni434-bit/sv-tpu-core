#!/usr/bin/env python3
"""
cov_check.py — Post-regression coverage gate for sv-tpu-core.

Parses IMC's report_metrics output (a JSON-fragment .report file inside
<out_dir>/report_data/) and checks every covergroup (cg_), coverpoint (cp_),
and cross (cx_) entry against COV_THRESHOLD. Exits nonzero if any entry
falls below threshold, so this is meant to be run as a CI/regression gate.

Format note: the .report file is NOT valid standalone JSON - it's a
JS-embedded fragment (leading byte-count header, comma-first continuation
lines) - so this uses regex extraction on "title"/"All Cov" key pairs
rather than a JSON parser. Confirmed against real IMC 26.05-a010 output
on 2026-08-01; sample lines look like:
    {"title":"mmu_coverage::cg_dim", ..., "All Cov":"1 / 3 (33.33%)", ...}
    {"title":"cp_dim", ..., "All Cov":"1 / 3 (33.33%)", ...}

Also handles IMC writing a new timestamped .report file on every
invocation (never overwriting) by selecting the most recent by mtime,
rather than relying on glob's filesystem-dependent ordering.

Usage:
    python3 cov_check.py <report_data_dir> <threshold_pct> <merged_ucd_path>
"""
import re
import sys
import glob
import os


def main():
    # Standard CLI contract, 3 positional arguments expected
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <report_data_dir> <threshold_pct> <merged_ucd_path>")
        sys.exit(2)

    report_data_dir, threshold_str, merged_ucd_path = sys.argv[1:4]
    threshold = float(threshold_str)

    # globs foe any .report file in the directory, bails with exit 1 if nothing exists
    files = glob.glob(f"{report_data_dir}/*.report")
    if not files:
        print(f"No .report file found under {report_data_dir}/ - cov-report may have failed.")
        sys.exit(1)

    # Even if a report exists, we need to choose the most RECENT one
    # IMC writes a NEW timestamped report file on every single invocation, so after N reruns, there are N files sitting in the directory
    # So, we explicitly pick the file with the latest modification time
    if len(files) > 1:
        print(f"NOTE: {len(files)} .report files found under {report_data_dir}/ "
              f"(one per past report-metrics run) - using the most recent by "
              f"mtime. Consider `rm -f {report_data_dir}/*.report` before a "
              f"clean regression run to avoid this pileup.")
    newest_file = max(files, key=os.path.getmtime)

    text = open(newest_file).read()

    # Extract every (title, percentage) pair. Non-greedy .*? so each title
    # binds to its own immediately-following "All Cov" field.
    pairs = re.findall(r'"title":"([^"]+)".*?"All Cov":"[^(]*\(([\d.]+)%\)', text)

    seen = {}
    # here, we strip any scope prefix: like mmu_coverage::cg_dim just becomes cg_dim
    # Then, only keep anything with one of three prefixes that matter: group, point, or cross
    for name, pct in pairs:
        short = name.split("::")[-1]
        if short.startswith(("cg_", "cp_", "cx_")):
            seen[short] = float(pct)

    # if no regex matches, then a sign that report format changed upstream, prints error accordingly
    if not seen:
        print(f"No cg_/cp_/cx_ entries found in {newest_file} - check the report format hasn't changed.")
        sys.exit(1)

    # Actual pass/fail comparison
    below = {k: v for k, v in seen.items() if v < threshold}

    # Dict comprehension collect everything under the threshold, if anything is below, prints formatted Fail block
    # Points user to exact imc, with the command to go inspect missing bins
    # If all above 90, then print PASS and exits 0 implicitly.
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
