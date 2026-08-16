/*
 * UART-programmable VGA scrolling text display for Tiny Tapeout SKY
 * SPDX-License-Identifier: Apache-2.0
 *
 * Clock: 25.175 MHz nominal
 * UART:  9600 baud, 8-N-1
 * UART RX: ui_in[3] (Tiny Tapeout demo-board USB/UART RX convention)
 * VGA: uo_out[7:0] using TinyVGA RGB222 + sync mapping
 */

`default_nettype none

module tt_um_nobleg30_uart_vga_scroller (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam integer CLK_FREQ_HZ = 25175000;
    localparam integer UART_BAUD   = 9600;

    // ----------------------------------------------------------------
    // UART receiver
    // ----------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD(UART_BAUD)
    ) uart_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx         (ui_in[3]),
        .data_out   (rx_data),
        .data_valid (rx_valid)
    );

    // ----------------------------------------------------------------
    // VGA timing: 640x480, standard 800x525 total timing
    // ----------------------------------------------------------------
    wire [9:0] h_count;
    wire [9:0] v_count;
    wire       hsync;
    wire       vsync;
    wire       video_active;
    wire       frame_tick;

    vga_timing vga_inst (
        .clk          (clk),
        .rst_n        (rst_n),
        .h_count      (h_count),
        .v_count      (v_count),
        .hsync        (hsync),
        .vsync        (vsync),
        .video_active (video_active),
        .frame_tick   (frame_tick)
    );

    // ----------------------------------------------------------------
    // Message memory
    //
    // Internal code:
    //   0       space / unsupported
    //   1..26   A..Z
    //   27..36  0..9
    //   37      .
    //   38      -
    //   39      !
    //   40      ?
    //   41      :
    //
    // 16 characters x 6 bits = 96 DFFs.
    // ----------------------------------------------------------------
    reg [5:0] msg_mem [0:15];
    reg [4:0] msg_len;
    reg [4:0] write_ptr;

    integer i;

    function [5:0] ascii_to_code;
        input [7:0] ascii;
        begin
            if ((ascii >= 8'h41) && (ascii <= 8'h5A))
                ascii_to_code = ascii - 8'h40;       // A-Z
            else if ((ascii >= 8'h61) && (ascii <= 8'h7A))
                ascii_to_code = ascii - 8'h60;       // a-z -> A-Z
            else if ((ascii >= 8'h30) && (ascii <= 8'h39))
                ascii_to_code = 6'd27 + (ascii - 8'h30);
            else begin
                case (ascii)
                    8'h20: ascii_to_code = 6'd0;     // space
                    8'h2E: ascii_to_code = 6'd37;    // .
                    8'h2D: ascii_to_code = 6'd38;    // -
                    8'h21: ascii_to_code = 6'd39;    // !
                    8'h3F: ascii_to_code = 6'd40;    // ?
                    8'h3A: ascii_to_code = 6'd41;    // :
                    default: ascii_to_code = 6'd0;
                endcase
            end
        end
    endfunction

    // Type a message, then press Enter (CR or LF).
    // After Enter, the write pointer returns to position 0 so the next
    // message overwrites the previous one.
    always @(posedge clk) begin
        if (!rst_n) begin
            msg_len        <= 5'd0;
            write_ptr      <= 5'd0;
            for (i = 0; i < 16; i = i + 1)
                msg_mem[i] <= 6'd0;
        end else begin
            if (rx_valid) begin
                if ((rx_data == 8'h0D) || (rx_data == 8'h0A)) begin
                    write_ptr <= 5'd0;
                end else if ((rx_data >= 8'h20) && (rx_data <= 8'h7E)) begin
                    if (write_ptr < 5'd16) begin
                        msg_mem[write_ptr[3:0]] <= ascii_to_code(rx_data);
                        msg_len                 <= write_ptr + 5'd1;
                        write_ptr               <= write_ptr + 5'd1;
                    end
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Scroll control
    //
    // ui_in[1:0]:
    //   00 = 1 pixel/frame
    //   01 = 2 pixels/frame
    //   10 = 4 pixels/frame
    //   11 = 8 pixels/frame
    //
    // ui_in[2] = pause when high
    // ----------------------------------------------------------------
    reg  [9:0] scroll_pos;
    wire [8:0] msg_width;
    wire [9:0] scroll_limit;
    wire [9:0] scroll_step;

    assign msg_width    = {msg_len, 4'b0000};  // 16 pixels/character
    assign scroll_limit = 10'd640 + {1'b0, msg_width};
    assign scroll_step  = (10'd1 << ui_in[1:0]);

    wire rx_enter = rx_valid && ((rx_data == 8'h0D) || (rx_data == 8'h0A));

    always @(posedge clk) begin
        if (!rst_n) begin
            scroll_pos <= 10'd0;
        end else if (rx_enter) begin
            scroll_pos <= 10'd0;
        end else if (frame_tick && !ui_in[2] && (msg_len != 0)) begin
            if ((scroll_pos + scroll_step) >= scroll_limit)
                scroll_pos <= 10'd0;
            else
                scroll_pos <= scroll_pos + scroll_step;
        end
    end

    // ----------------------------------------------------------------
    // Text addressing
    //
    // Message left edge = 640 - scroll_pos.
    // rel_x = pixel_x - message_left_edge
    //       = pixel_x + scroll_pos - 640
    //
    // Each character cell is 16x16 pixels. A 5x7 font is scaled 2x.
    // ----------------------------------------------------------------
    wire [10:0] x_sum;
    wire [10:0] rel_x;
    wire [9:0]  rel_y;
    wire [3:0]  char_index;
    wire [2:0]  glyph_col;
    wire [2:0]  glyph_row;
    wire [5:0]  current_code;
    wire [34:0] glyph_bits;
    wire [4:0]  glyph_row_bits;

    assign x_sum      = {1'b0, h_count} + {1'b0, scroll_pos};
    assign rel_x      = x_sum - 11'd640;
    assign rel_y      = v_count - 10'd232;
    assign char_index = rel_x[7:4];
    assign glyph_col  = rel_x[3:1];
    assign glyph_row  = rel_y[3:1];

    assign current_code   = msg_mem[char_index];
    assign glyph_bits     = glyph35(current_code);
    assign glyph_row_bits = row_select(glyph_bits, glyph_row);

    reg glyph_pixel;

    always @* begin
        glyph_pixel = 1'b0;
        case (glyph_col)
            3'd1: glyph_pixel = glyph_row_bits[4];
            3'd2: glyph_pixel = glyph_row_bits[3];
            3'd3: glyph_pixel = glyph_row_bits[2];
            3'd4: glyph_pixel = glyph_row_bits[1];
            3'd5: glyph_pixel = glyph_row_bits[0];
            default: glyph_pixel = 1'b0;
        endcase
    end

    wire text_window;
    wire pixel_on;

    assign text_window =
        video_active &&
        (v_count >= 10'd232) &&
        (v_count <  10'd248) &&
        (x_sum >= 11'd640) &&
        (rel_x < {2'b00, msg_width}) &&
        ({1'b0, char_index} < msg_len);

    assign pixel_on = text_window && glyph_pixel && ena;

    // ----------------------------------------------------------------
    // TinyVGA RGB222 output
    // White text on black background
    // ----------------------------------------------------------------
    wire [1:0] red   = pixel_on ? 2'b11 : 2'b00;
    wire [1:0] green = pixel_on ? 2'b11 : 2'b00;
    wire [1:0] blue  = pixel_on ? 2'b11 : 2'b00;

    assign uo_out[0] = red[1];    // R1
    assign uo_out[1] = green[1];  // G1
    assign uo_out[2] = blue[1];   // B1
    assign uo_out[3] = vsync;
    assign uo_out[4] = red[0];    // R0
    assign uo_out[5] = green[0];  // G0
    assign uo_out[6] = blue[0];   // B0
    assign uo_out[7] = hsync;

    // Bidirectional bank is unused in this version.
    assign uio_out = 8'b00000000;
    assign uio_oe  = 8'b00000000;

    // Suppress unused-input warnings.
    wire _unused = &{ui_in[7:4], uio_in, 1'b0};

    // ----------------------------------------------------------------
    // Select one 5-bit row from a packed 5x7 glyph.
    // ----------------------------------------------------------------
    function [4:0] row_select;
        input [34:0] bits;
        input [2:0]  row;
        begin
            case (row)
                3'd0: row_select = bits[34:30];
                3'd1: row_select = bits[29:25];
                3'd2: row_select = bits[24:20];
                3'd3: row_select = bits[19:15];
                3'd4: row_select = bits[14:10];
                3'd5: row_select = bits[9:5];
                3'd6: row_select = bits[4:0];
                default: row_select = 5'b00000;
            endcase
        end
    endfunction

    // ----------------------------------------------------------------
    // 5x7 font ROM implemented as combinational constants.
    // ----------------------------------------------------------------
    function [34:0] glyph35;
        input [5:0] code;
        begin
            case (code)
                6'd0:  glyph35 = 35'b00000_00000_00000_00000_00000_00000_00000; // space
                6'd1:  glyph35 = 35'b01110_10001_10001_11111_10001_10001_10001; // A
                6'd2:  glyph35 = 35'b11110_10001_10001_11110_10001_10001_11110; // B
                6'd3:  glyph35 = 35'b01111_10000_10000_10000_10000_10000_01111; // C
                6'd4:  glyph35 = 35'b11110_10001_10001_10001_10001_10001_11110; // D
                6'd5:  glyph35 = 35'b11111_10000_10000_11110_10000_10000_11111; // E
                6'd6:  glyph35 = 35'b11111_10000_10000_11110_10000_10000_10000; // F
                6'd7:  glyph35 = 35'b01111_10000_10000_10111_10001_10001_01111; // G
                6'd8:  glyph35 = 35'b10001_10001_10001_11111_10001_10001_10001; // H
                6'd9:  glyph35 = 35'b11111_00100_00100_00100_00100_00100_11111; // I
                6'd10: glyph35 = 35'b00111_00010_00010_00010_00010_10010_01100; // J
                6'd11: glyph35 = 35'b10001_10010_10100_11000_10100_10010_10001; // K
                6'd12: glyph35 = 35'b10000_10000_10000_10000_10000_10000_11111; // L
                6'd13: glyph35 = 35'b10001_11011_10101_10101_10001_10001_10001; // M
                6'd14: glyph35 = 35'b10001_11001_10101_10011_10001_10001_10001; // N
                6'd15: glyph35 = 35'b01110_10001_10001_10001_10001_10001_01110; // O
                6'd16: glyph35 = 35'b11110_10001_10001_11110_10000_10000_10000; // P
                6'd17: glyph35 = 35'b01110_10001_10001_10001_10101_10010_01101; // Q
                6'd18: glyph35 = 35'b11110_10001_10001_11110_10100_10010_10001; // R
                6'd19: glyph35 = 35'b01111_10000_10000_01110_00001_00001_11110; // S
                6'd20: glyph35 = 35'b11111_00100_00100_00100_00100_00100_00100; // T
                6'd21: glyph35 = 35'b10001_10001_10001_10001_10001_10001_01110; // U
                6'd22: glyph35 = 35'b10001_10001_10001_10001_10001_01010_00100; // V
                6'd23: glyph35 = 35'b10001_10001_10001_10101_10101_10101_01010; // W
                6'd24: glyph35 = 35'b10001_10001_01010_00100_01010_10001_10001; // X
                6'd25: glyph35 = 35'b10001_10001_01010_00100_00100_00100_00100; // Y
                6'd26: glyph35 = 35'b11111_00001_00010_00100_01000_10000_11111; // Z

                6'd27: glyph35 = 35'b01110_10001_10011_10101_11001_10001_01110; // 0
                6'd28: glyph35 = 35'b00100_01100_00100_00100_00100_00100_01110; // 1
                6'd29: glyph35 = 35'b01110_10001_00001_00010_00100_01000_11111; // 2
                6'd30: glyph35 = 35'b11110_00001_00001_01110_00001_00001_11110; // 3
                6'd31: glyph35 = 35'b00010_00110_01010_10010_11111_00010_00010; // 4
                6'd32: glyph35 = 35'b11111_10000_10000_11110_00001_00001_11110; // 5
                6'd33: glyph35 = 35'b01110_10000_10000_11110_10001_10001_01110; // 6
                6'd34: glyph35 = 35'b11111_00001_00010_00100_01000_01000_01000; // 7
                6'd35: glyph35 = 35'b01110_10001_10001_01110_10001_10001_01110; // 8
                6'd36: glyph35 = 35'b01110_10001_10001_01111_00001_00001_01110; // 9

                6'd37: glyph35 = 35'b00000_00000_00000_00000_00000_00110_00110; // .
                6'd38: glyph35 = 35'b00000_00000_00000_11111_00000_00000_00000; // -
                6'd39: glyph35 = 35'b00100_00100_00100_00100_00100_00000_00100; // !
                6'd40: glyph35 = 35'b01110_10001_00001_00010_00100_00000_00100; // ?
                6'd41: glyph35 = 35'b00000_00100_00100_00000_00100_00100_00000; // :

                default: glyph35 = 35'b00000_00000_00000_00000_00000_00000_00000;
            endcase
        end
    endfunction

endmodule


// ====================================================================
// UART RX, 8-N-1
// ====================================================================
module uart_rx #(
    parameter integer CLK_FREQ_HZ = 25175000,
    parameter integer BAUD        = 9600
) (
    input  wire      clk,
    input  wire      rst_n,
    input  wire      rx,
    output wire [7:0] data_out,
    output wire       data_valid
);

    // Round to the nearest integer number of clocks per UART bit.
    localparam integer CLKS_PER_BIT = (CLK_FREQ_HZ + (BAUD / 2)) / BAUD;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg       rx_meta;
    reg       rx_sync;
    reg [1:0] state;
    reg [12:0] clk_count;
    reg [2:0] bit_index;
    reg [7:0] rx_shift;

    // rx_shift already contains the complete byte during the stop bit.
    // Avoid a second 8-bit output register to save area.
    assign data_out = rx_shift;
    assign data_valid =
        (state == S_STOP) &&
        (clk_count == (CLKS_PER_BIT - 1)) &&
        rx_sync;

    // Two-flop synchronizer for asynchronous serial input.
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            clk_count  <= 13'd0;
            bit_index  <= 3'd0;
            rx_shift   <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    clk_count <= 13'd0;
                    bit_index <= 3'd0;
                    if (!rx_sync)
                        state <= S_START;
                end

                S_START: begin
                    if (clk_count == ((CLKS_PER_BIT / 2) - 1)) begin
                        clk_count <= 13'd0;
                        if (!rx_sync)
                            state <= S_DATA;
                        else
                            state <= S_IDLE;
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                S_DATA: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 13'd0;
                        rx_shift[bit_index] <= rx_sync;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state <= S_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                S_STOP: begin
                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= 13'd0;
                        state <= S_IDLE;

                    end else begin
                        clk_count <= clk_count + 13'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule


// ====================================================================
// VGA timing: 640x480 active, 800x525 total.
// Intended for ~25.175 MHz pixel clock.
// ====================================================================
module vga_timing (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [9:0] h_count,
    output reg  [9:0] v_count,
    output wire       hsync,
    output wire       vsync,
    output wire       video_active,
    output wire       frame_tick
);

    always @(posedge clk) begin
        if (!rst_n) begin
            h_count <= 10'd0;
            v_count <= 10'd0;
        end else begin
            if (h_count == 10'd799) begin
                h_count <= 10'd0;

                if (v_count == 10'd524)
                    v_count <= 10'd0;
                else
                    v_count <= v_count + 10'd1;
            end else begin
                h_count <= h_count + 10'd1;
            end
        end
    end

    assign video_active = (h_count < 10'd640) && (v_count < 10'd480);

    // Standard VGA syncs are active low.
    assign hsync = ~((h_count >= 10'd656) && (h_count < 10'd752));
    assign vsync = ~((v_count >= 10'd490) && (v_count < 10'd492));

    assign frame_tick = (h_count == 10'd799) && (v_count == 10'd524);

endmodule

`default_nettype wire
