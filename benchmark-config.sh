#!/bin/bash

# BALDA Benchmark Configuration
# Edit this file to configure your benchmark runs

# ==========================================
# TOOLS TO TEST
# ==========================================
# Available: claude, cursor. Include both to run Claude and Cursor (e.g. gpt-5.2).
TOOLS=("claude" "cursor")

# ==========================================
# MODELS TO TEST
# ==========================================
# Models for each tool will run SEQUENTIALLY (to avoid rate limits)
#   Priority 1 — Rerun (core models, easy wins)                                                                                                                                                                                                                                                                                                                                                                                     
#   ┌───────────────────┬────────┬───────┬───────┬──────┬──────┐
#   │       Model       │  Tool  │ Mode  │ Field │ Runs │ Need │                                                                                                                                                       
#   ├───────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ claude-opus-4-6   │ claude │ agent │ 3x4   │ 2    │ +1   │
#   ├───────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ claude-opus-4-6   │ claude │ agent │ 7x7   │ 2    │ +1   │
#   ├───────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ claude-sonnet-4-5 │ claude │ agent │ 3x4   │ 2    │ +1   │
#   ├───────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ opus-4-6          │ cursor │ ask   │ 5x5   │ 2    │ +1   │
#   ├───────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ claude-haiku-4-5  │ claude │ agent │ 7x7   │ 2    │ +1   │
#   ├───────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ claude-haiku-4-5  │ claude │ ask   │ 7x7   │ 2    │ +1   │
#   └───────────────────┴────────┴───────┴───────┴──────┴──────┘

#   These are your core Claude models and just need 1 more iteration each to hit 3.

#   Priority 2 — Rerun if you want the model in the article

#   ┌────────────────┬────────┬───────┬───────┬──────┬──────┐
#   │     Model      │  Tool  │ Mode  │ Field │ Runs │ Need │
#   ├────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ gpt-5-2        │ cursor │ agent │ 3x4   │ 2    │ +1   │
#   ├────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ grok           │ cursor │ agent │ 3x4   │ 1    │ +2   │
#   ├────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ grok           │ cursor │ ask   │ 5x5   │ 2    │ +1   │
#   ├────────────────┼────────┼───────┼───────┼──────┼──────┤
#   │ gemini-3-flash │ cursor │ agent │ 7x7   │ 1    │ +2  
# Claude models (3x4 and 7x7 only, 3 iterations, agent mode)
# Agent mode = tools allowed; ask = --tools "" (read-only). Models in CLAUDE_AGENT_MODE_MODELS use agent.
CLAUDE_MODE="${CLAUDE_MODE:-ask}"
CLAUDE_AGENT_MODE_MODELS=(
    # "claude-opus-4-6"
    # "claude-sonnet-4-5-20250929"
    # "claude-haiku-4-5-20251001"
)
claude_MODELS=(
    # "claude-opus-4-6"
    # "claude-sonnet-4-5-20250929"
    # "claude-haiku-4-5-20251001"
)

# Cursor mode: "ask" (read-only, default) or "agent" (full agent). Models listed in
# CURSOR_AGENT_MODE_MODELS use agent mode; all others use CURSOR_MODE.
CURSOR_MODE="${CURSOR_MODE:-agent}"
# Models that should run in agent mode (no --mode ask). Add composer-* etc. as needed.
CURSOR_AGENT_MODE_MODELS=(
    # "opus-4.6"      
    # "composer-1"
    # "composer-1.5"
    # "gemini-3-flash"
    # "gpt-5.3-codex-xhigh"
    # "gpt-5.2"
    # "grok"
    "auto"
)

# Cursor models
# Note: For opus max mode with 1M context, you may need to configure Cursor settings
# separately to enable extended context mode.
# Composer: if "composer-1" fails, try "cursor-composer" or "composer" (see CURSOR_MODELS_GUIDE.md)
cursor_MODELS=(
    # "opus-4.6"                  # Standard Opus 4.6
    # "opus-4.6-thinking"          
    # "sonnet-4.5"
    "auto"
    # "opus-4.6" 
    # "grok"            # Cursor Auto model selection
    # "gpt-5.2"
    # "grok"
    # "gemini-3-flash"
    # "gpt-5.3-codex-xhigh"
)

# ==========================================
# BOARD SIZES
# ==========================================
# Format: ROWSxCOLS. Make sure corresponding template files exist in templates/
# This run: 3x4 and 7x7 only (for Claude agent-mode setup)
BOARD_SIZES=(
    "3x4"
    "5x5"
    "7x7"
)

# ==========================================
# TIMEOUTS (seconds)
# ==========================================
# Per-move timeout for each agent
TIMEOUTS=(
    360
)

# ==========================================
# TURN LIMITS
# ==========================================
# Maximum turns before game ends (prevents infinite games)
# Format: "SIZE:LIMIT" or "SIZE:unlimited" (only 3x4 and 7x7 used with current BOARD_SIZES)
TURN_LIMITS=(
    "3x4:unlimited"
    "7x7:10"
)

# ==========================================
# ITERATIONS
# ==========================================
# Number of times to run each configuration (for averaging). This run: 3.
ITERATIONS=3

# ==========================================
# NOTES
# ==========================================
# Total experiments = (tools) × (models per tool) × (board sizes) × (timeouts) × (iterations)
#
# Current config:
#   Claude: 4 models
#   Cursor: 7 models
#   Total: (4 + 7) × 4 board sizes × 4 timeouts × 5 iterations = 880 experiments
#
# Per tool:
#   Claude: 4 models × 4 boards × 4 timeouts × 5 iterations = 320 experiments
#   Cursor: 7 models × 4 boards × 4 timeouts × 5 iterations = 560 experiments
#
# Estimated time with 2-second delays:
#   Claude: ~640 seconds (~11 min) in delays + game time
#   Cursor: ~1120 seconds (~19 min) in delays + game time
#   Running in parallel: ~19 minutes of delays (Cursor takes longer)
#   Plus actual game time (varies by timeout and complexity)
#
# Note: opus-4.6-max may require additional Cursor configuration for 1M context
