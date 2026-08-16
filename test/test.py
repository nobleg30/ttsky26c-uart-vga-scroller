# SPDX-License-Identifier: Apache-2.0
#
# Functional verification for:
# tt_um_nobleg30_uart_vga_scroller
#
# This test:
#   1. Checks reset and unused UIO pins.
#   2. Checks VGA HSYNC timing.
#   3. Runs the external-pin check in gate-level simulation.
#   4. Sends "HELLO MITS" through the actual UART RX input in RTL simulation.
#   5. Checks message length, Enter handling, scroll speed, and pause.
#   6. Verifies the VGA pixels against an independent golden 5x7 font model.
#   7. Generates two 640x480 PNG frames:
#
#        output/vga_hello_mits_frame1.png
#        output/vga_hello_mits_frame2.png
#
#      Frame 1: message left edge at x = 200
#      Frame 2: message left edge at x = 120
#
# The image-generation portion is RTL-only because it intentionally accesses
# internal RTL state to place the message at convenient visible locations.

import os
import struct
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer


# ============================================================================
# CLOCK / UART SETTINGS
# ============================================================================

# Integer picoseconds avoid Icarus precision errors.
# 39.722 ns is approximately 25.175 MHz.
CLK_PERIOD_PS = 39722

# Must match the clean RTL UART receiver.
UART_CLKS_PER_BIT = 2622


# ============================================================================
# INPUT CONTROL HELPERS
# ============================================================================

def set_rx(dut, bit):
    """
    Drive UART RX on ui_in[3] without changing the other ui_in bits.
    """
    value = int(dut.ui_in.value)

    if bit:
        value |= (1 << 3)
    else:
        value &= ~(1 << 3)

    dut.ui_in.value = value


def set_controls(dut, speed=0, pause=False):
    """
    ui_in[1:0] = scroll speed
    ui_in[2]   = pause
    ui_in[3]   = UART RX, idle high
    """
    value = speed & 0x3

    if pause:
        value |= (1 << 2)

    # UART idle state is logic 1.
    value |= (1 << 3)

    dut.ui_in.value = value


async def reset_dut(dut):
    """
    Reset DUT while holding UART RX in idle-high state.
    """
    dut.ena.value = 1
    dut.uio_in.value = 0

    set_controls(
        dut,
        speed=0,
        pause=False,
    )

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


# ============================================================================
# UART TRANSMISSION HELPERS
# ============================================================================

async def uart_send_byte(dut, value):
    """
    Send one byte as UART 9600-baud 8-N-1.

    Transmission order:
        start bit
        bit 0
        bit 1
        ...
        bit 7
        stop bit
    """

    # Start bit
    set_rx(dut, 0)
    await ClockCycles(
        dut.clk,
        UART_CLKS_PER_BIT,
    )

    # 8 data bits, LSB first
    for bit_index in range(8):

        set_rx(
            dut,
            (value >> bit_index) & 1,
        )

        await ClockCycles(
            dut.clk,
            UART_CLKS_PER_BIT,
        )

    # Stop bit
    set_rx(dut, 1)

    await ClockCycles(
        dut.clk,
        UART_CLKS_PER_BIT,
    )

    # Small idle gap
    await ClockCycles(
        dut.clk,
        4,
    )


async def uart_send_message(dut, text):
    """
    Send an ASCII message followed by carriage return.
    """

    for byte_value in text.encode("ascii"):

        await uart_send_byte(
            dut,
            byte_value,
        )

    # Enter / carriage return
    await uart_send_byte(
        dut,
        0x0D,
    )


# ============================================================================
# MINIMAL PNG WRITER
#
# No Pillow dependency is required.
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
    """
    Write RGB888 PNG.

    pixels:
        flat list of (R,G,B) tuples in row-major order.
    """

    raw = bytearray()

    for y in range(height):

        # PNG filter type 0
        raw.append(0)

        row_start = y * width
        row_end = row_start + width

        for red, green, blue in pixels[row_start:row_end]:

            raw.extend(
                (
                    red,
                    green,
                    blue,
                )
            )

    ihdr = struct.pack(
        ">IIBBBBB",
        width,
        height,
        8,    # 8 bits/channel
        2,    # RGB truecolour
        0,
        0,
        0,
    )

    png_data = bytearray(
        b"\x89PNG\r\n\x1a\n"
    )

    png_data += png_chunk(
        b"IHDR",
        ihdr,
    )

    png_data += png_chunk(
        b"IDAT",
        zlib.compress(
            bytes(raw),
            level=9,
        ),
    )

    png_data += png_chunk(
        b"IEND",
        b"",
    )

    Path(filename).write_bytes(
        png_data
    )


