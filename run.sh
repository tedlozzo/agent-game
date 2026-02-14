#!/bin/bash

# BALDA Game Agent Runner
# Usage: ./run.sh [game_file]
#
# The game file contains all state in one file:
#   - Board (grid, lines before ---PLAYERS---)
#   - ---PLAYERS--- section (Name|model|cli|timeout: score)
#   - ---WORDS--- section (word history)

DIR="$(cd "$(dirname "$0")" && pwd)"
GAME_FILE="${1:-$DIR/board.txt}"

# CLI backend paths (auto-detect or override via environment)
CLAUDE_CLI="${CLAUDE_CLI:-$(command -v claude)}"
CURSOR_CLI="${CURSOR_CLI:-$(command -v cursor)}"

# Section delimiters
DELIM_PLAYERS="---PLAYERS---"
DELIM_WORDS="---WORDS---"

# Game logging (CSV format: timestamp,event,details)
LOGDIR="$DIR/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/game_$(date +%Y%m%d_%H%M%S).csv"
GAME_START_TIME=$(date +%s)
# Use EXPERIMENT_RUN_ID if set (from benchmark.sh), otherwise use timestamp
RUN_ID="${EXPERIMENT_RUN_ID:-$(date '+%Y-%m-%d %H:%M:%S')}"

# CSV log: writes exactly one line per call
# Usage: log EVENT_TYPE "details" [MODEL] [SCORE] [ERROR]
log() {
    local event_type="$1"
    local message="$2"
    local model="${3:-}"
    local score="${4:-}"
    local error="${5:-}"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    # CSV-safe: double internal quotes, replace newlines with literal \n
    local safe_msg="${message//\"/\"\"}"
    safe_msg="${safe_msg//$'\n'/\\n}"
    local safe_error="${error//\"/\"\"}"
    safe_error="${safe_error//$'\n'/\\n}"
    echo "\"${RUN_ID}\",${ts},\"${model}\",\"${FIELD_SIZE}\",\"${INITIAL_WORD}\",${event_type},\"${safe_msg}\",${score},\"${safe_error}\"" >> "$LOGFILE"
}

# Write CSV header (populated after game file is read)
# Header will be written after FIELD_SIZE and INITIAL_WORD are extracted

# Detect timeout command (gtimeout on macOS with Homebrew coreutils)
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
else
    echo "Warning: timeout/gtimeout not found. Install: brew install coreutils"
    TIMEOUT_CMD=""
fi

# --- Section reading/writing helpers ---

read_section() {
    case "$1" in
        BOARD)   /usr/bin/awk '/^---PLAYERS---$/{exit} {print}' "$GAME_FILE" ;;
        PLAYERS) /usr/bin/awk '/^---PLAYERS---$/{f=1;next} /^---WORDS---$/{exit} f{print}' "$GAME_FILE" ;;
        WORDS)   /usr/bin/awk '/^---WORDS---$/{f=1;next} f{print}' "$GAME_FILE" ;;
    esac
}

# Extract "Name: score" lines from PLAYERS section for display/template
extract_scores() {
    local players="$1"
    while IFS='|' read -r name _ _ ts; do
        [ -z "$name" ] && continue
        echo "$name: ${ts##*: }"
    done <<< "$players"
}

write_game_file() {
    local board="$1" players="$2" words="$3"
    {
        printf '%s\n' "$board"
        echo "$DELIM_PLAYERS"
        printf '%s\n' "$players"
        echo "$DELIM_WORDS"
        [ -n "$words" ] && printf '%s\n' "$words"
    } > "$GAME_FILE"
}

# Log a failed move to the game file
log_failed_move() {
    local player_name="$1"
    local error="$2"

    local board=$(read_section BOARD)
    local players=$(read_section PLAYERS)
    local words=$(read_section WORDS)

    # Append error to words
    local err_line="-- ($player_name) errored ($error)"
    if [ -n "$words" ]; then
        words="${words}
${err_line}"
    else
        words="$err_line"
    fi

    write_game_file "$board" "$players" "$words"
}

# --- Validation ---

# Check game file exists
if [ ! -f "$GAME_FILE" ]; then
    echo "Error: Game file '$GAME_FILE' not found"
    exit 1
fi

