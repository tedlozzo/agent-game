#!/usr/bin/env python3
"""
Build benchmark_results_runs.csv: one row per run, no aggregations.
Reads from benchmarks/ (experiment dirs with game.csv, final_board.txt, output.log).
"""
import os
import re
import csv
from pathlib import Path

BENCHMARKS_DIR = Path(__file__).resolve().parent.parent / "benchmarks"
OUT_CSV = Path(__file__).resolve().parent.parent / "benchmark_results_runs.csv"


def get_initial_word(exp_dir: Path) -> str:
    """From game.csv first row with initial_word, or from board/final_board grid."""
    game_csv = exp_dir / "game.csv"
    if game_csv.exists():
        with open(game_csv) as f:
            reader = csv.DictReader(f)
            for row in reader:
                w = (row.get("initial_word") or "").strip()
                if w:
                    return w
    # Fallback: first sequence of letters from board/final
    for name in ("board.txt", "final_board.txt"):
        p = exp_dir / name
        if p.exists():
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("---") and "|" not in line:
                        letters = re.findall(r"[A-Za-z]+", line)
                        if letters and len(letters[0]) > 1:
                            return letters[0].upper()
    return ""


def get_words_list(exp_dir: Path) -> str:
    """Comma-separated list of words from final_board.txt ---WORDS--- section."""
    final = exp_dir / "final_board.txt"
    if not final.exists():
        return ""
    in_words = False
    words = []
    with open(final) as f:
        for line in f:
            line = line.strip()
            if line == "---WORDS---":
                in_words = True
                continue
            if in_words:
                if not line or line.startswith("---"):
                    break
                # "WORD (player) len (def)" -> WORD
                m = re.match(r"^([A-Za-z]+)\s", line)
                if m:
                    words.append(m.group(1).upper())
    return ",".join(words)


def get_score(final_board_path: Path) -> str:
    """Last player score from final_board.txt (e.g. 'claude|...|180: 33' -> 33)."""
    if not final_board_path.exists():
        return ""
    with open(final_board_path) as f:
        for line in f:
            m = re.search(r":\s*(\d+)\s*$", line.strip())
            if m:
                last_score = m.group(1)
    return last_score or ""


def count_errors(output_log_path: Path) -> dict:
    """Count timeout, parse, and invalid (wrong path/output) errors from output.log."""
    out = {"timeout": 0, "parse": 0, "invalid": 0}
    if not output_log_path.exists():
        return out
    with open(output_log_path) as f:
        content = f.read()
    out["timeout"] = len(re.findall(r"timed out after", content))
    out["parse"] = len(re.findall(r"Could not parse", content))
    out["invalid"] = len(re.findall(r"❌ INVALID MOVE:", content))
    return out


def count_rounds(output_log_path: Path) -> int:
    """Number of ROUND N START in output.log."""
    if not output_log_path.exists():
        return 0
    with open(output_log_path) as f:
        content = f.read()
    return len(re.findall(r"=== ROUND \d+ START ===", content))


def get_status(output_log_path: Path) -> str:
    """completed | turn_limit | consecutive_failures | interrupted."""
    if not output_log_path.exists():
        return "unknown"
    with open(output_log_path) as f:
        content = f.read()
    if "GAME OVER" in content or "Board is full" in content:
        return "completed"
    if "Max rounds reached" in content:
        return "turn_limit"
    if "consecutive failures" in content:
        return "consecutive_failures"
    return "interrupted"


def get_mode(output_log_path: Path) -> str:
    """ask | agent from [ask mode] or [agent mode] in output.log."""
    if not output_log_path.exists():
        return "ask"
    with open(output_log_path) as f:
        for line in f:
            if "[agent mode]" in line:
                return "agent"
            if "[ask mode]" in line:
                return "ask"
    return "ask"


def iter_experiments():
    """Yield (benchmark_id, tool, exp_name, exp_dir) for each experiment."""
    if not BENCHMARKS_DIR.exists():
        return
    for bm_dir in sorted(BENCHMARKS_DIR.iterdir()):
        if not bm_dir.is_dir() or not bm_dir.name.startswith("benchmark_"):
            continue
        bm_id = bm_dir.name
        for tool_dir in sorted(bm_dir.iterdir()):
            if not tool_dir.is_dir():
                continue
            tool = tool_dir.name
            for exp_dir in sorted(tool_dir.iterdir()):
                if not exp_dir.is_dir():
                    continue
                if (exp_dir / "game.csv").exists() or (exp_dir / "final_board.txt").exists():
                    yield bm_id, tool, exp_dir.name, exp_dir


def parse_exp_name(name: str) -> dict:
    """Parse experiment dir name into model, field_size, timeout, iteration, turn_limit."""
    # e.g. claude_claude-opus-4-6_3x4_180s_i1_tunlimited  or  ..._t10_agent
    m = re.match(r"^(claude|cursor)_(.+?)_(\d+x\d+)_(\d+)s_i(\d+)_t(.+)$", name)
    if not m:
        return {}
    tool, model, field_size, timeout, iteration, turn_limit = m.groups()
    if turn_limit.endswith("_agent"):
        turn_limit = turn_limit[:-6]  # e.g. unlimited_agent -> unlimited
    return {
        "tool": tool,
        "model": model,
        "field_size": field_size,
        "timeout": timeout,
        "iteration": int(iteration),
        "turn_limit": turn_limit,
    }


def main():
    rows = []
    for bm_id, tool, exp_name, exp_dir in iter_experiments():
        parsed = parse_exp_name(exp_name)
        if not parsed:
            continue
        output_log = exp_dir / "output.log"
        final_board = exp_dir / "final_board.txt"

        score = get_score(final_board)
        word = get_initial_word(exp_dir)
        words = get_words_list(exp_dir)
        errs = count_errors(output_log)
        rounds = count_rounds(output_log)
        status = get_status(output_log)
        mode = get_mode(output_log)
        # Composer models run as agent; output.log may say "ask" for Cursor UI
        if "composer" in parsed["model"].lower():
            mode = "agent"

        # 10-turn: keep turn_limit as-is (e.g. "10" or "unlimited")
        turn_limit = parsed["turn_limit"]

        rows.append({
            "Model": parsed["model"],
            "Tool": parsed["tool"],
            "Mode": mode,
            "Field size": parsed["field_size"],
            "Turn limit": turn_limit,
            "Iteration": parsed["iteration"],
            "Score": score,
            "Rounds": rounds,
            "Invalid errors": errs["invalid"],
            "Timeout errors": errs["timeout"],
            "Parse errors": errs["parse"],
            "Word": word,
            "Words": words,
            "Status": status,
            "Benchmark": bm_id,
        })

    fieldnames = [
        "Model", "Tool", "Mode", "Field size", "Turn limit", "Iteration",
        "Score", "Rounds", "Invalid errors", "Timeout errors", "Parse errors",
        "Word", "Words", "Status", "Benchmark",
    ]
    with open(OUT_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(sorted(rows, key=lambda r: (r["Benchmark"], r["Tool"], r["Model"], r["Field size"], r["Iteration"])))

    print(f"Wrote {len(rows)} runs to {OUT_CSV}")


if __name__ == "__main__":
    main()
