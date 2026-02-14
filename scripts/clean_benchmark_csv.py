#!/usr/bin/env python3
"""
Clean benchmark_results_runs.csv by removing broken/incomplete runs.

Discard rules:
1. Status = "interrupted" (externally stopped, incomplete data)
2. Parse errors >= 100 (sonnet-4-5 cursor 128 parse errors — markdown wrapping)
3. Score = 0 (test/broken runs, no valid moves at all)
4. consecutive_failures caused by network/timeout infrastructure issues:
   - gpt-5-3-codex-xhigh: all runs (5-8 timeouts per run, model integration broken)
   - Any consecutive_failures with timeout_errors >= 50% of rounds played
5. Runs with API/connection/rate-limit errors in output.log:
   - "unavailable", "ENOTFOUND", "stalled", "resource_exhausted"
   These are infrastructure issues, not model performance data.

Keep:
- "completed" and "turn_limit" runs without infrastructure errors
- consecutive_failures caused by genuine model struggles (high invalid errors,
  low/zero timeouts) — these represent real model performance data

Output: benchmark_results_clean.csv
"""

import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INPUT = ROOT / "benchmark_results_runs.csv"
OUTPUT = ROOT / "benchmark_results_clean.csv"
BENCHMARKS_DIR = ROOT / "benchmarks"

# Patterns indicating API/connection/rate-limit infrastructure errors in output.log
API_ERROR_PATTERNS = [
    re.compile(r"\[unavailable\]", re.IGNORECASE),
    re.compile(r"ENOTFOUND", re.IGNORECASE),
    re.compile(r"Connection stalled", re.IGNORECASE),
    re.compile(r"\[resource_exhausted\]", re.IGNORECASE),
    re.compile(r"getaddrinfo", re.IGNORECASE),
]


def find_output_log(row):
    """Find the output.log for a given CSV row."""
    benchmark = row.get("Benchmark", "")
    tool = row.get("Tool", "")
    if not benchmark or not tool:
        return None
    tool_dir = BENCHMARKS_DIR / benchmark / tool
    if not tool_dir.exists():
        return None
    # Match experiment dir by model, field, iteration
    model = row.get("Model", "")
    field = row.get("Field size", "")
    iteration = row.get("Iteration", "")
    for exp_dir in tool_dir.iterdir():
        if not exp_dir.is_dir():
            continue
        name = exp_dir.name
        if model.replace(".", "-") in name and field in name and f"_i{iteration}_" in name:
            log = exp_dir / "output.log"
            if log.exists():
                return log
    return None


def has_api_errors(output_log_path):
    """Check if output.log contains API/connection/rate-limit errors."""
    if not output_log_path or not output_log_path.exists():
        return False, ""
    with open(output_log_path) as f:
        content = f.read()
    for pattern in API_ERROR_PATTERNS:
        matches = pattern.findall(content)
        if matches:
            return True, pattern.pattern
    return False, ""


def main():
    with open(INPUT, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    kept = []
    discarded_reasons = {}

    for i, row in enumerate(rows, start=2):  # row 2 is first data row
        status = row.get("Status", "").strip()
        score = int(row.get("Score", "0"))
        parse_errors = int(row.get("Parse errors", "0"))
        timeout_errors = int(row.get("Timeout errors", "0"))
        rounds = int(row.get("Rounds", "0"))
        model = row.get("Model", "")

        reason = None

        # Rule 1: interrupted
        if status == "interrupted":
            reason = "interrupted (incomplete data)"

        # Rule 2: high parse errors (markdown wrapping / technical issue)
        elif parse_errors >= 100:
            reason = f"broken run ({parse_errors} parse errors)"

        # Rule 3: Score = 0
        elif score == 0:
            reason = "Score=0 (no valid moves)"

        # Rule 4: consecutive_failures from network/timeout issues
        elif status == "consecutive_failures":
            # gpt-5-3-codex-xhigh: entire model broken (all runs timeout-heavy)
            if model == "gpt-5-3-codex-xhigh":
                reason = f"timeout infrastructure failure ({model}, {timeout_errors} timeouts)"
            # Timeout-dominated failures: timeouts >= 50% of rounds
            elif rounds > 0 and timeout_errors / rounds >= 0.5:
                reason = f"timeout-dominated failure ({timeout_errors}/{rounds} rounds timed out)"
            # Otherwise: genuine model struggle (keep it)

        # Rule 5: API/connection/rate-limit errors in output.log
        if reason is None:
            log_path = find_output_log(row)
            has_errors, pattern = has_api_errors(log_path)
            if has_errors:
                reason = f"API/connection error ({pattern})"

        if reason:
            discarded_reasons.setdefault(reason, []).append(i)
        else:
            kept.append(row)

    # Write cleaned CSV
    with open(OUTPUT, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(kept)

    print(f"Input:     {len(rows)} runs")
    print(f"Kept:      {len(kept)} runs")
    print(f"Discarded: {len(rows) - len(kept)} runs")
    print()
    print("Discard breakdown:")
    for reason, row_nums in sorted(discarded_reasons.items()):
        print(f"  {reason}: {len(row_nums)} runs (rows {', '.join(map(str, row_nums))})")

    print(f"\nWrote: {OUTPUT}")

    # Summary stats for kept runs
    print("\n--- Kept runs summary ---")
    by_model = {}
    for row in kept:
        key = (row["Model"], row["Tool"], row["Mode"], row["Field size"])
        by_model.setdefault(key, []).append(row)

    for key in sorted(by_model.keys()):
        runs = by_model[key]
        model, tool, mode, field = key
        scores = [int(r["Score"]) for r in runs]
        statuses = [r["Status"] for r in runs]
        completed = sum(1 for s in statuses if s == "completed")
        turn_limit = sum(1 for s in statuses if s == "turn_limit")
        avg_score = sum(scores) / len(scores) if scores else 0
        inv = sum(int(r["Invalid errors"]) for r in runs)
        to = sum(int(r["Timeout errors"]) for r in runs)
        pe = sum(int(r["Parse errors"]) for r in runs)
        print(f"  {model:40s} {tool:8s} {mode:6s} {field:4s}  "
              f"runs={len(runs):2d}  completed={completed:2d}  turn_limit={turn_limit:2d}  "
              f"avg_score={avg_score:5.1f}  inv={inv:2d}  timeout={to:2d}  parse={pe:2d}")


if __name__ == "__main__":
    main()
