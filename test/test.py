# SPDX-License-Identifier: Apache-2.0
#
# Cocotb verification for the 4x-scaled, colour-selectable version of:
#   tt_um_nobleg30_uart_vga_scroller
#
# ui_in mapping:
#   [1:0] scroll speed
#   [2]   pause
#   [3]   UART RX
#   [5:4] text colour:
#           00 white
#           01 yellow
#           10 cyan
#           11 magenta
#   [7:6] background colour:
#           00 black
#           01 dark blue
#           10 dark green
#           11 dark red
#
# Verifies an exact 32-character UART message and generates:
#   output/vga_32char_white_black_start.png
#   output/vga_32char_yellow_blue_end.png

import os
import struct
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer


CLK_PERIOD_PS = 39722
UART_CLKS_PER_BIT = 2622


# ============================================================================
# INPUT HELPERS
# ============================================================================

def make_ui(
    speed=0,
    pause=False,
    rx=1,
    text_color=0,
    bg_color=0,
):
    value = speed & 0x3

    if pause:
        value |= 1 << 2

    if rx:
        value |= 1 << 3

    value |= (text_color & 0x3) << 4
    value |= (bg_color & 0x3) << 6

    return value


def set_controls(
    dut,
    speed=0,
    pause=False,
    text_color=0,
    bg_color=0,
):
    dut.ui_in.value = make_ui(
        speed=speed,
        pause=pause,
        rx=1,
        text_color=text_color,
        bg_color=bg_color,
    )


def set_rx(dut, bit):
    value = int(dut.ui_in.value)

    if bit:
        value |= 1 << 3
    else:
        value &= ~(1 << 3)

    dut.ui_in.value = value


async def reset_dut(dut):
    dut.ena.value = 1
    dut.uio_in.value = 0

    set_controls(dut)

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


# ============================================================================
# UART
# ============================================================================

async def uart_send_byte(dut, value):
    set_rx(dut, 0)
    await ClockCycles(dut.clk, UART_CLKS_PER_BIT)

    for bit_index in range(8):
        set_rx(dut, (value >> bit_index) & 1)
        await ClockCycles(dut.clk, UART_CLKS_PER_BIT)

    set_rx(dut, 1)
    await ClockCycles(dut.clk, UART_CLKS_PER_BIT)

    await ClockCycles(dut.clk, 4)


async def uart_send_message(dut, text):
    for value in text.encode("ascii"):
        await uart_send_byte(dut, value)

    await uart_send_byte(dut, 0x0D)


# ============================================================================
# PNG WRITER
# ============================================================================

def png_chunk(chunk_type, data):
    payload = chunk_type + data
    crc = zlib.crc32(payload) & 0xFFFFFFFF

    return (
        struct.pack(">I", len(data))
        + payload
        + struct.pack(">I", crc)
    )


def write_png(filename, width, height, pixels):
    raw = bytearray()

    for y in range(height):
        raw.append(0)

        start = y * width
        end = start + width

        for red, green, blue in pixels[start:end]:
            raw.extend((red, green, blue))

    ihdr = struct.pack(
        ">IIBBBBB",
        width,
        height,
        8,
        2,
        0,
        0,
        0,
    )

    data = bytearray(b"\x89PNG\r\n\x1a\n")
    data += png_chunk(b"IHDR", ihdr)
    data += png_chunk(b"IDAT", zlib.compress(bytes(raw), level=9))
    data += png_chunk(b"IEND", b"")

    Path(filename).write_bytes(data)


# ============================================================================
# GOLDEN FONT
# ============================================================================

FONT = {
    " ": [
        "00000",
        "00000",
        "00000",
        "00000",
        "00000",
        "00000",
        "00000",
    ],
    "H": [
        "10001",
        "10001",
        "10001",
        "11111",
        "10001",
        "10001",
        "10001",
    ],
    "E": [
        "11111",
        "10000",
        "10000",
        "11110",
        "10000",
        "10000",
        "11111",
    ],
    "L": [
        "10000",
        "10000",
        "10000",
        "10000",
        "10000",
        "10000",
        "11111",
    ],
    "O": [
        "01110",
        "10001",
        "10001",
        "10001",
        "10001",
        "10001",
        "01110",
    ],
    "M": [
        "10001",
        "11011",
        "10101",
        "10101",
        "10001",
        "10001",
        "10001",
    ],
    "I": [
        "11111",
        "00100",
        "00100",
        "00100",
        "00100",
        "00100",
        "11111",
    ],
    "T": [
        "11111",
        "00100",
        "00100",
        "00100",
        "00100",
        "00100",
        "00100",
    ],
    "S": [
        "01111",
        "10000",
        "10000",
        "01110",
        "00001",
        "00001",
        "11110",
    ],
}


