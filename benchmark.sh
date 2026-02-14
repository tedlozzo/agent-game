#!/bin/bash

# BALDA Benchmark Runner
# Runs parallel tests across different models and tools with configurable parameters
#
# Usage: ./benchmark.sh [config_file]
#   config_file: Path to benchmark configuration (default: benchmark-config.sh)

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-$DIR/benchmark-config.sh}"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file '$CONFIG_FILE' not found"
    exit 1
fi

source "$CONFIG_FILE"

# Validate models before starting
echo "=== Validating Models ==="
if [ -f "$DIR/validate-models.sh" ]; then
    if ! "$DIR/validate-models.sh" "$CONFIG_FILE"; then
        echo ""
        echo "Model validation failed. Please fix errors before running benchmark."
        echo "You can skip validation with: SKIP_VALIDATION=1 ./benchmark.sh"
        [ "${SKIP_VALIDATION:-0}" = "1" ] || exit 1
    fi
else
    echo "Warning: validate-models.sh not found, skipping validation"
fi
echo ""

# Create benchmark results directory
BENCHMARK_ID="benchmark_$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="$DIR/benchmarks/$BENCHMARK_ID"
mkdir -p "$RESULTS_DIR"

echo "=== BALDA BENCHMARK RUNNER ==="
echo "Benchmark ID: $BENCHMARK_ID"
echo "Results directory: $RESULTS_DIR"
echo ""

# Copy config for reference
cp "$CONFIG_FILE" "$RESULTS_DIR/config.sh"

# Summary file
SUMMARY_FILE="$RESULTS_DIR/summary.txt"
{
    echo "BALDA Benchmark Summary"
    echo "Started: $(date)"
    echo "Benchmark ID: $BENCHMARK_ID"
    echo ""
    echo "Configuration:"
    echo "  Board Sizes: ${BOARD_SIZES[*]}"
    echo "  Timeouts: ${TIMEOUTS[*]}"
    echo "  Iterations: $ITERATIONS"
    echo "  Turn Limits: ${TURN_LIMITS[*]}"
    echo ""
    echo "Models:"
    for tool in "${TOOLS[@]}"; do
        eval "models=(\"\${${tool}_MODELS[@]}\")"
        echo "  $tool: ${models[*]}"
    done
    echo ""
} > "$SUMMARY_FILE"

# Function to generate experiment name
gen_experiment_name() {
    local tool="$1"
    local model="$2"
    local board_size="$3"
    local timeout="$4"
    local iteration="$5"
    local turn_limit="$6"

    # Sanitize model name (remove special chars)
    local model_safe=$(echo "$model" | tr '.' '-' | tr '/' '-')

    echo "${tool}_${model_safe}_${board_size}_${timeout}s_i${iteration}_t${turn_limit}"
}

# Function to create board file for experiment
create_experiment_board() {
    local template_file="$1"
    local experiment_name="$2"
    local output_file="$3"
    local tool="$4"
    local model="$5"
    local timeout="$6"

    # Copy template
    cp "$template_file" "$output_file"

    # Update PLAYERS section with model info
    local player_name="${tool}|${model}|${tool}|${timeout}: 0"

    # Replace placeholder or add player
    if grep -q "PLACEHOLDER" "$output_file"; then
        sed -i.bak "s/PLACEHOLDER.*/$player_name/" "$output_file"
        rm "${output_file}.bak"
    else
        # Insert player after ---PLAYERS---
        awk -v player="$player_name" '
            /^---PLAYERS---$/ { print; print player; next }
            { print }
        ' "$output_file" > "${output_file}.tmp"
        mv "${output_file}.tmp" "$output_file"
    fi
}