# Verify all section delimiters are present
for section in "$DELIM_PLAYERS" "$DELIM_WORDS"; do
    if ! /usr/bin/grep -qF -- "$section" "$GAME_FILE"; then
        echo "Error: Missing section delimiter '$section' in $GAME_FILE"
        exit 1
    fi
done

# Function to verify required CLI backends are installed
verify_required_clis() {
    local need_claude=false
    local need_cursor=false

    while IFS='|' read -r _NAME _MODEL _CLI _TIMEOUT_SCORE || [ -n "$_NAME" ]; do
        [ -z "$_NAME" ] && continue
        _CLI="${_CLI:-claude}"
        case "$_CLI" in
            claude) need_claude=true ;;
            cursor) need_cursor=true ;;
            *)
                echo "Error: Unknown CLI backend '$_CLI' for player '$_NAME'"
                exit 1
                ;;
        esac
    done <<< "$(read_section PLAYERS)"

    if [ "$need_claude" = true ] && [ ! -x "$CLAUDE_CLI" ]; then
        echo "Error: claude CLI not found at $CLAUDE_CLI"
        exit 1
    fi

    if [ "$need_cursor" = true ] && [ ! -x "$CURSOR_CLI" ]; then
        echo "Error: cursor CLI not found at $CURSOR_CLI"
        exit 1
    fi
}

# Verify required CLI backends are installed
verify_required_clis

# Extract game metadata for CSV logging
INITIAL_BOARD=$(read_section BOARD)
# Calculate field size (rows x cols)
BOARD_ROWS=$(echo "$INITIAL_BOARD" | wc -l | tr -d ' ')
BOARD_COLS=$(echo "$INITIAL_BOARD" | head -1 | wc -c | tr -d ' ')
BOARD_COLS=$((BOARD_COLS - 1))  # Subtract newline
FIELD_SIZE="${BOARD_ROWS}x${BOARD_COLS}"

# Max rounds: from env or derive from board size (cells = max possible moves)
if [ -z "${MAX_ROUNDS:-}" ]; then
    MAX_ROUNDS=$((BOARD_ROWS * BOARD_COLS))
fi

# Extract initial word (first non-empty sequence of letters)
INITIAL_WORD=$(/bin/echo "$INITIAL_BOARD" | /usr/bin/grep -o '[a-zA-Z]\+' | head -1)
INITIAL_WORD="${INITIAL_WORD:-none}"

# Extract model from first player (for CSV logging)
# Format: Name|model|cli|timeout: score
GAME_MODEL=$(read_section PLAYERS | head -1 | cut -d'|' -f2)
GAME_MODEL="${GAME_MODEL:-unknown}"

# Write CSV header now that we have game metadata
echo "run_id,timestamp,model,field_size,initial_word,event,details,score,error" > "$LOGFILE"

# Dump initial game file to log for post-game analysis
echo "=== INITIAL GAME FILE: $GAME_FILE ==="
/bin/cat "$GAME_FILE"
echo "=== END INITIAL GAME FILE ==="
echo ""
log GAME_START "$GAME_FILE" "$GAME_MODEL" "" ""
log GAME_CONFIG "$(/bin/cat "$GAME_FILE")" "$GAME_MODEL" "" ""

# --- Per-player statistics (parallel arrays for bash 3.x compatibility) ---
STAT_PLAYERS=()
STAT_ATTEMPTS=()
STAT_SUCCESS=()
STAT_FAIL=()

# Initialize stats for all players
while IFS='|' read -r _sname _ _ _ || [ -n "$_sname" ]; do
    [ -z "$_sname" ] && continue
    STAT_PLAYERS+=("$_sname")
    STAT_ATTEMPTS+=(0)
    STAT_SUCCESS+=(0)
    STAT_FAIL+=(0)
done <<< "$(read_section PLAYERS)"

# Get player index
get_player_idx() {
    local player="$1"
    local i=0
    for p in "${STAT_PLAYERS[@]}"; do
        [ "$p" = "$player" ] && echo "$i" && return
        i=$((i + 1))
    done
    echo "-1"
}