# ============================================================================
# COLOUR MODELS
# ============================================================================

TEXT_RGB222 = {
    0: (3, 3, 3),  # white
    1: (3, 3, 0),  # yellow
    2: (0, 3, 3),  # cyan
    3: (3, 0, 3),  # magenta
}

BG_RGB222 = {
    0: (0, 0, 0),  # black
    1: (0, 0, 1),  # dark blue
    2: (0, 1, 0),  # dark green
    3: (1, 0, 0),  # dark red
}


def rgb222_to_rgb888(rgb):
    return tuple(channel * 85 for channel in rgb)


def decode_rgb222(uo_value):
    red = (
        (((uo_value >> 0) & 1) << 1)
        | ((uo_value >> 4) & 1)
    )

    green = (
        (((uo_value >> 1) & 1) << 1)
        | ((uo_value >> 5) & 1)
    )

    blue = (
        (((uo_value >> 2) & 1) << 1)
        | ((uo_value >> 6) & 1)
    )

    return (red, green, blue)


# ============================================================================
# 4x GOLDEN PIXEL MODEL
# ============================================================================

def expected_text_on(
    message,
    x,
    y,
    left_x,
    top_y=224,
):
    # 32x32 character cells.
    if y < top_y or y >= top_y + 32:
        return False

    if x < left_x:
        return False

    if x >= left_x + 32 * len(message):
        return False

    rel_x = x - left_x
    rel_y = y - top_y

    char_index = rel_x // 32

    if char_index >= len(message):
        return False

    glyph_col = (rel_x % 32) // 4
    glyph_row = rel_y // 4

    # Same cell layout as the RTL:
    # glyph columns 1..5 contain the 5 font columns.
    if glyph_col < 1 or glyph_col > 5:
        return False

    # Row 7 is blank.
    if glyph_row > 6:
        return False

    character = message[char_index]

    return (
        FONT[character][glyph_row][glyph_col - 1]
        == "1"
    )


# ============================================================================
# FRAME CAPTURE / VERIFICATION
# ============================================================================

async def capture_frame(
    dut,
    message,
    left_x,
    text_color,
    bg_color,
    image_path,
):
    width = 640
    height = 480
    top_y = 224

    # Relationship is unchanged:
    # message_left = 640 - scroll_pos
    scroll_position = 640 - left_x

    set_controls(
        dut,
        speed=0,
        pause=True,
        text_color=text_color,
        bg_color=bg_color,
    )

    dut.user_project.scroll_pos.value = scroll_position

    await Timer(1, unit="ns")

    text_rgb222 = TEXT_RGB222[text_color]
    bg_rgb222 = BG_RGB222[bg_color]

    text_rgb888 = rgb222_to_rgb888(text_rgb222)
    bg_rgb888 = rgb222_to_rgb888(bg_rgb222)

    # Full active frame is the selected background colour.
    pixels = [bg_rgb888] * (width * height)

    # Verify several ordinary background pixels first.
    background_points = [
        (20, 20),
        (620, 20),
        (20, 450),
        (620, 450),
    ]

    for x, y in background_points:
        dut.user_project.vga_inst.h_count.value = x
        dut.user_project.vga_inst.v_count.value = y

        await ReadOnly()

        actual = decode_rgb222(int(dut.uo_out.value))

        assert actual == bg_rgb222, (
            f"Background colour mismatch at ({x},{y}): "
            f"expected {bg_rgb222}, got {actual}"
        )

        await Timer(1, unit="ns")

    sample_x0 = max(0, left_x - 8)
    sample_x1 = min(
        width - 1,
        left_x + 32 * len(message) + 8,
    )

    sample_y0 = top_y - 4
    sample_y1 = top_y + 35

    mismatches = []
    text_pixels = []

    for y in range(sample_y0, sample_y1 + 1):
        for x in range(sample_x0, sample_x1 + 1):
            dut.user_project.vga_inst.h_count.value = x
            dut.user_project.vga_inst.v_count.value = y

            await ReadOnly()

            actual_rgb222 = decode_rgb222(
                int(dut.uo_out.value)
            )

            expected_on = expected_text_on(
                message,
                x,
                y,
                left_x=left_x,
                top_y=top_y,
            )

            expected_rgb222 = (
                text_rgb222
                if expected_on
                else bg_rgb222
            )

            pixels[y * width + x] = rgb222_to_rgb888(
                actual_rgb222
            )

            if expected_on:
                text_pixels.append((x, y))

            if actual_rgb222 != expected_rgb222:
                mismatches.append(
                    (
                        x,
                        y,
                        expected_rgb222,
                        actual_rgb222,
                    )
                )

            await Timer(1, unit="ns")

    write_png(
        image_path,
        width,
        height,
        pixels,
    )

    assert len(text_pixels) > 800, (
        f"Too few expected 4x text pixels in {image_path}"
    )

    if mismatches:
        preview = "\n".join(
            (
                f"x={x}, y={y}, "
                f"expected={expected}, actual={actual}"
            )
            for x, y, expected, actual
            in mismatches[:20]
        )

        raise AssertionError(
            f"{len(mismatches)} pixel mismatch(es) "
            f"in {image_path}\n{preview}"
        )

    dut._log.info(
        "Verified and saved %s",
        image_path,
    )