# Function to run single experiment
run_experiment() {
    local tool="$1"
    local model="$2"
    local board_size="$3"
    local timeout="$4"
    local iteration="$5"
    local turn_limit="$6"
    local template_file="$7"
    local results_subdir="$8"

    # Claude mode: agent or ask (from config; agent for models in CLAUDE_AGENT_MODE_MODELS)
    if [ "$tool" = "claude" ]; then
        if [[ " ${CLAUDE_AGENT_MODE_MODELS[*]:-} " = *" $model "* ]]; then
            export CLAUDE_AGENT_MODE=agent
        else
            export CLAUDE_AGENT_MODE="${CLAUDE_MODE:-ask}"
        fi
        echo "  [$(date +%H:%M:%S)] Claude mode: $CLAUDE_AGENT_MODE (model: $model)"
    fi

    local exp_name=$(gen_experiment_name "$tool" "$model" "$board_size" "$timeout" "$iteration" "$turn_limit")
    if [ "$tool" = "claude" ] && [ "${CLAUDE_AGENT_MODE:-ask}" = "agent" ]; then
        exp_name="${exp_name}_agent"
    fi
    local exp_dir="$results_subdir/$exp_name"
    mkdir -p "$exp_dir"

    local board_file="$exp_dir/board.txt"

    echo "  [$(date +%H:%M:%S)] Starting: $exp_name"

    # Create board file
    create_experiment_board "$template_file" "$exp_name" "$board_file" "$tool" "$model" "$timeout"

    # Determine game timeout
    local run_script="$DIR/run.sh"
    local game_timeout

    if [ "$turn_limit" != "unlimited" ]; then
        # Turn limit specified: timeout = turns × per-move-timeout + 60s buffer
        game_timeout=$((turn_limit * timeout + 60))
        export MAX_ROUNDS="$turn_limit"
    else
        # No turn limit: use reasonable max based on board size
        case "$board_size" in
            3x4) game_timeout=$((12 * timeout + 60)) ;;  # 12 cells
            4x4) game_timeout=$((16 * timeout + 60)) ;;  # 16 cells
            5x5) game_timeout=$((25 * timeout + 60)) ;;  # 25 cells
            7x7) game_timeout=$((49 * timeout + 60)) ;;  # 49 cells
            *) game_timeout=$((30 * timeout + 60)) ;;    # default
        esac
        case "$board_size" in
            3x4) export MAX_ROUNDS=12 ;;
            4x4) export MAX_ROUNDS=16 ;;
            5x5) export MAX_ROUNDS=25 ;;
            7x7) export MAX_ROUNDS=49 ;;
            *) export MAX_ROUNDS=30 ;;
        esac
    fi

    # Detect timeout command
    if command -v timeout &>/dev/null; then
        TIMEOUT_CMD="timeout"
    elif command -v gtimeout &>/dev/null; then
        TIMEOUT_CMD="gtimeout"
    else
        TIMEOUT_CMD=""
    fi

    # Set unique RUN_ID for this experiment (used in CSV logging)
    # Format: experiment_name to make it unique and identifiable
    export EXPERIMENT_RUN_ID="$exp_name"

    # Cursor mode: agent or ask (from config; agent for models in CURSOR_AGENT_MODE_MODELS)
    if [ "$tool" = "cursor" ]; then
        if [[ " ${CURSOR_AGENT_MODE_MODELS[*]:-} " = *" $model "* ]]; then
            export CURSOR_AGENT_MODE=agent
        else
            export CURSOR_AGENT_MODE="${CURSOR_MODE:-ask}"
        fi
        echo "  [$(date +%H:%M:%S)] Cursor mode: $CURSOR_AGENT_MODE (model: $model)"
    fi

    # Claude mode already set above (before exp_name) for experiment naming

    # Run with timeout and hang detection
    local start_time=$(date +%s)

    if [ -n "$TIMEOUT_CMD" ]; then
        # Run with timeout and capture PID for monitoring (quote duration so empty game_timeout never becomes "s" as command)
        $TIMEOUT_CMD --foreground "${game_timeout:-120}s" "$run_script" "$board_file" > "$exp_dir/output.log" 2>&1 &
        local run_pid=$!

        # Monitor for hangs (no log updates)
        # Hang detection: no progress for longer than per-move timeout + 60s buffer
        # This allows models time to think without false positives
        local hang_timeout=$((timeout + 60))  # Per-move timeout + buffer
        local check_interval=10  # Check every 10 seconds
        local max_no_progress=$((hang_timeout / check_interval))  # Calculate checks needed

        local last_log_size=0
        local no_progress_count=0

        while kill -0 $run_pid 2>/dev/null; do
            sleep $check_interval

            # Check if log is growing
            if [ -f "$exp_dir/output.log" ]; then
                local current_size=$(wc -c < "$exp_dir/output.log")
                if [ "$current_size" -eq "$last_log_size" ]; then
                    no_progress_count=$((no_progress_count + 1))
                    if [ $no_progress_count -ge $max_no_progress ]; then
                        echo "  [$(date +%H:%M:%S)] WARNING: No progress for ${hang_timeout}s (timeout=${timeout}s), killing hung process"
                        kill -9 $run_pid 2>/dev/null || true
                        echo "EXPERIMENT KILLED: Hung process detected (no output for ${hang_timeout}s)" >> "$exp_dir/output.log"
                        break
                    fi
                else
                    no_progress_count=0
                    last_log_size=$current_size
                fi
            fi
        done

        # Wait for process to finish
        wait $run_pid 2>/dev/null || true
    else
        # No timeout available, run directly
        "$run_script" "$board_file" > "$exp_dir/output.log" 2>&1 || true
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    # Copy final board state
    cp "$board_file" "$exp_dir/final_board.txt" 2>/dev/null || true

    # Copy log file
    local latest_log=$(ls -t "$DIR/logs/"*.csv 2>/dev/null | head -1)
    if [ -n "$latest_log" ]; then
        cp "$latest_log" "$exp_dir/game.csv"
    fi

    # Check for repeated errors (experiment failure)
    if [ -f "$board_file" ]; then
        local error_count=$(grep "errored" "$board_file" 2>/dev/null | wc -l | tr -d ' \n')
        error_count=${error_count:-0}
        if [ "$error_count" -gt 10 ]; then
            echo "  [$(date +%H:%M:%S)] WARNING: Experiment had $error_count errors (possible model failure)"
        fi
    fi

    echo "  [$(date +%H:%M:%S)] Completed: $exp_name (${elapsed}s)"
}

