#!/usr/bin/env python3
"""
Generate 6 animated GIFs illustrating BALDA game rules for an article.
Each GIF uses a 5x5 board starting with "AGENT" in row 2.

Words used are real examples from benchmark runs: RAGE, DENT, etc.

Design:
- Board on the left, side panel on the right showing word being formed + word list
- Path cells highlighted with connector lines between them
- Two valid turns then one invalid turn per GIF (where applicable)
- No caption bars — the animation speaks for itself

Usage:
  python scripts/generate_rule_gifs.py
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = Path(__file__).resolve().parent.parent / "docs"

# Layout
CELL = 60
PAD = 24
SIDE_W = 180  # side panel width
FONT_SIZE = 22
SIDE_FONT_SIZE = 16
SMALL_FONT_SIZE = 13
FRAME_MS = 150

# Colors
BG = (254, 254, 254)
EMPTY_FILL = (232, 232, 232)
EMPTY_BORDER = (189, 189, 189)
LETTER_FILL = (255, 255, 255)
LETTER_BORDER = (158, 158, 158)
PATH_COLOR = (33, 150, 243)       # blue
NEW_COLOR = (76, 175, 80)         # green
ERROR_COLOR = (244, 67, 54)       # red
YELLOW_COLOR = (255, 193, 7)      # amber highlight
VALID_COLOR = (76, 175, 80)       # same as NEW
MUTED = (140, 140, 140)
DARK = (40, 40, 40)


def load_fonts():
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", FONT_SIZE)
        side_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", SIDE_FONT_SIZE)
        small_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", SMALL_FONT_SIZE)
        big_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 36)
        word_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    except Exception:
        font = ImageFont.load_default()
        side_font = font
        small_font = font
        big_font = font
        word_font = font
    return font, side_font, small_font, big_font, word_font


FONT, SIDE_FONT, SMALL_FONT, BIG_FONT, WORD_FONT = load_fonts()


def initial_board():
    """5x5 board with AGENT in row 2 (0-indexed)."""
    return [
        [".", ".", ".", ".", "."],
        [".", ".", ".", ".", "."],
        ["A", "G", "E", "N", "T"],
        [".", ".", ".", ".", "."],
        [".", ".", ".", ".", "."],
    ]


def copy_board(b):
    return [row[:] for row in b]


def img_size():
    w = 5 * CELL + 2 * PAD + SIDE_W
    h = 5 * CELL + 2 * PAD
    return w, h


def cell_center(r, c, x0=PAD, y0=PAD):
    return x0 + c * CELL + CELL // 2, y0 + r * CELL + CELL // 2


def draw_board(draw, board, x0=PAD, y0=PAD, highlights=None, path_cells=None,
               new_letter_cell=None):
    highlights = highlights or {}
    path_cells = path_cells or []
    rows, cols = len(board), len(board[0])
    for r in range(rows):
        for c in range(cols):
            x = x0 + c * CELL
            y = y0 + r * CELL
            ch = board[r][c]
            if (r, c) in highlights:
                fill = highlights[(r, c)]
                border = _darken(fill, 30)
            elif (r, c) == new_letter_cell:
                fill = NEW_COLOR
                border = _darken(NEW_COLOR, 30)
            elif (r, c) in path_cells:
                fill = PATH_COLOR
                border = _darken(PATH_COLOR, 30)
            elif ch == ".":
                fill = EMPTY_FILL
                border = EMPTY_BORDER
            else:
                fill = LETTER_FILL
                border = LETTER_BORDER
            draw.rectangle([x, y, x + CELL - 1, y + CELL - 1], fill=fill,
                           outline=border, width=2)
            if ch != ".":
                bbox = draw.textbbox((0, 0), ch, font=FONT)
                tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
                tx = x + (CELL - tw) // 2
                ty = y + (CELL - th) // 2
                bright = fill in (ERROR_COLOR, PATH_COLOR, NEW_COLOR, YELLOW_COLOR)
                text_color = (255, 255, 255) if bright else DARK
                draw.text((tx, ty), ch, fill=text_color, font=FONT)

    # Draw connector lines between consecutive path cells
    if len(path_cells) >= 2:
        for i in range(len(path_cells) - 1):
            cx1, cy1 = cell_center(*path_cells[i], x0, y0)
            cx2, cy2 = cell_center(*path_cells[i + 1], x0, y0)
            dx, dy = cx2 - cx1, cy2 - cy1
            mag = max(abs(dx), abs(dy))
            if mag == 0:
                continue
            ux, uy = dx / mag, dy / mag
            sx = cx1 + ux * (CELL // 2 - 4)
            sy = cy1 + uy * (CELL // 2 - 4)
            ex = cx2 - ux * (CELL // 2 - 4)
            ey = cy2 - uy * (CELL // 2 - 4)
            draw.line([(sx, sy), (ex, ey)], fill=(100, 100, 100), width=2)


def _darken(color, amount):
    return tuple(max(0, c - amount) for c in color)


def draw_side_panel(draw, x0, y0, word_list=None, current_word=None,
                    current_word_color=DARK, status=None, status_color=DARK):
    y = y0
    draw.text((x0, y), "Words:", fill=MUTED, font=SIDE_FONT)
    y += 24
    if word_list:
        for w, color in word_list:
            draw.text((x0 + 4, y), w, fill=color, font=SIDE_FONT)
            y += 22
    else:
        draw.text((x0 + 4, y), "(none)", fill=MUTED, font=SMALL_FONT)
        y += 22

    y += 16
    if current_word is not None:
        draw.text((x0, y), "Current:", fill=MUTED, font=SIDE_FONT)
        y += 24
        draw.text((x0 + 4, y), current_word, fill=current_word_color, font=WORD_FONT)
        y += 28

    if status:
        y += 8
        for line in status.split("\n"):
            draw.text((x0, y), line, fill=status_color, font=WORD_FONT)
            y += 24


def make_frame(board, word_list=None, current_word=None,
               current_word_color=DARK, status=None, status_color=DARK,
               highlights=None, path_cells=None, new_letter_cell=None,
               extra_draw=None, img_w=None, img_h=None):
    if img_w is None or img_h is None:
        img_w, img_h = img_size()
    img = Image.new("RGB", (img_w, img_h), BG)
    d = ImageDraw.Draw(img)
    draw_board(d, board, highlights=highlights, path_cells=path_cells,
               new_letter_cell=new_letter_cell)
    side_x = 5 * CELL + 2 * PAD + 16
    draw_side_panel(d, side_x, PAD, word_list=word_list,
                    current_word=current_word,
                    current_word_color=current_word_color,
                    status=status, status_color=status_color)
    if extra_draw:
        extra_draw(d, img)
    return img


def repeat_frame(frame, count):
    return [frame.copy() for _ in range(count)]


def save_gif(frames, durations, path):
    if isinstance(durations, int):
        durations = [durations] * len(frames)
    frames[0].save(
        path, save_all=True, append_images=frames[1:],
        duration=durations, loop=0,
    )
    print(f"  Wrote {path} ({len(frames)} frames)")


# ─── Standard turns used across GIFs ─────────────────────────────────────
# Turn 1: RAGE — place R at (1,0), path R(1,0)→A(2,0)→G(2,1)→E(2,2)
# Turn 2: DENT — place D at (3,2), path D(3,2)→E(2,2)→N(2,3)→T(2,4)
#
# Board after turn 1:         Board after turn 2:
# . . . . .                   . . . . .
# R . . . .                   R . . . .
# A G E N T                   A G E N T
# . . . . .                   . . D . .
# . . . . .                   . . . . .

TURN1 = {"cell": (1, 0), "letter": "R", "word": "RAGE",
         "path": [(1, 0), (2, 0), (2, 1), (2, 2)]}
TURN2 = {"cell": (3, 2), "letter": "D", "word": "DENT",
         "path": [(3, 2), (2, 2), (2, 3), (2, 4)]}


def animate_turn(board, turn, word_list, is_error=False):
    """
    Animate a single turn:
    1. Highlight target cell (yellow)
    2. Place letter (green)
    3. Animate path cell by cell, showing word building
    4. Show result (green check or red X)

    Returns (frames, durations, updated_board, updated_word_list).
    """
    new_cell = turn["cell"]
    new_letter = turn["letter"]
    word = turn["word"]
    path = turn["path"]

    frames = []
    durations = []
    board = copy_board(board)

    # Step 1: highlight empty cell
    frames.append(make_frame(board, word_list=word_list,
                             highlights={new_cell: YELLOW_COLOR}))
    durations.append(500)

    # Step 2: place letter
    r, c = new_cell
    board[r][c] = new_letter
    frames.append(make_frame(board, word_list=word_list,
                             new_letter_cell=new_cell))
    durations.append(500)

    # Step 3: animate path cell by cell, building word
    for i in range(1, len(path) + 1):
        frames.append(make_frame(
            board, word_list=word_list,
            current_word=word[:i], current_word_color=PATH_COLOR,
            path_cells=path[:i], new_letter_cell=new_cell,
        ))
        durations.append(350)

    # Step 4: result
    if is_error:
        err_hl = {(pr, pc): ERROR_COLOR for pr, pc in path}
        err_hl[new_cell] = ERROR_COLOR
        err_frame = make_frame(
            board, word_list=word_list,
            current_word=word, current_word_color=ERROR_COLOR,
            status="✗ INVALID", status_color=ERROR_COLOR,
            highlights=err_hl,
        )
        frames.extend(repeat_frame(err_frame, 20))
        durations.extend([FRAME_MS] * 20)
    else:
        ok_frame = make_frame(
            board, word_list=word_list,
            current_word=word, current_word_color=VALID_COLOR,
            status="✓ Valid", status_color=VALID_COLOR,
            path_cells=path, new_letter_cell=new_cell,
        )
        frames.extend(repeat_frame(ok_frame, 6))
        durations.extend([FRAME_MS] * 6)

        word_list = list(word_list or [])
        word_list.append((word, VALID_COLOR))
        frames.append(make_frame(board, word_list=word_list))
        durations.append(600)

    return frames, durations, board, word_list


def two_valid_turns(board):
    """Run standard two valid turns (RAGE, DENT). Returns frames, durations, board, word_list."""
    frames = []
    durations = []
    word_list = []

    f, d, board, word_list = animate_turn(board, TURN1, word_list)
    frames += f; durations += d

    f, d, board, word_list = animate_turn(board, TURN2, word_list)
    frames += f; durations += d

    return frames, durations, board, word_list


# ─── GIF 1: Single Letter Placement ──────────────────────────────────────

def gif1():
    """One letter per turn, must be placed on an empty cell."""
    frames, durations, board, word_list = two_valid_turns(initial_board())

    # Turn 3 (invalid): try to place on (2,2) which already has E
    board_copy = copy_board(board)
    frames.append(make_frame(board_copy, word_list=word_list,
                             highlights={(2, 2): YELLOW_COLOR},
                             status="Placing on (2,2)...", status_color=MUTED))
    durations.append(600)

    err_frame = make_frame(board_copy, word_list=word_list,
                           highlights={(2, 2): ERROR_COLOR},
                           status="✗ Cell occupied!", status_color=ERROR_COLOR)
    frames.extend(repeat_frame(err_frame, 20))
    durations.extend([FRAME_MS] * 20)

    save_gif(frames, durations, OUT_DIR / "gif1_letter_placement.gif")


# ─── GIF 2: Word Path Must Include New Letter ────────────────────────────

def gif2():
    """New letter must be part of the word path."""
    frames, durations, board, word_list = two_valid_turns(initial_board())

    # Turn 3 (invalid): Place T at (4,3), try to claim word TENT
    # TENT needs path through E(2,2)→N(2,3)→T(2,4) — new T at (4,3) NOT in path
    board_inv = copy_board(board)
    board_inv[4][3] = "T"

    frames.append(make_frame(board_inv, word_list=word_list,
                             new_letter_cell=(4, 3)))
    durations.append(600)

    # Show path tracing through existing letters: E→N→T (the word needs T-E-N-T
    # but new T at (4,3) is far from the path)
    bad_path = [(2, 2), (2, 3), (2, 4)]
    word_letters = "ENT"
    for i in range(1, len(bad_path) + 1):
        frames.append(make_frame(
            board_inv, word_list=word_list,
            current_word="T" + word_letters[:i], current_word_color=PATH_COLOR,
            path_cells=bad_path[:i], new_letter_cell=(4, 3),
        ))
        durations.append(300)

    err_hl = {(r, c): ERROR_COLOR for r, c in bad_path}
    err_hl[(4, 3)] = YELLOW_COLOR  # T highlighted but not in path
    err_frame = make_frame(
        board_inv, word_list=word_list,
        current_word="TENT", current_word_color=ERROR_COLOR,
        status="✗ New letter not\nin path!", status_color=ERROR_COLOR,
        highlights=err_hl,
    )
    frames.extend(repeat_frame(err_frame, 20))
    durations.extend([FRAME_MS] * 20)

    save_gif(frames, durations, OUT_DIR / "gif2_path_must_include_letter.gif")


# ─── GIF 3: No Diagonal Movement ─────────────────────────────────────────

def gif3():
    """Path must use orthogonal (up/down/left/right) steps only."""
    frames, durations, board, word_list = two_valid_turns(initial_board())

    # Turn 3 (invalid): Place K at (3,1), attempt diagonal to E(2,2)
    board_inv = copy_board(board)
    board_inv[3][1] = "K"

    frames.append(make_frame(board_inv, word_list=word_list,
                             new_letter_cell=(3, 1)))
    durations.append(600)

    # Show K highlighted as start of path
    frames.append(make_frame(
        board_inv, word_list=word_list,
        current_word="K", current_word_color=PATH_COLOR,
        path_cells=[(3, 1)], new_letter_cell=(3, 1),
    ))
    durations.append(400)

    # Diagonal attempt: K(3,1) → E(2,2) — row AND col change = diagonal!
    def draw_diagonal_line(d, img):
        cx1, cy1 = cell_center(3, 1)
        cx2, cy2 = cell_center(2, 2)
        d.line([(cx1, cy1), (cx2, cy2)], fill=ERROR_COLOR, width=3)
        mx, my = (cx1 + cx2) // 2, (cy1 + cy2) // 2
        d.text((mx - 12, my - 18), "✗", fill=ERROR_COLOR, font=BIG_FONT)

    err_frame = make_frame(
        board_inv, word_list=word_list,
        current_word="KE...", current_word_color=ERROR_COLOR,
        status="✗ Diagonal move!", status_color=ERROR_COLOR,
        highlights={(3, 1): ERROR_COLOR, (2, 2): ERROR_COLOR},
        extra_draw=draw_diagonal_line,
    )
    frames.extend(repeat_frame(err_frame, 20))
    durations.extend([FRAME_MS] * 20)

    save_gif(frames, durations, OUT_DIR / "gif3_no_diagonal.gif")


# ─── GIF 4: No Cell Reuse ────────────────────────────────────────────────

def gif4():
    """Each cell can only be visited once in a path."""
    frames, durations, board, word_list = two_valid_turns(initial_board())

    # Turn 3 (invalid): Place O at (3,1), attempt O→G→E→G (revisit G at (2,1))
    # Path: O(3,1)→G(2,1)→E(2,2)→G(2,1) — (2,1) visited twice!
    board_inv = copy_board(board)
    board_inv[3][1] = "O"

    frames.append(make_frame(board_inv, word_list=word_list,
                             new_letter_cell=(3, 1)))
    durations.append(600)

    attempt_path = [(3, 1), (2, 1), (2, 2)]
    for i in range(1, len(attempt_path) + 1):
        frames.append(make_frame(
            board_inv, word_list=word_list,
            current_word="OGE"[:i], current_word_color=PATH_COLOR,
            path_cells=attempt_path[:i], new_letter_cell=(3, 1),
        ))
        durations.append(400)

    # Try to revisit (2,1) — error!
    err_hl = {(3, 1): PATH_COLOR, (2, 2): PATH_COLOR, (2, 1): ERROR_COLOR}
    err_frame = make_frame(
        board_inv, word_list=word_list,
        current_word="OGEG?", current_word_color=ERROR_COLOR,
        status="✗ Cell already\nvisited!", status_color=ERROR_COLOR,
        highlights=err_hl,
    )
    frames.extend(repeat_frame(err_frame, 20))
    durations.extend([FRAME_MS] * 20)

    save_gif(frames, durations, OUT_DIR / "gif4_no_cell_reuse.gif")


# ─── GIF 5: No Repeated Words ────────────────────────────────────────────

def gif5():
    """A word that was already used cannot be submitted again."""
    frames, durations, board, word_list = two_valid_turns(initial_board())

    # Turn 3 (invalid): Place E at (3,1), attempt RAGE again
    # Path: R(1,0)→A(2,0)→G(2,1)→E(3,1) — all orthogonal, but RAGE already used!
    board_inv = copy_board(board)
    board_inv[3][1] = "E"
    dup_path = [(1, 0), (2, 0), (2, 1), (3, 1)]

    frames.append(make_frame(board_inv, word_list=word_list,
                             new_letter_cell=(3, 1)))
    durations.append(600)

    for i in range(1, len(dup_path) + 1):
        frames.append(make_frame(
            board_inv, word_list=word_list,
            current_word="RAGE"[:i], current_word_color=PATH_COLOR,
            path_cells=dup_path[:i], new_letter_cell=(3, 1),
        ))
        durations.append(350)

    # Error: RAGE already in word list
    err_word_list = [(w, ERROR_COLOR if w == "RAGE" else c)
                     for w, c in word_list]
    err_hl = {(r, c): ERROR_COLOR for r, c in dup_path}
    err_frame = make_frame(
        board_inv, word_list=err_word_list,
        current_word="RAGE", current_word_color=ERROR_COLOR,
        status="✗ Already used!", status_color=ERROR_COLOR,
        highlights=err_hl,
    )
    frames.extend(repeat_frame(err_frame, 20))
    durations.extend([FRAME_MS] * 20)

    save_gif(frames, durations, OUT_DIR / "gif5_no_repeated_words.gif")


# ─── GIF 6: Format Failure ───────────────────────────────────────────────

def gif6():
    """Model output must match exact format — no extra text or markdown."""
    frames = []
    durations = []

    img_w = 520
    img_h = 360

    def draw_format_box(d, x, y, w, h, title, lines, title_color, line_color,
                        border_color=None):
        border_color = border_color or title_color
        d.rectangle([x, y, x + w, y + h], fill=BG, outline=border_color, width=2)
        d.text((x + 8, y + 6), title, fill=title_color, font=SIDE_FONT)
        for i, line in enumerate(lines):
            d.text((x + 16, y + 30 + i * 18), line, fill=line_color, font=SMALL_FONT)

    # Frame 1: correct format (using RAGE example from benchmarks)
    correct = ["1 0 R", "RAGE", "1,0 2,0 2,1 2,2"]
    img1 = Image.new("RGB", (img_w, img_h), BG)
    d1 = ImageDraw.Draw(img1)
    draw_format_box(d1, 20, 20, img_w - 40, 110, "✓ Correct format",
                    correct, VALID_COLOR, VALID_COLOR, VALID_COLOR)
    d1.text((20, 160), "Line 1: row col letter", fill=MUTED, font=SMALL_FONT)
    d1.text((20, 180), "Line 2: word", fill=MUTED, font=SMALL_FONT)
    d1.text((20, 200), "Line 3: path as row,col pairs", fill=MUTED, font=SMALL_FONT)
    frames.append(img1)
    durations.append(3000)

    # Frame 2: wrong format (verbose model output)
    wrong = [
        'I\'ll place "R" at row 1, col 0',
        "forming the word RAGE.",
        "",
        "```",
        "1 0 R",
        "RAGE",
        "1,0 2,0 2,1 2,2",
        "```",
    ]
    img2 = Image.new("RGB", (img_w, img_h), BG)
    d2 = ImageDraw.Draw(img2)
    draw_format_box(d2, 20, 20, img_w - 40, 200, "Model output",
                    wrong, DARK, (120, 80, 80), MUTED)
    d2.text((20, 240), "Extra text + markdown wrapping", fill=MUTED, font=SMALL_FONT)
    d2.text((20, 260), "→ parser cannot extract the move", fill=ERROR_COLOR, font=SMALL_FONT)
    frames.append(img2)
    durations.append(3000)

    # Frame 3: error flash — REJECTED
    img3 = Image.new("RGB", (img_w, img_h), (255, 242, 240))
    d3 = ImageDraw.Draw(img3)
    draw_format_box(d3, 20, 20, img_w - 40, 200, "✗ REJECTED",
                    wrong, ERROR_COLOR, ERROR_COLOR, ERROR_COLOR)
    d3.line([(30, 30), (img_w - 30, 210)], fill=ERROR_COLOR, width=4)
    d3.line([(img_w - 30, 30), (30, 210)], fill=ERROR_COLOR, width=4)
    d3.text((20, 240), "Parse failure → move skipped",
            fill=ERROR_COLOR, font=SIDE_FONT)
    frames.extend(repeat_frame(img3, 20))
    durations.extend([FRAME_MS] * 20)

    save_gif(frames, durations, OUT_DIR / "gif6_format_failure.gif")


# ─── Main ────────────────────────────────────────────────────────────────

def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Generating rule illustration GIFs...")
    gif1()
    gif2()
    gif3()
    gif4()
    gif5()
    gif6()
    print("Done! All GIFs saved to", OUT_DIR)


if __name__ == "__main__":
    main()