# ============================================================================
# INDEPENDENT GOLDEN 5x7 FONT
#
# Only the characters required for "HELLO MITS" are included here.
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
# GOLDEN PIXEL MODEL
# ============================================================================

def expected_text_pixel(
    message,
    x,
    y,
    left_x,
    top_y=232,
):
    """
    Golden model of the RTL text renderer.

    Character cell:
        16 x 16 pixels

    Font:
        5 x 7

    Scale:
        2 x

    Therefore:
        visible glyph width  = 10 pixels
        visible glyph height = 14 pixels

    The RTL uses glyph columns 1..5 of the 8-column-scaled character cell.
    """

    # Outside text cell vertically
    if y < top_y:
        return False

    if y >= top_y + 16:
        return False

    # Outside complete message horizontally
    if x < left_x:
        return False

    if x >= left_x + (16 * len(message)):
        return False

    rel_x = x - left_x
    rel_y = y - top_y

    char_index = rel_x // 16

    if char_index >= len(message):
        return False

    character = message[char_index]

    glyph_col = (
        (rel_x % 16) // 2
    )

    glyph_row = (
        rel_y // 2
    )

    # RTL uses columns 1 through 5.
    if glyph_col < 1:
        return False

    if glyph_col > 5:
        return False

    # Row 7 is blank.
    if glyph_row > 6:
        return False

    return (
        FONT[character][glyph_row][glyph_col - 1]
        == "1"
    )


# ============================================================================
# TinyVGA RGB222 DECODER
# ============================================================================

def decode_rgb222(uo_value):
    """
    RTL pin mapping:

        uo[0] = R1
        uo[4] = R0

        uo[1] = G1
        uo[5] = G0

        uo[2] = B1
        uo[6] = B0

    Converts each 2-bit channel (0..3) to 8-bit (0..255).
    """

    red_2bit = (
        (((uo_value >> 0) & 1) << 1)
        |
        ((uo_value >> 4) & 1)
    )

    green_2bit = (
        (((uo_value >> 1) & 1) << 1)
        |
        ((uo_value >> 5) & 1)
    )

    blue_2bit = (
        (((uo_value >> 2) & 1) << 1)
        |
        ((uo_value >> 6) & 1)
    )

    return (
        red_2bit * 85,
        green_2bit * 85,
        blue_2bit * 85,
    )


# ============================================================================
# RENDER AND VERIFY ONE VGA FRAME
# ============================================================================

