#!/bin/bash

# Board Template Generator
# Creates initial board templates for different sizes
#
# Usage: ./generate-templates.sh

DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$DIR/templates"

mkdir -p "$TEMPLATES_DIR"

echo "=== BALDA Board Template Generator ==="
echo ""

# Function to generate a board template
# Args: rows cols initial_word output_file
generate_template() {
    local rows=$1
    local cols=$2
    local initial_word=$3
    local output_file=$4

    echo "Generating ${rows}x${cols} template with initial word: $initial_word"

    # Calculate center row for initial word
    local center_row=$((rows / 2))

    # Validate initial word fits
    if [ ${#initial_word} -gt $cols ]; then
        echo "Error: Initial word '$initial_word' (${#initial_word} chars) doesn't fit in $cols columns"
        return 1
    fi

    # Calculate starting column to center the word
    local word_start=$(( (cols - ${#initial_word}) / 2 ))

    # Generate board
    {
        for ((r=0; r<rows; r++)); do
            if [ $r -eq $center_row ]; then
                # This is the row with the initial word
                local line=""
                for ((c=0; c<cols; c++)); do
                    local char_idx=$((c - word_start))
                    if [ $char_idx -ge 0 ] && [ $char_idx -lt ${#initial_word} ]; then
                        line+="${initial_word:$char_idx:1}"
                    else
                        line+="."
                    fi
                done
                echo "$line"
            else
                # Empty row
                printf '.%.0s' $(seq 1 $cols)
                echo ""
            fi
        done

        # Add PLAYERS section
        echo "---PLAYERS---"
        echo "PLACEHOLDER|model|tool|180: 0"

        # Add WORDS section
        echo "---WORDS---"
    } > "$output_file"

    echo "  Created: $output_file"
}

# ==========================================
# TEMPLATE DEFINITIONS
# ==========================================

# 3x4 board
generate_template 3 4 "TEAM" "$TEMPLATES_DIR/board_3x4.txt"

# 4x4 board
generate_template 4 4 "STAR" "$TEMPLATES_DIR/board_4x4.txt"

# 5x5 board
generate_template 5 5 "AGENT" "$TEMPLATES_DIR/board_5x5.txt"

# 7x7 board
generate_template 7 7 "NETWORK" "$TEMPLATES_DIR/board_7x7.txt"

echo ""
echo "=== Templates Generated ==="
echo "Templates directory: $TEMPLATES_DIR"
echo ""
echo "Generated templates:"
ls -1 "$TEMPLATES_DIR"
echo ""
echo "To customize templates, edit files in $TEMPLATES_DIR"