# ============================================================================
# MAIN TEST
# ============================================================================

@cocotb.test()
async def test_uart_vga_scroller_4x_colour(dut):
    clock = Clock(
        dut.clk,
        CLK_PERIOD_PS,
        unit="ps",
    )

    clock.start()

    # ------------------------------------------------------------------------
    # Reset and unused UIO
    # ------------------------------------------------------------------------
    await reset_dut(dut)

    assert int(dut.uio_out.value) == 0
    assert int(dut.uio_oe.value) == 0

    # ------------------------------------------------------------------------
    # External HSYNC timing check. This remains gate-level compatible.
    # ------------------------------------------------------------------------
    await ClockCycles(dut.clk, 654)
    await Timer(10, unit="ns")

    assert (
        (int(dut.uo_out.value) >> 7) & 1
    ) == 0, "HSYNC should be low at x=656"

    await ClockCycles(dut.clk, 96)
    await Timer(10, unit="ns")

    assert (
        (int(dut.uo_out.value) >> 7) & 1
    ) == 1, "HSYNC should return high at x=752"

    if os.getenv("GATES", "no") == "yes":
        dut._log.info(
            "Gate-level external VGA timing test passed."
        )
        return

    # ------------------------------------------------------------------------
    # UART message
    # ------------------------------------------------------------------------
    await reset_dut(dut)

    # Exactly 32 supported characters.
    message = "HELLO MITS HELLO MITS HELLO MITS"
    assert len(message) == 32

    await uart_send_message(
        dut,
        message,
    )

    await ClockCycles(dut.clk, 8)

    assert int(
        dut.user_project.msg_len.value
    ) == len(message)

    assert int(
        dut.user_project.write_ptr.value
    ) == 0

    assert int(
        dut.user_project.scroll_pos.value
    ) == 0

    # ------------------------------------------------------------------------
    # Scroll speed is preserved.
    # ------------------------------------------------------------------------
    set_controls(
        dut,
        speed=1,
        pause=False,
        text_color=0,
        bg_color=0,
    )

    dut.user_project.vga_inst.h_count.value = 799
    dut.user_project.vga_inst.v_count.value = 524

    await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    await ReadOnly()

    assert int(
        dut.user_project.scroll_pos.value
    ) == 2

    await Timer(1, unit="ns")

    # ------------------------------------------------------------------------
    # Pause is preserved.
    # ------------------------------------------------------------------------
    set_controls(
        dut,
        speed=3,
        pause=True,
        text_color=0,
        bg_color=0,
    )

    dut.user_project.vga_inst.h_count.value = 799
    dut.user_project.vga_inst.v_count.value = 524

    await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    await ReadOnly()

    assert int(
        dut.user_project.scroll_pos.value
    ) == 2

    await Timer(1, unit="ns")

    # ------------------------------------------------------------------------
    # Stop clock for deterministic manual VGA-coordinate sampling.
    # ------------------------------------------------------------------------
    clock.stop()

    output_dir = Path("output")
    output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    # ------------------------------------------------------------------------
    # Frame 1: beginning of the 32-character message.
    # White text on black background.
    #
    # Total message width = 32 x 32 = 1024 pixels, so only part of the
    # full message is visible on the 640-pixel display at one time.
    # ------------------------------------------------------------------------
    await capture_frame(
        dut,
        message,
        left_x=200,
        text_color=0,
        bg_color=0,
        image_path=(
            output_dir
            / "vga_32char_white_black_start.png"
        ),
    )

    # ------------------------------------------------------------------------
    # Frame 2: later scroll position so the end of the 32-character
    # message is visible.  The left edge is off-screen by 384 pixels:
    #
    #   -384 + 1024 = 640
    #
    # Yellow text on dark-blue background.
    # ------------------------------------------------------------------------
    await capture_frame(
        dut,
        message,
        left_x=-384,
        text_color=1,
        bg_color=1,
        image_path=(
            output_dir
            / "vga_32char_yellow_blue_end.png"
        ),
    )

    dut._log.info(
        "PASS: exact 32-character UART buffer, 4x scaling, scrolling, "
        "pause, text colour and background colour verified."
    )
