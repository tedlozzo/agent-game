#!/bin/bash

# Benchmark Results Analyzer
# Parses experiment results and generates comparative metrics
#
# Usage: ./analyze-results.sh <benchmark_results_dir>

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <benchmark_results_dir>"
    echo ""
    echo "Example:"
    echo "  ./analyze-results.sh benchmarks/benchmark_20260209_120000"
    exit 1
fi

RESULTS_DIR="$1"

if [ ! -d "$RESULTS_DIR" ]; then
    echo "Error: Results directory not found: $RESULTS_DIR"
    exit 1
fi

echo "=== BALDA Benchmark Analysis ==="
echo "Results directory: $RESULTS_DIR"
echo ""

# Output files
METRICS_CSV="$RESULTS_DIR/metrics.csv"
SUMMARY_TXT="$RESULTS_DIR/analysis_summary.txt"
COMPARISON_CSV="$RESULTS_DIR/comparison.csv"

# Initialize metrics CSV
echo "experiment,tool,model,board_size,timeout,iteration,turn_limit,total_score,moves_made,errors,error_rate,avg_word_length,execution_time,game_completed" > "$METRICS_CSV"

# Function to parse a single experiment
parse_experiment() {
    local exp_dir="$1"
    local exp_name=$(basename "$exp_dir")

    # Skip if not a valid experiment directory
    [ ! -d "$exp_dir" ] && return
    [ ! -f "$exp_dir/game.csv" ] && return

    # Parse experiment name: tool_model_size_timeout_iteration_turnlimit
    # Example: claude_opus-4-6_4x4_180s_i1_t20
    if [[ $exp_name =~ ^([^_]+)_(.+)_([0-9]+x[0-9]+)_([0-9]+)s_i([0-9]+)_t(.+)$ ]]; then
        local tool="${BASH_REMATCH[1]}"
        local model="${BASH_REMATCH[2]}"
        local board_size="${BASH_REMATCH[3]}"
        local timeout="${BASH_REMATCH[4]}"
        local iteration="${BASH_REMATCH[5]}"
        local turn_limit="${BASH_REMATCH[6]}"
    else
        echo "Warning: Could not parse experiment name: $exp_name"
        return
    fi

    local csv_file="$exp_dir/game.csv"
    local board_file="$exp_dir/final_board.txt"

    # Extract metrics from CSV
    local total_score=0
    local moves_made=0
    local errors=0
    local word_lengths=()
    local execution_time=0
    local game_completed=0

    # Parse CSV (skip header)
    local in_data=0
    while IFS=',' read -r run_id timestamp model_col field_size initial_word event details score error_col; do
        # Skip header
        if [ "$event" = "event" ]; then
            in_data=1
            continue
        fi

        [ $in_data -eq 0 ] && continue

        # Remove quotes from fields
        event=$(echo "$event" | tr -d '"')
        score=$(echo "$score" | tr -d '"' | tr -d ' ')
        error_col=$(echo "$error_col" | tr -d '"')

        case "$event" in
            MOVE_OK)
                moves_made=$((moves_made + 1))
                if [ -n "$score" ] && [ "$score" != "" ]; then
                    total_score=$((total_score + score))
                    word_lengths+=("$score")
                fi
                ;;
            MOVE_FAIL)
                errors=$((errors + 1))
                ;;
            GAME_OVER)
                game_completed=1
                ;;
            GAME_END)
                # Extract duration
                if [[ $details =~ ([0-9]+)s ]]; then
                    execution_time="${BASH_REMATCH[1]}"
                fi
                ;;
        esac
    done < "$csv_file"

    # Calculate error rate
    local total_attempts=$((moves_made + errors))
    local error_rate=0
    if [ $total_attempts -gt 0 ]; then
        error_rate=$(echo "scale=2; $errors * 100 / $total_attempts" | bc)
    fi

    # Calculate average word length
    local avg_word_length=0
    if [ $moves_made -gt 0 ]; then
        local sum=0
        for len in "${word_lengths[@]}"; do
            sum=$((sum + len))
        done
        avg_word_length=$(echo "scale=2; $sum / $moves_made" | bc)
    fi

    # Write to metrics CSV
    echo "$exp_name,$tool,$model,$board_size,$timeout,$iteration,$turn_limit,$total_score,$moves_made,$errors,$error_rate,$avg_word_length,$execution_time,$game_completed" >> "$METRICS_CSV"
}