# Print final statistics summary
print_statistics() {
    echo "=== GAME STATISTICS ==="
    echo ""
    printf "%-12s %8s %8s %8s %8s\n" "Player" "Attempts" "Success" "Failed" "Rate"
    printf "%-12s %8s %8s %8s %8s\n" "------" "--------" "-------" "------" "----"
    local i=0
    for player in "${STAT_PLAYERS[@]}"; do
        local att="${STAT_ATTEMPTS[$i]}"
        local suc="${STAT_SUCCESS[$i]}"
        local fai="${STAT_FAIL[$i]}"
        if [ "$att" -gt 0 ]; then
            local rate=$((suc * 100 / att))
            printf "%-12s %8d %8d %8d %7d%%\n" "$player" "$att" "$suc" "$fai" "$rate"
            log STAT "$player|$att|$suc|$fai|${rate}%" "$GAME_MODEL" "" ""
        else
            printf "%-12s %8d %8d %8d %8s\n" "$player" "$att" "$suc" "$fai" "N/A"
            log STAT "$player|$att|$suc|$fai|N/A" "$GAME_MODEL" "" ""
        fi
        i=$((i + 1))
    done
    local duration=$(( $(date +%s) - GAME_START_TIME ))
    echo ""
    echo "Game duration: ${duration}s"
    log GAME_END "${duration}s" "$GAME_MODEL" "" ""
    echo ""
}

