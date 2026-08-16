# SPDX-License-Identifier: Apache-2.0

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_PERIOD_PS = 39722
UART_CLKS_PER_BIT = round(25_175_000 / 9600)


def set_rx(dut, bit):
    value = int(dut.ui_in.value)
    if bit:
        value |= (1 << 3)
    else:
        value &= ~(1 << 3)
    dut.ui_in.value = value


async def reset_dut(dut):
    dut.ena.value = 1
    dut.uio_in.value = 0

    # UART idle high. Speed = 00. Pause = 0.
    dut.ui_in.value = 0x08

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def uart_send_byte(dut, value):
    # Start bit
    set_rx(dut, 0)
    await ClockCycles(dut.clk, UART_CLKS_PER_BIT)

    # 8 data bits, LSB first
    for bit_index in range(8):
        set_rx(dut, (value >> bit_index) & 1)
        await ClockCycles(dut.clk, UART_CLKS_PER_BIT)

    # Stop bit
    set_rx(dut, 1)
    await ClockCycles(dut.clk, UART_CLKS_PER_BIT)

    # Small idle gap
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_uart_vga_scroller(dut):
    clock = Clock(dut.clk, CLK_PERIOD_PS, unit="ps")
    cocotb.start_soon(clock.start())

    # ------------------------------------------------------------
    # Basic reset, unused-I/O and VGA HSYNC test
    # ------------------------------------------------------------
    await reset_dut(dut)

    assert int(dut.uio_out.value) == 0
    assert int(dut.uio_oe.value) == 0

    # h_count is 2 here. At x=0..655 HSYNC is high.
    assert ((int(dut.uo_out.value) >> 7) & 1) == 1

    # Advance from x=2 to x=656.
    await ClockCycles(dut.clk, 654)
    assert ((int(dut.uo_out.value) >> 7) & 1) == 0, \
        "HSYNC should be low at x=656"

    # HSYNC is low for x=656..751 (96 clocks).
    await ClockCycles(dut.clk, 96)
    assert ((int(dut.uo_out.value) >> 7) & 1) == 1, \
        "HSYNC should return high at x=752"

    # Gate-level netlist does not expose RTL internal registers.
    if os.getenv("GATES", "no") == "yes":
        return

    # ------------------------------------------------------------
    # UART/message-buffer test
    # ------------------------------------------------------------
    await reset_dut(dut)

    for ch in b"HELLO":
        await uart_send_byte(dut, ch)

    await ClockCycles(dut.clk, 4)

    assert int(dut.user_project.msg_len.value) == 5
    assert int(dut.user_project.write_ptr.value) == 5

    # Enter restarts scrolling and prepares the buffer for a new message.
    await uart_send_byte(dut, 0x0D)
    await ClockCycles(dut.clk, 4)

    assert int(dut.user_project.msg_len.value) == 5
    assert int(dut.user_project.write_ptr.value) == 0

    # The next character starts a new message at position zero.
    await uart_send_byte(dut, ord("A"))
    await ClockCycles(dut.clk, 4)

    assert int(dut.user_project.msg_len.value) == 1
    assert int(dut.user_project.write_ptr.value) == 1