async def render_and_verify_frame(
    dut,
    message,
    left_x,
    image_path,
):
    """
    Force a convenient scrolling position, sample the actual RGB outputs,
    compare every sampled text-region pixel against the independent golden
    font model, and write a complete 640x480 PNG.
    """

    width = 640
    height = 480

    top_y = 232

    # RTL relationship:
    #
    # message_left = 640 - scroll_pos
    #
    # Therefore:
    #
    # scroll_pos = 640 - desired_left_x

    scroll_position = 640 - left_x

    dut.user_project.scroll_pos.value = (
        scroll_position
    )

    await Timer(
        1,
        unit="ns",
    )

    # Entire frame defaults to black.
    pixels = [
        (0, 0, 0)
    ] * (
        width * height
    )

    # Only the text region needs to be simulated pixel-by-pixel.
    # Add 10-pixel margins around the message.
    sample_x0 = max(
        0,
        left_x - 10,
    )

    sample_x1 = min(
        width - 1,
        left_x
        + (16 * len(message))
        + 10,
    )

    sample_y0 = (
        top_y - 4
    )

    sample_y1 = (
        top_y + 19
    )

    mismatches = []
    lit_pixels = []

    dut._log.info(
        "Rendering %s with message left edge at x=%d "
        "(scroll_pos=%d)",
        image_path,
        left_x,
        scroll_position,
    )

    for y in range(
        sample_y0,
        sample_y1 + 1,
    ):

        for x in range(
            sample_x0,
            sample_x1 + 1,
        ):

            # Directly select a VGA coordinate.
            dut.user_project.vga_inst.h_count.value = x
            dut.user_project.vga_inst.v_count.value = y

            # Let all continuous/combinational RTL settle.
            await ReadOnly()

            uo_value = int(
                dut.uo_out.value
            )

            rgb = decode_rgb222(
                uo_value
            )

            pixels[
                y * width + x
            ] = rgb

            actual_on = (
                rgb != (0, 0, 0)
            )

            expected_on = expected_text_pixel(
                message,
                x,
                y,
                left_x=left_x,
                top_y=top_y,
            )

            if actual_on:

                lit_pixels.append(
                    (x, y)
                )

            if actual_on != expected_on:

                mismatches.append(
                    (
                        x,
                        y,
                        expected_on,
                        actual_on,
                        uo_value,
                    )
                )

            # ReadOnly ends the current simulator time step.
            # Move to a new time step before driving coordinates again.
            await Timer(
                1,
                unit="ns",
            )

    # Always save image before assertions so debugging is easier.
    write_png(
        image_path,
        width,
        height,
        pixels,
    )

    dut._log.info(
        "Saved VGA frame: %s",
        image_path,
    )

    assert len(lit_pixels) > 200, (
        f"Too few illuminated text pixels "
        f"in {image_path}"
    )

    min_x = min(
        x for x, _ in lit_pixels
    )

    max_x = max(
        x for x, _ in lit_pixels
    )

    min_y = min(
        y for _, y in lit_pixels
    )

    max_y = max(
        y for _, y in lit_pixels
    )

    dut._log.info(
        "%s bounding box: x=%d..%d, y=%d..%d",
        image_path,
        min_x,
        max_x,
        min_y,
        max_y,
    )

    # First glyph can begin a few pixels after cell left edge because
    # the 5x7 font has horizontal margin.
    assert (
        left_x
        <= min_x
        <= left_x + 11
    ), (
        f"Unexpected text left edge in "
        f"{image_path}: {min_x}"
    )

    assert max_x < (
        left_x
        + 16 * len(message)
    ), (
        f"Text extends beyond message width "
        f"in {image_path}: {max_x}"
    )

    assert (
        top_y
        <= min_y
        <= top_y + 13
    ), (
        f"Unexpected text top edge in "
        f"{image_path}: {min_y}"
    )

    assert max_y <= (
        top_y + 13
    ), (
        f"Text extends below 5x7 scaled font "
        f"in {image_path}: {max_y}"
    )

    if mismatches:

        preview = "\n".join(

            (
                f"x={x}, y={y}, "
                f"expected={'ON' if expected else 'OFF'}, "
                f"actual={'ON' if actual else 'OFF'}, "
                f"uo_out=0x{uo:02X}"
            )

            for (
                x,
                y,
                expected,
                actual,
                uo,
            ) in mismatches[:20]

        )

        raise AssertionError(

            f"{len(mismatches)} VGA pixel mismatch(es) "
            f"in {image_path}.\n"
            f"First mismatches:\n"
            f"{preview}"

        )

    return (
        min_x,
        max_x,
        min_y,
        max_y,
    )


# ============================================================================
# MAIN COCOTB TEST
# ============================================================================