# Function to run all experiments for a tool (sequential for models)
run_tool_experiments() {
    local tool="$1"
    local results_subdir="$2"

    echo ""
    echo "=== Running experiments for $tool ==="

    eval "models=(\"\${${tool}_MODELS[@]}\")"

    for model in "${models[@]}"; do
        echo ""
        echo "--- Model: $model ---"

        local consecutive_failures=0
        local max_consecutive_failures=3  # Skip model after 3 consecutive failed experiments

        for board_size in "${BOARD_SIZES[@]}"; do
            # Check if we should skip this model
            if [ $consecutive_failures -ge $max_consecutive_failures ]; then
                echo "⚠️  Skipping remaining experiments for $model (too many consecutive failures)"
                break
            fi

            # Determine turn limit for this board size
            local turn_limit="unlimited"
            for limit_spec in "${TURN_LIMITS[@]}"; do
                if [[ "$limit_spec" == "$board_size:"* ]]; then
                    turn_limit="${limit_spec#*:}"
                    break
                fi
            done

            local template_file="$DIR/templates/board_${board_size}.txt"

            if [ ! -f "$template_file" ]; then
                echo "Warning: Template not found: $template_file"
                continue
            fi

            for timeout in "${TIMEOUTS[@]}"; do
                for iteration in $(seq 1 $ITERATIONS); do
                    # Check again before each experiment
                    if [ $consecutive_failures -ge $max_consecutive_failures ]; then
                        echo "⚠️  Skipping remaining experiments for $model"
                        break 3  # Break out of all three loops
                    fi

                    run_experiment "$tool" "$model" "$board_size" "$timeout" "$iteration" "$turn_limit" "$template_file" "$results_subdir"

                    # Check if experiment failed (high error count)
                    local exp_name=$(gen_experiment_name "$tool" "$model" "$board_size" "$timeout" "$iteration" "$turn_limit")
                    local board_file="$results_subdir/$exp_name/board.txt"

                    if [ -f "$board_file" ]; then
                        # Count errors - sanitize output
                        local error_count=$(grep "errored" "$board_file" 2>/dev/null | wc -l | tr -d ' \n')
                        error_count=${error_count:-0}

                        # Count successful moves (lines with parentheses that aren't errors)
                        local move_count=$(grep ")" "$board_file" 2>/dev/null | grep -v "errored" | wc -l | tr -d ' \n')
                        move_count=${move_count:-0}

                        # Consider it a failure if more than 80% errors or no successful moves
                        if [ "$move_count" -eq 0 ] || [ "$error_count" -gt $((move_count * 4)) ]; then
                            consecutive_failures=$((consecutive_failures + 1))
                            echo "  ⚠️  Experiment failure detected ($consecutive_failures/$max_consecutive_failures)"
                        else
                            consecutive_failures=0  # Reset on success
                        fi
                    fi

                    # Small delay between runs to avoid rate limiting
                    sleep 2
                done
            done
        done

        # Report if model was skipped
        if [ $consecutive_failures -ge $max_consecutive_failures ]; then
            echo ""
            echo "❌ Model $model skipped due to repeated failures"
            echo "   Check output logs for details"
            echo ""
        fi
    done
}

# Create results subdirectories
CLAUDE_RESULTS="$RESULTS_DIR/claude"
CURSOR_RESULTS="$RESULTS_DIR/cursor"
mkdir -p "$CLAUDE_RESULTS" "$CURSOR_RESULTS"

# Start timestamp
START_TIME=$(date +%s)

# Run experiments sequentially for all tools
# This ensures unique run IDs and avoids conflicts
echo "Running all experiments sequentially..."
echo ""

for tool in "${TOOLS[@]}"; do
    if [ "$tool" = "claude" ]; then
        run_tool_experiments "claude" "$CLAUDE_RESULTS"
    elif [ "$tool" = "cursor" ]; then
        run_tool_experiments "cursor" "$CURSOR_RESULTS"
    fi
done

# End timestamp
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=== BENCHMARK COMPLETE ==="
echo "Duration: ${DURATION}s ($(($DURATION / 60))m $(($DURATION % 60))s)"
echo "Results saved to: $RESULTS_DIR"
echo ""

# Update summary
{
    echo "Completed: $(date)"
    echo "Duration: ${DURATION}s ($(($DURATION / 60))m $(($DURATION % 60))s)"
} >> "$SUMMARY_FILE"

echo "Run analysis script to generate metrics:"
echo "  ./analyze-results.sh $RESULTS_DIR"