# Function to execute a single move for a player
# Sets non-local: LAST_ERROR, LAST_ERROR_MSG, LAST_OUTPUT_LINE, MOVE_ELAPSED, LAST_WORD, LAST_WORD_LENGTH
execute_move() {
    local PLAYER_NAME="$1"
    local ATTEMPT="$2"
    local MODEL="$3"
    local CLI_BACKEND="$4"
    local MOVE_TIMEOUT="${5:-90}"
    local RETRY_CONTEXT="$6"

    # Initialize exported state
    MOVE_ELAPSED=0
    LAST_WORD=""
    LAST_WORD_LENGTH=0

    # Read game state from sections
    local BOARD_RAW=$(read_section BOARD)
    local PLAYERS_RAW=$(read_section PLAYERS)
    USED_WORDS=$(read_section WORDS)
    # Filter out error entries (no value to agent, reduces prompt tokens)
    USED_WORDS_CLEAN=$(/bin/echo "$USED_WORDS" | /usr/bin/grep -v '^-- ')

    # Extract scores from player lines for agent template
    SCORES=$(extract_scores "$PLAYERS_RAW")

    # Parse board into array for validation/update
    local BOARD_ARRAY=()
    while IFS= read -r line || [ -n "$line" ]; do
        BOARD_ARRAY+=("$line")
    done <<< "$BOARD_RAW"

    # Build annotated board with coordinates and empty cells list
    # Derive column count from first row
    local FIRST_ROW
    FIRST_ROW=$(head -1 <<< "$BOARD_RAW")
    local COL_HEADER="   "
    for (( ci=0; ci<${#FIRST_ROW}; ci++ )); do
        COL_HEADER+=" $ci"
    done
    local BOARD_LABELED="$COL_HEADER"
    local EMPTY_CELLS_LIST=""
    local ROW_NUM=0
    while IFS= read -r line || [ -n "$line" ]; do
        local BOARD_LINE="$ROW_NUM:  "
        for (( i=0; i<${#line}; i++ )); do
            local CHAR="${line:$i:1}"
            BOARD_LINE+="$CHAR "
            if [ "$CHAR" = "." ]; then
                EMPTY_CELLS_LIST+="($ROW_NUM;$i) "
            fi
        done
        BOARD_LABELED+=$'\n'"$BOARD_LINE"
        ROW_NUM=$((ROW_NUM + 1))
    done <<< "$BOARD_RAW"

    # Read the agent instructions template
    INSTRUCTIONS=$(/bin/cat "$DIR/AGENT_INSTRUCTIONS.md")

    # Replace placeholders with actual game state
    INSTRUCTIONS="${INSTRUCTIONS//\{\{BOARD\}\}/$BOARD_LABELED}"
    INSTRUCTIONS="${INSTRUCTIONS//\{\{EMPTY_CELLS\}\}/$EMPTY_CELLS_LIST}"
    INSTRUCTIONS="${INSTRUCTIONS//\{\{USED_WORDS\}\}/$USED_WORDS_CLEAN}"
    INSTRUCTIONS="${INSTRUCTIONS//\{\{SCORES\}\}/$SCORES}"
    INSTRUCTIONS="${INSTRUCTIONS//\{\{RETRY_CONTEXT\}\}/$RETRY_CONTEXT}"
    INSTRUCTIONS="${INSTRUCTIONS//\{\{MOVE_TIMEOUT\}\}/$MOVE_TIMEOUT}"

    # Build CLI command based on backend
    # Redirect stdin from /dev/null to prevent it from consuming input
    local CLI_CMD=()

    if [ -n "$TIMEOUT_CMD" ]; then
        CLI_CMD+=("$TIMEOUT_CMD" "$MOVE_TIMEOUT")
    fi

    case "$CLI_BACKEND" in
        claude)
            CLI_CMD+=("$CLAUDE_CLI" "-p" "--model" "$MODEL" "--max-turns" "1" "--system-prompt" "$INSTRUCTIONS")
            # Ask mode = no tools (read-only); agent mode = tools allowed (default)
            if [ "${CLAUDE_AGENT_MODE:-ask}" = "ask" ]; then
                CLI_CMD+=("--tools" "")
            fi
            # Use "--" to prevent variadic --tools from consuming the prompt
            CLI_CMD+=("--" "Make your move.")
            ;;
        cursor)
            # cursor agent has no --system-prompt flag; embed instructions in the prompt
            local COMBINED_PROMPT="${INSTRUCTIONS}

Make your move."
            # Mode from config (CURSOR_AGENT_MODE=agent or ask, set by benchmark.sh)
            if [ "${CURSOR_AGENT_MODE:-ask}" = "agent" ]; then
                CLI_CMD+=("$CURSOR_CLI" "agent" "-p" "--trust" "--model" "$MODEL" "$COMBINED_PROMPT")
            else
                CLI_CMD+=("$CURSOR_CLI" "agent" "-p" "--trust" "--model" "$MODEL" "--mode" "ask" "$COMBINED_PROMPT")
            fi
            ;;
        *)
            echo "❌ ERROR: Unknown CLI backend '$CLI_BACKEND'"
            LAST_ERROR="internal error"
            return 1
            ;;
    esac

    local START_TIME=$(date +%s)
    FULL_OUTPUT=$("${CLI_CMD[@]}" < /dev/null 2>&1)
    CLI_EXIT=$?
    local END_TIME=$(date +%s)
    MOVE_ELAPSED=$((END_TIME - START_TIME))

    OUTPUT=$(/bin/echo "$FULL_OUTPUT" | /usr/bin/tail -1)
    # Export output for retry context
    LAST_OUTPUT_LINE="$OUTPUT"

    # Display the result
    if [ $ATTEMPT -gt 1 ]; then
        echo "[$PLAYER_NAME - Attempt $ATTEMPT] (${MOVE_ELAPSED}s) $OUTPUT"
    else
        echo "[$PLAYER_NAME] (${MOVE_ELAPSED}s) $OUTPUT"
    fi

    # Handle timeout and internal errors early
    if [ $CLI_EXIT -eq 124 ]; then
        echo ""
        echo "❌ ERROR: $CLI_BACKEND agent timed out after ${MOVE_TIMEOUT}s"
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="timeout"
        LAST_ERROR_MSG="Agent timed out after ${MOVE_TIMEOUT}s. Respond faster with a simpler, shorter word."
        return 1
    fi

    if [ -z "$OUTPUT" ] || [ $CLI_EXIT -ne 0 ]; then
        echo "[DEBUG] $CLI_BACKEND agent exit code: $CLI_EXIT"
        echo "[DEBUG] Full output:"
        echo "$FULL_OUTPUT"
        echo "[DEBUG] ---"
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="internal error"
        LAST_ERROR_MSG="Agent returned empty output or errored. Output a single line in the exact required format."
        return 1
    fi

    # Parse the output
    # Format: LETTER: X, POSITION: r;c, WORD: WORDHERE, PATH: (r;c)->(r;c)->..., DEFINITION: brief meaning
    if [[ $OUTPUT =~ LETTER:\ ([A-Z]),\ POSITION:\ ([0-9])\;([0-9]),\ WORD:\ ([A-Z]+),\ PATH:\ (.+),\ DEFINITION:\ (.+)$ ]]; then
    local LETTER="${BASH_REMATCH[1]}"
    local ROW="${BASH_REMATCH[2]}"
    local COL="${BASH_REMATCH[3]}"
    local WORD="${BASH_REMATCH[4]}"
    local MOVE_PATH="${BASH_REMATCH[5]}"
    local DEFINITION="${BASH_REMATCH[6]}"

    # Calculate word length (score)
    local WORD_LENGTH=${#WORD}

    # === VALIDATION ===

    # Check 1: Position must be empty
    CURRENT_CELL="${BOARD_ARRAY[$ROW]:$COL:1}"
    if [ "$CURRENT_CELL" != "." ]; then
        echo ""
        echo "❌ INVALID MOVE: Position $ROW;$COL is not empty (contains '$CURRENT_CELL')"
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="occupied cell"
        LAST_ERROR_MSG="Position $ROW;$COL is OCCUPIED (contains '$CURRENT_CELL'). You can ONLY place on cells marked '.' in the board. Check the empty cells list."
        return 1
    fi

    # Check 2: Validate PATH
    # Extract coordinates from PATH: (r;c)->(r;c)->...
    local PATH_COORDS=()
    local TEMP_PATH="$MOVE_PATH"
    while [[ $TEMP_PATH =~ \(([0-9])\;([0-9])\) ]]; do
        PATH_COORDS+=("${BASH_REMATCH[1]};${BASH_REMATCH[2]}")
        # Remove the matched part to continue
        TEMP_PATH="${TEMP_PATH#*${BASH_REMATCH[0]}}"
    done

    # Check 3: PATH length must match WORD length
    if [ ${#PATH_COORDS[@]} -ne $WORD_LENGTH ]; then
        echo ""
        echo "❌ INVALID MOVE: PATH length (${#PATH_COORDS[@]}) doesn't match WORD length ($WORD_LENGTH)"
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="wrong path"
        LAST_ERROR_MSG="PATH has ${#PATH_COORDS[@]} cells but WORD '$WORD' has $WORD_LENGTH letters. Each letter needs exactly one cell."
        return 1
    fi

    # Check 4: Validate each step in PATH
    local PREV_R=""
    local PREV_C=""
    local EXPECTED_WORD=""
    local DECLARED_POSITIONS=()
    local NEW_LETTER_FOUND=false

    for i in "${!PATH_COORDS[@]}"; do
        IFS=';' read -r R C <<< "${PATH_COORDS[$i]}"

        # Check for duplicate positions
        for pos in "${DECLARED_POSITIONS[@]}"; do
            if [ "$pos" = "$R;$C" ]; then
                echo ""
                echo "❌ INVALID MOVE: Cell $R;$C is used multiple times in PATH"
                echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
                LAST_ERROR="wrong path"
                LAST_ERROR_MSG="Cell $R;$C appears multiple times in PATH. Each cell can only be used ONCE."
                return 1
            fi
        done
        DECLARED_POSITIONS+=("$R;$C")

        # Check adjacency (except for first cell)
        if [ -n "$PREV_R" ]; then
            DIFF_R=$((R - PREV_R))
            DIFF_C=$((C - PREV_C))
            # Absolute values
            [ $DIFF_R -lt 0 ] && DIFF_R=$((- DIFF_R))
            [ $DIFF_C -lt 0 ] && DIFF_C=$((- DIFF_C))

            # Must be adjacent: exactly one step in one direction
            if [ $(($DIFF_R + $DIFF_C)) -ne 1 ]; then
                echo ""
                echo "❌ INVALID MOVE: Cells ($PREV_R;$PREV_C) and ($R;$C) are not adjacent"
                echo "   This is a DIAGONAL move - only horizontal/vertical moves allowed!"
                echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
                LAST_ERROR="wrong path"
                LAST_ERROR_MSG="Cells ($PREV_R;$PREV_C) and ($R;$C) are NOT adjacent. Adjacent means |row_diff|+|col_diff|=1. You had diff=($DIFF_R,$DIFF_C). Only change row OR column by 1, never both."
                return 1
            fi
        fi

        # Get letter at this position
        if [ "$R;$C" = "$ROW;$COL" ]; then
            # This is the new letter position
            CELL_LETTER="$LETTER"
            NEW_LETTER_FOUND=true
        else
            # Existing letter on board
            CELL_LETTER="${BOARD_ARRAY[$R]:$C:1}"
            if [ "$CELL_LETTER" = "." ]; then
                echo ""
                echo "❌ INVALID MOVE: PATH uses empty cell at $R;$C (only the new letter can be at an empty cell)"
                echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
                LAST_ERROR="wrong path"
                LAST_ERROR_MSG="PATH uses empty cell at $R;$C but only your newly placed letter can be on an empty cell. All other PATH cells must have existing letters."
                return 1
            fi
            # Convert to uppercase for comparison
            case "$CELL_LETTER" in
                a) CELL_LETTER="A" ;;
                b) CELL_LETTER="B" ;;
                c) CELL_LETTER="C" ;;
                d) CELL_LETTER="D" ;;
                e) CELL_LETTER="E" ;;
                f) CELL_LETTER="F" ;;
                g) CELL_LETTER="G" ;;
                h) CELL_LETTER="H" ;;
                i) CELL_LETTER="I" ;;
                j) CELL_LETTER="J" ;;
                k) CELL_LETTER="K" ;;
                l) CELL_LETTER="L" ;;
                m) CELL_LETTER="M" ;;
                n) CELL_LETTER="N" ;;
                o) CELL_LETTER="O" ;;
                p) CELL_LETTER="P" ;;
                q) CELL_LETTER="Q" ;;
                r) CELL_LETTER="R" ;;
                s) CELL_LETTER="S" ;;
                t) CELL_LETTER="T" ;;
                u) CELL_LETTER="U" ;;
                v) CELL_LETTER="V" ;;
                w) CELL_LETTER="W" ;;
                x) CELL_LETTER="X" ;;
                y) CELL_LETTER="Y" ;;
                z) CELL_LETTER="Z" ;;
            esac
        fi

        EXPECTED_WORD="${EXPECTED_WORD}${CELL_LETTER}"
        PREV_R=$R
        PREV_C=$C
    done

    # Check 5: New letter must be in the PATH
    if [ "$NEW_LETTER_FOUND" = false ]; then
        echo ""
        echo "❌ INVALID MOVE: New letter at $ROW;$COL is not used in the PATH"
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="wrong path"
        LAST_ERROR_MSG="Your new letter at position $ROW;$COL must appear in the PATH. Include ($ROW;$COL) in your path."
        return 1
    fi

    # Check 6: Word formed by PATH must match declared WORD
    if [ "$EXPECTED_WORD" != "$WORD" ]; then
        echo ""
        echo "❌ INVALID MOVE: PATH forms '$EXPECTED_WORD' but declared WORD is '$WORD'"
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="wrong path"
        LAST_ERROR_MSG="PATH actually spells '$EXPECTED_WORD' but you declared '$WORD'. Verify each cell in the path contains the letter you expect by reading the board carefully."
        return 1
    fi

    # Check 7: Word must not be already used
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Extract just the word (first field before space)
        used_word="${line%% (*}"
        if [ "$used_word" = "$WORD" ]; then
            echo ""
            echo "❌ INVALID MOVE: Word '$WORD' has already been used"
            echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
            LAST_ERROR="duplicate word"
            LAST_ERROR_MSG="Word '$WORD' was already used. Check the USED WORDS list and pick a different word."
            return 1
        fi
    done <<< "$USED_WORDS"

    # ========================================
    # ALL VALIDATION PASSED - NOW UPDATE FILES
    # ========================================

    echo "✓ Move validated successfully"

    # Export word info for logging in main loop
    LAST_WORD="$WORD"
    LAST_WORD_LENGTH=$WORD_LENGTH

    # ========================================
    # Step 1: Build new board
    # ========================================
    CURRENT_ROW="${BOARD_ARRAY[$ROW]}"
    NEW_ROW="${CURRENT_ROW:0:$COL}${LETTER}${CURRENT_ROW:$((COL+1))}"
    BOARD_ARRAY[$ROW]="$NEW_ROW"
    local NEW_BOARD=$(printf '%s\n' "${BOARD_ARRAY[@]}")

    # ========================================
    # Step 2: Build new words
    # ========================================
    local NEW_WORD_LINE="$WORD ($PLAYER_NAME) $WORD_LENGTH ($DEFINITION)"
    local NEW_WORDS
    if [ -n "$USED_WORDS" ]; then
        NEW_WORDS="${USED_WORDS}