@cocotb.test()
async def test_uart_vga_scroller(dut):

    # ------------------------------------------------------------------------
    # Start 25.175-MHz-equivalent clock.
    # ------------------------------------------------------------------------

    clock = Clock(
        dut.clk,
        CLK_PERIOD_PS,
        unit="ps",
    )

    clock.start()


    # ========================================================================
    # 1. RESET / UNUSED UIO TEST
    # ========================================================================

    await reset_dut(dut)

    assert int(
        dut.uio_out.value
    ) == 0, (
        "Unused uio_out pins should be 0"
    )

    assert int(
        dut.uio_oe.value
    ) == 0, (
        "All UIO pins should be configured as inputs"
    )


    # ========================================================================
    # 2. BASIC VGA HSYNC TEST
    #
    # This portion uses only external pins and therefore also works during
    # gate-level simulation.
    # ========================================================================

    # h_count is 2 after reset_dut().
    #
    # Advance:
    #     x = 2
    # to:
    #     x = 656

    await ClockCycles(
        dut.clk,
        654,
    )

    # Allow gate-level combinational propagation to settle.
    await Timer(
        10,
        unit="ns",
    )

    assert (
        (
            int(dut.uo_out.value)
            >> 7
        )
        & 1
    ) == 0, (
        "HSYNC should be low at x=656"
    )


    # HSYNC low period:
    #
    # 656 through 751
    #
    # = 96 pixel clocks

    await ClockCycles(
        dut.clk,
        96,
    )

    await Timer(
        10,
        unit="ns",
    )

    assert (
        (
            int(dut.uo_out.value)
            >> 7
        )
        & 1
    ) == 1, (
        "HSYNC should return high at x=752"
    )


    # ========================================================================
    # GATE-LEVEL TEST ENDS HERE
    #
    # Internal RTL names/registers are not guaranteed to survive synthesis,
    # so all remaining checks are RTL-only.
    # ========================================================================

    if os.getenv(
        "GATES",
        "no",
    ) == "yes":

        dut._log.info(
            "Gate-level external VGA timing test passed."
        )

        return


    # ========================================================================
    # 3. SEND "HELLO MITS" THROUGH REAL UART INPUT
    # ========================================================================

    await reset_dut(dut)

    message = "HELLO MITS"

    dut._log.info(
        'Sending "%s" through UART RX...',
        message,
    )

    await uart_send_message(
        dut,
        message,
    )

    await ClockCycles(
        dut.clk,
        8,
    )


    # ========================================================================
    # 4. VERIFY MESSAGE BUFFER STATE
    # ========================================================================

    assert int(
        dut.user_project.msg_len.value
    ) == len(message), (
        f"Expected msg_len={len(message)}"
    )

    assert int(
        dut.user_project.write_ptr.value
    ) == 0, (
        "Enter should reset write_ptr to 0"
    )

    assert int(
        dut.user_project.scroll_pos.value
    ) == 0, (
        "Enter should restart scroll_pos at 0"
    )


    # ========================================================================
    # 5. VERIFY SCROLL SPEED
    #
    # ui[1:0] = 01
    #
    # Expected:
    #     2 pixels/frame
    # ========================================================================

    set_controls(
        dut,
        speed=1,
        pause=False,
    )

    # Force VGA timing to the final pixel of a frame.
    dut.user_project.vga_inst.h_count.value = 799
    dut.user_project.vga_inst.v_count.value = 524

    await Timer(
        1,
        unit="ns",
    )

    await RisingEdge(
        dut.clk
    )

    await ReadOnly()

    assert int(
        dut.user_project.scroll_pos.value
    ) == 2, (
        "Speed 01 should move by 2 pixels/frame"
    )

    await Timer(
        1,
        unit="ns",
    )


    # ========================================================================
    # 6. VERIFY PAUSE
    # ========================================================================

    set_controls(
        dut,
        speed=3,
        pause=True,
    )

    dut.user_project.vga_inst.h_count.value = 799
    dut.user_project.vga_inst.v_count.value = 524

    await Timer(
        1,
        unit="ns",
    )

    await RisingEdge(
        dut.clk
    )

    await ReadOnly()

    assert int(
        dut.user_project.scroll_pos.value
    ) == 2, (
        "Pause should hold scroll_pos"
    )

    await Timer(
        1,
        unit="ns",
    )


    # ========================================================================
    # 7. STOP CLOCK BEFORE MANUAL VGA PIXEL SAMPLING
    # ========================================================================

    clock.stop()

    set_controls(
        dut,
        speed=0,
        pause=True,
    )

    await Timer(
        1,
        unit="ns",
    )


    # ========================================================================
    # 8. CREATE OUTPUT DIRECTORY
    # ========================================================================

    output_dir = Path(
        "output"
    )

    output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )


    # ========================================================================
    # 9. FRAME 1
    #
    # Message left edge:
    #
    #     x = 200
    #
    # Equivalent:
    #
    #     scroll_pos = 640 - 200 = 440
    # ========================================================================

    frame1_path = (
        output_dir
        / "vga_hello_mits_frame1.png"
    )

    frame1_box = await render_and_verify_frame(
        dut,
        message,
        left_x=200,
        image_path=frame1_path,
    )


    # ========================================================================
    # 10. FRAME 2
    #
    # Message shifted 80 pixels to the left:
    #
    #     x = 120
    #
    # Equivalent:
    #
    #     scroll_pos = 640 - 120 = 520
    # ========================================================================

    frame2_path = (
        output_dir
        / "vga_hello_mits_frame2.png"
    )

    frame2_box = await render_and_verify_frame(
        dut,
        message,
        left_x=120,
        image_path=frame2_path,
    )


    # ========================================================================
    # 11. VERIFY THE SECOND FRAME REALLY MOVED LEFT
    # ========================================================================

    frame1_min_x = frame1_box[0]
    frame2_min_x = frame2_box[0]

    measured_shift = (
        frame1_min_x
        - frame2_min_x
    )

    assert measured_shift == 80, (
        f"Expected second frame to shift left by 80 pixels, "
        f"but measured {measured_shift}"
    )


    # ========================================================================
    # FINAL PASS MESSAGES
    # ========================================================================

    dut._log.info(
        'PASS: UART "%s" was received correctly.',
        message,
    )

    dut._log.info(
        "PASS: Scroll speed and pause controls verified."
    )

    dut._log.info(
        "PASS: Frame 1 verified: %s",
        frame1_path,
    )

    dut._log.info(
        "PASS: Frame 2 verified: %s",
        frame2_path,
    )

    dut._log.info(
        "PASS: Second frame moved left by exactly %d pixels.",
        measured_shift,
    )
