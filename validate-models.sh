#!/bin/bash

# Model Validation Script
# Validates that all configured models are available before running benchmark

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-$DIR/benchmark-config.sh}"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file '$CONFIG_FILE' not found"
    exit 1
fi

source "$CONFIG_FILE"

echo "=== Model Validation ==="
echo ""

# CLI backend paths (auto-detect or override via environment)
CLAUDE_CLI="${CLAUDE_CLI:-$(command -v claude)}"
CURSOR_CLI="${CURSOR_CLI:-$(command -v cursor)}"

VALIDATION_FAILED=0

# Function to test a model with a CLI
test_model() {
    local cli="$1"
    local model="$2"
    local tool="$3"

    echo -n "Testing $tool model '$model'... "

    case "$tool" in
        claude)
            # Test Claude model with a simple prompt
            if timeout 30s "$cli" -p --model "$model" --max-turns 1 "Say 'OK'" < /dev/null > /tmp/model_test_$$.txt 2>&1; then
                if grep -q "OK\|ok" /tmp/model_test_$$.txt; then
                    echo "✓ OK"
                    rm -f /tmp/model_test_$$.txt
                    return 0
                else
                    echo "⚠ WARNING: Model responded but output unexpected"
                    cat /tmp/model_test_$$.txt
                    rm -f /tmp/model_test_$$.txt
                    return 1
                fi
            else
                echo "✗ FAILED"
                echo "   Error output:"
                cat /tmp/model_test_$$.txt | head -10 | sed 's/^/   /'
                rm -f /tmp/model_test_$$.txt
                return 1
            fi
            ;;
        cursor)
            # Test Cursor model with a simple prompt
            if timeout 30s "$cli" agent -p --trust --model "$model" --mode ask "Say 'OK'" < /dev/null > /tmp/model_test_$$.txt 2>&1; then
                if grep -q "OK\|ok" /tmp/model_test_$$.txt; then
                    echo "✓ OK"
                    rm -f /tmp/model_test_$$.txt
                    return 0
                else
                    echo "⚠ WARNING: Model responded but output unexpected"
                    cat /tmp/model_test_$$.txt
                    rm -f /tmp/model_test_$$.txt
                    return 1
                fi
            else
                echo "✗ FAILED"
                echo "   Error output:"
                cat /tmp/model_test_$$.txt | head -10 | sed 's/^/   /'
                rm -f /tmp/model_test_$$.txt
                return 1
            fi
            ;;
    esac
}

# Validate Claude models
if [[ " ${TOOLS[@]} " =~ " claude " ]]; then
    echo "=== Validating Claude Models ==="
    if [ ! -x "$CLAUDE_CLI" ]; then
        echo "✗ ERROR: Claude CLI not found at: $CLAUDE_CLI"
        VALIDATION_FAILED=1
    else
        for model in "${claude_MODELS[@]}"; do
            if ! test_model "$CLAUDE_CLI" "$model" "claude"; then
                VALIDATION_FAILED=1
            fi
            sleep 1  # Avoid rate limiting
        done
    fi
    echo ""
fi

# Validate Cursor models
if [[ " ${TOOLS[@]} " =~ " cursor " ]]; then
    echo "=== Validating Cursor Models ==="
    if [ ! -x "$CURSOR_CLI" ]; then
        echo "✗ ERROR: Cursor CLI not found at: $CURSOR_CLI"
        VALIDATION_FAILED=1
    else
        for model in "${cursor_MODELS[@]}"; do
            if ! test_model "$CURSOR_CLI" "$model" "cursor"; then
                VALIDATION_FAILED=1
            fi
            sleep 1  # Avoid rate limiting
        done
    fi
    echo ""
fi

# Summary
if [ $VALIDATION_FAILED -eq 0 ]; then
    echo "=== Validation Complete: All models OK ✓ ==="
    exit 0
else
    echo "=== Validation Failed: Some models have errors ✗ ==="
    echo ""
    echo "Please fix the errors above before running the benchmark."
    echo ""
    echo "Common fixes:"
    echo "  1. Check model names: cursor agent --list-models"
    echo "  2. Update benchmark-config.sh with correct model IDs"
    echo "  3. Ensure you have access to these models"
    echo "  4. Check for typos in model names"
    exit 1
fi
