# SPDX-License-Identifier: Apache-2.0
import os
import struct
import zlib
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

CLK_PERIOD_PS = 39722
UART_CLKS_PER_BIT = 2622

def set_rx(dut, bit):
    v = int(dut.ui_in.value)
    v = (v | 0x08) if bit else (v & ~0x08)
    dut.ui_in.value = v

def set_controls(dut, speed=0, pause=False):
    # ui[1:0]=speed, ui[2]=pause, ui[3]=UART idle high
    dut.ui_in.value = (speed & 0x3) | (0x04 if pause else 0) | 0x08

async def reset_dut(dut):
    dut.ena.value = 1
    dut.uio_in.value = 0
    set_controls(dut, 0, False)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

async def uart_send_byte(dut, value):
    set_rx(dut, 0)
    await ClockCycles(dut.clk, UART_CLKS_PER_BIT)
    for i in range(8):
        set_rx(dut, (value >> i) & 1)
        await ClockCycles(dut.clk, UART_CLKS_PER_BIT)
    set_rx(dut, 1)
    await ClockCycles(dut.clk, UART_CLKS_PER_BIT)
    await ClockCycles(dut.clk, 4)

async def uart_send_message(dut, text):
    for b in text.encode("ascii"):
        await uart_send_byte(dut, b)
    await uart_send_byte(dut, 0x0D)  # Enter / CR

def png_chunk(kind, data):
    payload = kind + data
    return struct.pack(">I", len(data)) + payload + struct.pack(
        ">I", zlib.crc32(payload) & 0xFFFFFFFF
    )

def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for r, g, b in pixels[y * width:(y + 1) * width]:
            raw.extend((r, g, b))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    data = bytearray(b"\x89PNG\r\n\x1a\n")
    data += png_chunk(b"IHDR", ihdr)
    data += png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    data += png_chunk(b"IEND", b"")
    Path(path).write_bytes(data)

FONT = {
    " ": ["00000","00000","00000","00000","00000","00000","00000"],
    "H": ["10001","10001","10001","11111","10001","10001","10001"],
    "E": ["11111","10000","10000","11110","10000","10000","11111"],
    "L": ["10000","10000","10000","10000","10000","10000","11111"],
    "O": ["01110","10001","10001","10001","10001","10001","01110"],
    "M": ["10001","11011","10101","10101","10001","10001","10001"],
    "I": ["11111","00100","00100","00100","00100","00100","11111"],
    "T": ["11111","00100","00100","00100","00100","00100","00100"],
    "S": ["01111","10000","10000","01110","00001","00001","11110"],
}

def expected_pixel(message, x, y, left=200, top=232):
    if y < top or y >= top + 16:
        return False
    if x < left or x >= left + 16 * len(message):
        return False
    rx, ry = x - left, y - top
    ci = rx // 16
    col = (rx % 16) // 2
    row = ry // 2
    if not (1 <= col <= 5) or row > 6:
        return False
    return FONT[message[ci]][row][col - 1] == "1"

def decode_rgb222(uo):
    r = ((((uo >> 0) & 1) << 1) | ((uo >> 4) & 1)) * 85
    g = ((((uo >> 1) & 1) << 1) | ((uo >> 5) & 1)) * 85
    b = ((((uo >> 2) & 1) << 1) | ((uo >> 6) & 1)) * 85
    return r, g, b

@cocotb.test()
async def test_uart_vga_scroller(dut):
    clock = Clock(dut.clk, CLK_PERIOD_PS, unit="ps")
    clock.start()

    # External-pin checks: these also run on the gate-level netlist.
    await reset_dut(dut)
    assert int(dut.uio_out.value) == 0
    assert int(dut.uio_oe.value) == 0

    await ClockCycles(dut.clk, 654)
    await Timer(10, unit="ns")
    assert ((int(dut.uo_out.value) >> 7) & 1) == 0, \
        "HSYNC should be low at x=656"

    await ClockCycles(dut.clk, 96)
    await Timer(10, unit="ns")
    assert ((int(dut.uo_out.value) >> 7) & 1) == 1, \
        "HSYNC should return high at x=752"

    if os.getenv("GATES", "no") == "yes":
        dut._log.info("Gate-level external-pin VGA timing test passed.")
        return

    # End-to-end UART input.
    await reset_dut(dut)
    message = "HELLO MITS"
    await uart_send_message(dut, message)
    await ClockCycles(dut.clk, 8)

    assert int(dut.user_project.msg_len.value) == len(message)
    assert int(dut.user_project.write_ptr.value) == 0
    assert int(dut.user_project.scroll_pos.value) == 0

    # Speed 01 must advance by 2 pixels at a frame boundary.
    set_controls(dut, speed=1, pause=False)
    dut.user_project.vga_inst.h_count.value = 799
    dut.user_project.vga_inst.v_count.value = 524
    await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.user_project.scroll_pos.value) == 2
    await Timer(1, unit="ns")

    # Pause must hold the position.
    set_controls(dut, speed=3, pause=True)
    dut.user_project.vga_inst.h_count.value = 799
    dut.user_project.vga_inst.v_count.value = 524
    await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.user_project.scroll_pos.value) == 2
    await Timer(1, unit="ns")

    # Visual RTL check. Place the message at x=200:
    # message_left = 640 - scroll_pos => scroll_pos = 440.
    clock.stop()
    set_controls(dut, speed=0, pause=True)
    dut.user_project.scroll_pos.value = 440
    await Timer(1, unit="ns")

    width, height = 640, 480
    pixels = [(0, 0, 0)] * (width * height)
    mismatches = []
    lit = []

    # Sample a box covering the complete 160x16 message plus margin.
    for y in range(228, 252):
        for x in range(190, 371):
            dut.user_project.vga_inst.h_count.value = x
            dut.user_project.vga_inst.v_count.value = y
            await ReadOnly()

            uo = int(dut.uo_out.value)
            rgb = decode_rgb222(uo)
            pixels[y * width + x] = rgb

            actual = rgb != (0, 0, 0)
            expected = expected_pixel(message, x, y)

            if actual:
                lit.append((x, y))
            if actual != expected:
                mismatches.append((x, y, expected, actual, uo))

            await Timer(1, unit="ns")

    outdir = Path("output")
    outdir.mkdir(parents=True, exist_ok=True)
    image = outdir / "vga_hello_mits.png"
    write_png(image, width, height, pixels)

    dut._log.info("Generated simulated VGA image: %s", image)
    assert len(lit) > 200, "Too few lit pixels in VGA text"

    if mismatches:
        sample = "\n".join(
            f"x={x}, y={y}, expected={e}, actual={a}, uo=0x{uo:02X}"
            for x, y, e, a, uo in mismatches[:20]
        )
        raise AssertionError(
            f"{len(mismatches)} VGA pixel mismatches.\n{sample}\nImage: {image}"
        )

    dut._log.info('PASS: UART "%s" rendered correctly on VGA.', message)