# Parse all experiments
echo "Parsing experiments..."
for tool_dir in "$RESULTS_DIR"/*/; do
    [ ! -d "$tool_dir" ] && continue

    for exp_dir in "$tool_dir"/*/; do
        [ ! -d "$exp_dir" ] && continue
        parse_experiment "$exp_dir"
    done
done

echo "Metrics extracted to: $METRICS_CSV"
echo ""

# Generate summary statistics
echo "Generating summary statistics..."

{
    echo "=== BENCHMARK ANALYSIS SUMMARY ==="
    echo "Generated: $(date)"
    echo ""
    echo "=== OVERALL STATISTICS BY MODEL ==="
    echo ""

    # Group by tool and model, calculate aggregates
    awk -F',' '
    NR==1 { next }  # Skip header
    {
        key = $2 "|" $3  # tool|model
        score[key] += $8
        moves[key] += $9
        errors[key] += $10
        count[key] += 1
        time[key] += $13
        completed[key] += $14

        # Store for later
        tool_model[key] = $2 " - " $3
    }
    END {
        printf "%-40s %8s %8s %8s %10s %10s %8s\n", "Tool - Model", "AvgScore", "AvgMoves", "AvgError", "AvgTime(s)", "Completed", "Runs"
        printf "%-40s %8s %8s %8s %10s %10s %8s\n", "----------------------------------------", "--------", "--------", "--------", "----------", "----------", "--------"

        for (key in count) {
            avg_score = score[key] / count[key]
            avg_moves = moves[key] / count[key]
            avg_errors = errors[key] / count[key]
            avg_time = time[key] / count[key]
            total_completed = completed[key]
            total_runs = count[key]

            printf "%-40s %8.1f %8.1f %8.1f %10.1f %10d %8d\n",
                tool_model[key], avg_score, avg_moves, avg_errors, avg_time, total_completed, total_runs
        }
    }
    ' "$METRICS_CSV"

    echo ""
    echo "=== PERFORMANCE BY BOARD SIZE ==="
    echo ""

    awk -F',' '
    NR==1 { next }
    {
        key = $4  # board_size
        score[key] += $8
        moves[key] += $9
        errors[key] += $10
        count[key] += 1
        time[key] += $13
        completed[key] += $14
    }
    END {
        printf "%-12s %8s %8s %8s %10s %10s\n", "Board Size", "AvgScore", "AvgMoves", "AvgError", "AvgTime(s)", "Completed"
        printf "%-12s %8s %8s %8s %10s %10s\n", "------------", "--------", "--------", "--------", "----------", "----------"

        for (key in count) {
            avg_score = score[key] / count[key]
            avg_moves = moves[key] / count[key]
            avg_errors = errors[key] / count[key]
            avg_time = time[key] / count[key]
            total_completed = completed[key]

            printf "%-12s %8.1f %8.1f %8.1f %10.1f %10d\n",
                key, avg_score, avg_moves, avg_errors, avg_time, total_completed
        }
    }
    ' "$METRICS_CSV"

    echo ""
    echo "=== PERFORMANCE BY TIMEOUT ==="
    echo ""

    awk -F',' '
    NR==1 { next }
    {
        key = $5  # timeout
        score[key] += $8
        moves[key] += $9
        errors[key] += $10
        count[key] += 1
        time[key] += $13
        completed[key] += $14
    }
    END {
        printf "%-12s %8s %8s %8s %10s %10s\n", "Timeout(s)", "AvgScore", "AvgMoves", "AvgError", "AvgTime(s)", "Completed"
        printf "%-12s %8s %8s %8s %10s %10s\n", "------------", "--------", "--------", "--------", "----------", "----------"

        for (key in count) {
            avg_score = score[key] / count[key]
            avg_moves = moves[key] / count[key]
            avg_errors = errors[key] / count[key]
            avg_time = time[key] / count[key]
            total_completed = completed[key]

            printf "%-12s %8.1f %8.1f %8.1f %10.1f %10d\n",
                key, avg_score, avg_moves, avg_errors, avg_time, total_completed
        }
    }
    ' "$METRICS_CSV"

    echo ""
    echo "=== ERROR RATE ANALYSIS ==="
    echo ""

    awk -F',' '
    NR==1 { next }
    {
        key = $2 "|" $3  # tool|model
        error_rate_sum[key] += $11
        count[key] += 1
        tool_model[key] = $2 " - " $3
    }
    END {
        printf "%-40s %12s\n", "Tool - Model", "AvgError%"
        printf "%-40s %12s\n", "----------------------------------------", "------------"

        for (key in count) {
            avg_error_rate = error_rate_sum[key] / count[key]
            printf "%-40s %11.2f%%\n", tool_model[key], avg_error_rate
        }
    }
    ' "$METRICS_CSV"

    echo ""
    echo "=== WORD LENGTH ANALYSIS ==="
    echo ""

    awk -F',' '
    NR==1 { next }
    {
        key = $2 "|" $3  # tool|model
        word_len_sum[key] += $12
        count[key] += 1
        tool_model[key] = $2 " - " $3
    }
    END {
        printf "%-40s %15s\n", "Tool - Model", "AvgWordLength"
        printf "%-40s %15s\n", "----------------------------------------", "---------------"

        for (key in count) {
            avg_word_len = word_len_sum[key] / count[key]
            printf "%-40s %14.2f\n", tool_model[key], avg_word_len
        }
    }
    ' "$METRICS_CSV"

} > "$SUMMARY_TXT"