${NEW_WORD_LINE}"
    else
        NEW_WORDS="$NEW_WORD_LINE"
    fi

    # ========================================
    # Step 3: Update score in PLAYERS section
    # ========================================
    local NEW_PLAYERS=""
    while IFS= read -r pline; do
        [ -z "$pline" ] && continue
        local pname="${pline%%|*}"
        if [ "$pname" = "$PLAYER_NAME" ]; then
            local prefix="${pline%: *}"
            local old_score="${pline##*: }"
            local new_score=$((old_score + WORD_LENGTH))
            NEW_PLAYERS+="${prefix}: ${new_score}"$'\n'
        else
            NEW_PLAYERS+="$pline"$'\n'
        fi
    done <<< "$PLAYERS_RAW"
    NEW_PLAYERS="${NEW_PLAYERS%$'\n'}"

    # ========================================
    # Step 4: Write all sections atomically
    # ========================================
    write_game_file "$NEW_BOARD" "$NEW_PLAYERS" "$NEW_WORDS"

    # ========================================
    # Step 5: Check for game over
    # ========================================
    EMPTY_CELLS=0
    for row in "${BOARD_ARRAY[@]}"; do
        # Count dots in this row
        DOTS="${row//[^.]}"
        EMPTY_CELLS=$((EMPTY_CELLS + ${#DOTS}))
    done

    if [ $EMPTY_CELLS -eq 0 ]; then
        echo ""
        echo "🎮 GAME OVER! Board is full!"
        echo ""
        echo "=== FINAL SCORES ==="
        extract_scores "$NEW_PLAYERS"
        echo ""
        return 2  # Special code for game over
    fi

    # Move successful
    return 0

    else
        echo ""
        echo "❌ ERROR: Could not parse agent output"
        echo "Expected format: LETTER: X, POSITION: r;c, WORD: WORD, PATH: (r;c)->(r;c)->..., DEFINITION: meaning"
        echo "Received: $OUTPUT"
        echo ""
        echo "⚠️  NO FILES WERE MODIFIED - Game state unchanged"
        LAST_ERROR="wrong output"
        LAST_ERROR_MSG="Output could not be parsed. You MUST output EXACTLY one line: LETTER: X, POSITION: r;c, WORD: WORD, PATH: (r;c)->(r;c)->..., DEFINITION: meaning. No other text."
        return 1
    fi
}

# ========================================
# MAIN LOOP: Process all players until game over
# ========================================

ROUND=1
CONSECUTIVE_FAILURES=0

while true; do
    echo "=== ROUND $ROUND START ==="
    echo ""
    log ROUND_START "$ROUND" "$GAME_MODEL" "" ""

    # Read players from PLAYERS section (format: Name|model-id|cli-backend|timeout: score)
    while IFS='|' read -r PLAYER_NAME MODEL CLI_BACKEND TIMEOUT_AND_SCORE || [ -n "$PLAYER_NAME" ]; do
        # Skip empty lines
        [ -z "$PLAYER_NAME" ] && continue
        CLI_BACKEND="${CLI_BACKEND:-claude}"
        PLAYER_TIMEOUT="${TIMEOUT_AND_SCORE%%: *}"
        PLAYER_TIMEOUT="${PLAYER_TIMEOUT:-90}"

        cursor_mode=""
        claude_mode=""
        if [ "$CLI_BACKEND" = "cursor" ]; then
            cursor_mode=" [${CURSOR_AGENT_MODE:-ask} mode]"
        elif [ "$CLI_BACKEND" = "claude" ]; then
            claude_mode=" [${CLAUDE_AGENT_MODE:-ask} mode]"
        fi
        echo "($PLAYER_NAME using $MODEL via $CLI_BACKEND, ${PLAYER_TIMEOUT}s timeout)$cursor_mode$claude_mode"
        log TURN_START "$PLAYER_NAME|$MODEL|$CLI_BACKEND|${PLAYER_TIMEOUT}s${cursor_mode}${claude_mode}" "$MODEL" "" ""

        # Single attempt per player (increase MAX_ATTEMPTS to re-enable retries)
        MAX_ATTEMPTS=1
        SUCCESS=false
        ERRORS=()
        RETRY_MSG=""
        for ATTEMPT in $(seq 1 $MAX_ATTEMPTS); do
            LAST_ERROR=""
            LAST_ERROR_MSG=""
            LAST_OUTPUT_LINE=""
            execute_move "$PLAYER_NAME" "$ATTEMPT" "$MODEL" "$CLI_BACKEND" "$PLAYER_TIMEOUT" "$RETRY_MSG"
            RESULT=$?
            PIDX=$(get_player_idx "$PLAYER_NAME")
            STAT_ATTEMPTS[$PIDX]=$(( ${STAT_ATTEMPTS[$PIDX]} + 1 ))

            if [ $RESULT -eq 0 ]; then
                STAT_SUCCESS[$PIDX]=$(( ${STAT_SUCCESS[$PIDX]} + 1 ))
                log MOVE_OK "$PLAYER_NAME|$LAST_WORD|${MOVE_ELAPSED}s" "$MODEL" "$LAST_WORD_LENGTH" ""
                SUCCESS=true
                echo ""
                break
            elif [ $RESULT -eq 2 ]; then
                STAT_SUCCESS[$PIDX]=$(( ${STAT_SUCCESS[$PIDX]} + 1 ))
                log MOVE_OK "$PLAYER_NAME|$LAST_WORD|${MOVE_ELAPSED}s" "$MODEL" "$LAST_WORD_LENGTH" ""
                log GAME_OVER "$(extract_scores "$(read_section PLAYERS)")" "$GAME_MODEL" "" ""
                echo ""
                print_statistics
                exit 0
            else
                ERRORS+=("$LAST_ERROR")
                log MOVE_FAIL "$PLAYER_NAME|${MOVE_ELAPSED}s" "$MODEL" "" "$LAST_ERROR"

                if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
                    # Build retry context for next attempt
                    RETRY_MSG="## PREVIOUS FAILED ATTEMPT (Attempt $ATTEMPT of $MAX_ATTEMPTS)
Your move was REJECTED. You MUST try a DIFFERENT move.

Your output: $LAST_OUTPUT_LINE
Error: $LAST_ERROR_MSG

DO NOT repeat the same move. Pick a DIFFERENT position, word, or path."

                    echo "⚠️  $PLAYER_NAME will retry..."
                    echo ""
                    sleep 1
                else
                    STAT_FAIL[$PIDX]=$(( ${STAT_FAIL[$PIDX]} + 1 ))
                    echo "⚠️  $PLAYER_NAME failed. Skipping turn."
                    echo ""

                    # Log failure to game file
                    log_failed_move "$PLAYER_NAME" "$LAST_ERROR"
                fi
            fi
        done

        # Small delay between players to avoid rate limiting
        sleep 1
    done <<< "$(read_section PLAYERS)"

    # Track consecutive rounds with no successful move (for early exit)
    if [ "$SUCCESS" = true ]; then
        CONSECUTIVE_FAILURES=0
    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    fi

    echo "=== ROUND $ROUND COMPLETE ==="
    echo ""
    echo "Current Scores:"
    extract_scores "$(read_section PLAYERS)"
    log ROUND_END "$ROUND|$(extract_scores "$(read_section PLAYERS)" | tr '\n' '|' | sed 's/|$//')" "$GAME_MODEL" "" ""
    echo ""

    # Early exit: too many consecutive failures (no progress)
    if [ $CONSECUTIVE_FAILURES -ge 5 ]; then
        echo "Game stopped: too many consecutive failures ($CONSECUTIVE_FAILURES)"
        exit 0
    fi

    ROUND=$((ROUND + 1))

    # Max rounds reached (bounded time so benchmark always gets final state)
    if [ -n "$MAX_ROUNDS" ] && [ $ROUND -gt "$MAX_ROUNDS" ]; then
        echo "Max rounds reached ($MAX_ROUNDS)"
        exit 0
    fi
done