cat "$SUMMARY_TXT"
echo ""
echo "Summary saved to: $SUMMARY_TXT"

# Generate comparison CSV (averages by model and config)
echo "Generating comparison table..."

{
    echo "tool,model,board_size,timeout,avg_score,std_dev_score,avg_moves,avg_errors,avg_error_rate,avg_word_length,avg_time,completed_count,total_runs"

    awk -F',' '
    NR==1 { next }
    {
        key = $2 "|" $3 "|" $4 "|" $5  # tool|model|board_size|timeout

        # Accumulate values
        scores[key] = scores[key] " " $8
        n[key] += 1
        sum_score[key] += $8
        sum_moves[key] += $9
        sum_errors[key] += $10
        sum_error_rate[key] += $11
        sum_word_len[key] += $12
        sum_time[key] += $13
        sum_completed[key] += $14

        # Store metadata
        meta_tool[key] = $2
        meta_model[key] = $3
        meta_size[key] = $4
        meta_timeout[key] = $5
    }
    END {
        for (key in n) {
            count = n[key]
            avg_score = sum_score[key] / count
            avg_moves = sum_moves[key] / count
            avg_errors = sum_errors[key] / count
            avg_error_rate = sum_error_rate[key] / count
            avg_word_len = sum_word_len[key] / count
            avg_time = sum_time[key] / count
            completed = sum_completed[key]

            # Calculate standard deviation for score
            split(scores[key], arr, " ")
            sum_sq_diff = 0
            for (i in arr) {
                if (arr[i] != "") {
                    diff = arr[i] - avg_score
                    sum_sq_diff += diff * diff
                }
            }
            std_dev = sqrt(sum_sq_diff / count)

            printf "%s,%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d\n",
                meta_tool[key], meta_model[key], meta_size[key], meta_timeout[key],
                avg_score, std_dev, avg_moves, avg_errors, avg_error_rate,
                avg_word_len, avg_time, completed, count
        }
    }
    ' "$METRICS_CSV"
} > "$COMPARISON_CSV"

echo "Comparison table saved to: $COMPARISON_CSV"
echo ""
echo "=== Analysis Complete ==="
echo ""
echo "Generated files:"
echo "  - Detailed metrics: $METRICS_CSV"
echo "  - Summary statistics: $SUMMARY_TXT"
echo "  - Comparison table: $COMPARISON_CSV"
