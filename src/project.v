/*
 * UART-programmable VGA scrolling text display for Tiny Tapeout SKY26C
 *
 * Clock    : 25.175 MHz
 * UART     : 9600 baud, 8-N-1
 * UART RX  : ui_in[3]
 * VGA      : uo_out[7:0], TinyVGA RGB222 + HSYNC/VSYNC
 *
 * Message length : 16 characters maximum
 * Font           : 5x7, scaled 2x
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


    // ============================================================
    // UART RECEIVER
    // ============================================================

    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx uart_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx         (ui_in[3]),
        .data_out   (rx_data),
        .data_valid (rx_valid)
    );


    // ============================================================
    // VGA TIMING
    // ============================================================

    wire [9:0] h_count;
    wire [9:0] v_count;

    wire hsync;
    wire vsync;

    wire video_active;
    wire frame_tick;

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


    // ============================================================
    // MESSAGE BUFFER
    //
    // Character codes:
    //
    //  0       Space
    //  1-26    A-Z
    // 27-36    0-9
    // 37       .
    // 38       -
    // 39       !
    // 40       ?
    // 41       :
    //
    // Storage = 16 x 6 = 96 bits
    // ============================================================

    reg [5:0] msg_mem [0:15];

    reg [4:0] msg_len;
    reg [4:0] write_ptr;

    integer i;


    // ------------------------------------------------------------
    // ASCII to compact 6-bit code
    // ------------------------------------------------------------

    function [5:0] ascii_to_code;

        input [7:0] ascii;

        begin

            // A-Z
            //
            // ASCII:
            // A = 0x41 -> lower 6 bits = 1
            // Z = 0x5A -> lower 6 bits = 26

            if ((ascii >= 8'h41) &&
                (ascii <= 8'h5A)) begin

                ascii_to_code = ascii[5:0];

            end


            // a-z -> A-Z
            //
            // 'a'[5:0] = 33
            // 33 - 32 = 1

            else if ((ascii >= 8'h61) &&
                     (ascii <= 8'h7A)) begin

                ascii_to_code =
                    ascii[5:0] - 6'd32;

            end


            // 0-9
            //
            // '0' = 48
            // 48 - 21 = 27

            else if ((ascii >= 8'h30) &&
                     (ascii <= 8'h39)) begin

                ascii_to_code =
                    ascii[5:0] - 6'd21;

            end


            else begin

                case (ascii)

                    8'h20:
                        ascii_to_code = 6'd0;   // space

                    8'h2E:
                        ascii_to_code = 6'd37;  // .

                    8'h2D:
                        ascii_to_code = 6'd38;  // -

                    8'h21:
                        ascii_to_code = 6'd39;  // !

                    8'h3F:
                        ascii_to_code = 6'd40;  // ?

                    8'h3A:
                        ascii_to_code = 6'd41;  // :

                    default:
                        ascii_to_code = 6'd0;

                endcase

            end

        end

    endfunction


    // ------------------------------------------------------------
    // Store incoming UART characters
    //
    // CR/LF:
    //   - resets write pointer
    //   - restarts scrolling
    //
    // Next character therefore starts a new message.
    // ------------------------------------------------------------

    always @(posedge clk) begin

        if (!rst_n) begin

            msg_len   <= 5'd0;
            write_ptr <= 5'd0;

            for (i = 0; i < 16; i = i + 1)
                msg_mem[i] <= 6'd0;

        end

        else begin

            if (rx_valid) begin

                // ENTER = carriage return or line feed

                if ((rx_data == 8'h0D) ||
                    (rx_data == 8'h0A)) begin

                    write_ptr <= 5'd0;

                end


                // Printable ASCII

                else if ((rx_data >= 8'h20) &&
                         (rx_data <= 8'h7E)) begin

                    if (write_ptr < 5'd16) begin

                        msg_mem[write_ptr[3:0]]
                            <= ascii_to_code(rx_data);

                        msg_len
                            <= write_ptr + 5'd1;

                        write_ptr
                            <= write_ptr + 5'd1;

                    end

                end

            end

        end

    end


    // ============================================================
    // SCROLL CONTROL
    //
    // ui_in[1:0]
    //
    // 00 = 1 pixel/frame
    // 01 = 2 pixels/frame
    // 10 = 4 pixels/frame
    // 11 = 8 pixels/frame
    //
    // ui_in[2] = pause
    // ============================================================

    reg [9:0] scroll_pos;

    wire [8:0] msg_width;
    wire [9:0] scroll_limit;
    wire [9:0] scroll_step;

    wire rx_enter;


    assign msg_width =
        {msg_len, 4'b0000};


    assign scroll_limit =
        10'd640 + {1'b0, msg_width};


    assign scroll_step =
        10'd1 << ui_in[1:0];


    assign rx_enter =
        rx_valid &&
        (
            (rx_data == 8'h0D) ||
            (rx_data == 8'h0A)
        );


    always @(posedge clk) begin

        if (!rst_n) begin

            scroll_pos <= 10'd0;

        end


        else if (rx_enter) begin

            scroll_pos <= 10'd0;

        end


        else if (
            frame_tick &&
            !ui_in[2] &&
            (msg_len != 5'd0)
        ) begin

            if (
                (scroll_pos + scroll_step)
                >= scroll_limit
            ) begin

                scroll_pos <= 10'd0;

            end

            else begin

                scroll_pos
                    <= scroll_pos + scroll_step;

            end

        end

    end


    // ============================================================
    // TEXT POSITION CALCULATION
    //
    // Message starts outside right side:
    //
    // message_x = 640 - scroll_pos
    //
    // Therefore:
    //
    // rel_x = pixel_x + scroll_pos - 640
    //
    // Character cell = 16 x 16 pixels
    // Font = 5 x 7 scaled 2x
    // ============================================================

    wire [10:0] x_sum;
    wire [10:0] rel_x;

    wire [3:0] char_index;

    wire [2:0] glyph_col;
    wire [2:0] glyph_row;

    wire [5:0] current_code;

    wire [34:0] glyph_bits;
    wire [4:0]  glyph_row_bits;


    assign x_sum =
        {1'b0, h_count}
        +
        {1'b0, scroll_pos};


    assign rel_x =
        x_sum - 11'd640;


    // 16 pixels per character

    assign char_index =
        rel_x[7:4];


    // 2x horizontal font scaling

    assign glyph_col =
        rel_x[3:1];


    // ------------------------------------------------------------
    // Vertical font row
    //
    // Text window = y 232 to 247
    //
    // Desired sequence:
    //
    // y=232,233 -> row 0
    // y=234,235 -> row 1
    // ...
    // y=244,245 -> row 6
    // y=246,247 -> row 7 (blank)
    //
    // v_count[3:1] sequence inside this region is:
    //
    // 4,4,5,5,6,6,7,7,0,0,1,1,2,2,3,3
    //
    // Adding 4 modulo 8 gives:
    //
    // 0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7
    //
    // This removes the unused rel_y signal.
    // ------------------------------------------------------------

    assign glyph_row =
        v_count[3:1] + 3'd4;


    assign current_code =
        msg_mem[char_index];


    assign glyph_bits =
        glyph35(current_code);


    assign glyph_row_bits =
        row_select(
            glyph_bits,
            glyph_row
        );


    // ============================================================
    // SELECT FONT PIXEL
    // ============================================================

    reg glyph_pixel;


    always @* begin

        glyph_pixel = 1'b0;

        case (glyph_col)

            3'd1:
                glyph_pixel = glyph_row_bits[4];

            3'd2:
                glyph_pixel = glyph_row_bits[3];

            3'd3:
                glyph_pixel = glyph_row_bits[2];

            3'd4:
                glyph_pixel = glyph_row_bits[1];

            3'd5:
                glyph_pixel = glyph_row_bits[0];

            default:
                glyph_pixel = 1'b0;

        endcase

    end


    // ============================================================
    // TEXT DISPLAY WINDOW
    // ============================================================

    wire text_window;
    wire pixel_on;


    assign text_window =

        video_active &&

        // Vertical text position
        (v_count >= 10'd232) &&
        (v_count <  10'd248) &&

        // Message has entered visible region
        (x_sum >= 11'd640) &&

        // Pixel lies inside current message width
        (rel_x < {2'b00, msg_width}) &&

        // Character number is valid
        ({1'b0, char_index} < msg_len);


    assign pixel_on =
        text_window &&
        glyph_pixel &&
        ena;


    // ============================================================
    // VGA COLOUR
    //
    // White text on black background
    // RGB222
    // ============================================================

    wire [1:0] red;
    wire [1:0] green;
    wire [1:0] blue;


    assign red =
        pixel_on ? 2'b11 : 2'b00;


    assign green =
        pixel_on ? 2'b11 : 2'b00;


    assign blue =
        pixel_on ? 2'b11 : 2'b00;


    // ============================================================
    // TinyVGA OUTPUT MAPPING
    //
    // uo[0] = R1
    // uo[1] = G1
    // uo[2] = B1
    // uo[3] = VSYNC
    // uo[4] = R0
    // uo[5] = G0
    // uo[6] = B0
    // uo[7] = HSYNC
    // ============================================================

    assign uo_out[0] = red[1];
    assign uo_out[1] = green[1];
    assign uo_out[2] = blue[1];

    assign uo_out[3] = vsync;

    assign uo_out[4] = red[0];
    assign uo_out[5] = green[0];
    assign uo_out[6] = blue[0];

    assign uo_out[7] = hsync;


    // ============================================================
    // BIDIRECTIONAL PINS
    //
    // Not used in this design.
    // ============================================================

    assign uio_out =
        8'b00000000;

    assign uio_oe =
        8'b00000000;


    // Suppress unused-input warnings for unused UI/UIO pins.

    wire _unused;

    assign _unused =
        &{
            ui_in[7:4],
            uio_in,
            1'b0
        };


    // ============================================================
    // SELECT ONE ROW FROM 5x7 FONT
    // ============================================================

    function [4:0] row_select;

        input [34:0] bits;
        input [2:0]  row;

        begin

            case (row)

                3'd0:
                    row_select = bits[34:30];

                3'd1:
                    row_select = bits[29:25];

                3'd2:
                    row_select = bits[24:20];

                3'd3:
                    row_select = bits[19:15];

                3'd4:
                    row_select = bits[14:10];

                3'd5:
                    row_select = bits[9:5];

                3'd6:
                    row_select = bits[4:0];

                default:
                    row_select = 5'b00000;

            endcase

        end

    endfunction


    // ============================================================
    // 5 x 7 FONT
    //
    // Each glyph = 35 bits
    // 7 rows x 5 columns
    // ============================================================

    function [34:0] glyph35;

        input [5:0] code;

        begin

            case (code)

                // SPACE

                6'd0:
                    glyph35 =
                    35'b00000_00000_00000_00000_00000_00000_00000;


                // A

                6'd1:
                    glyph35 =
                    35'b01110_10001_10001_11111_10001_10001_10001;


                // B

                6'd2:
                    glyph35 =
                    35'b11110_10001_10001_11110_10001_10001_11110;


                // C

                6'd3:
                    glyph35 =
                    35'b01111_10000_10000_10000_10000_10000_01111;


                // D

                6'd4:
                    glyph35 =
                    35'b11110_10001_10001_10001_10001_10001_11110;


                // E

                6'd5:
                    glyph35 =
                    35'b11111_10000_10000_11110_10000_10000_11111;


                // F

                6'd6:
                    glyph35 =
                    35'b11111_10000_10000_11110_10000_10000_10000;


                // G

                6'd7:
                    glyph35 =
                    35'b01111_10000_10000_10111_10001_10001_01111;


                // H

                6'd8:
                    glyph35 =
                    35'b10001_10001_10001_11111_10001_10001_10001;


                // I

                6'd9:
                    glyph35 =
                    35'b11111_00100_00100_00100_00100_00100_11111;


                // J

                6'd10:
                    glyph35 =
                    35'b00111_00010_00010_00010_00010_10010_01100;


                // K

                6'd11:
                    glyph35 =
                    35'b10001_10010_10100_11000_10100_10010_10001;


                // L

                6'd12:
                    glyph35 =
                    35'b10000_10000_10000_10000_10000_10000_11111;


                // M

                6'd13:
                    glyph35 =
                    35'b10001_11011_10101_10101_10001_10001_10001;


                // N

                6'd14:
                    glyph35 =
                    35'b10001_11001_10101_10011_10001_10001_10001;


                // O

                6'd15:
                    glyph35 =
                    35'b01110_10001_10001_10001_10001_10001_01110;


                // P

                6'd16:
                    glyph35 =
                    35'b11110_10001_10001_11110_10000_10000_10000;


                // Q

                6'd17:
                    glyph35 =
                    35'b01110_10001_10001_10001_10101_10010_01101;


                // R

                6'd18:
                    glyph35 =
                    35'b11110_10001_10001_11110_10100_10010_10001;


                // S

                6'd19:
                    glyph35 =
                    35'b01111_10000_10000_01110_00001_00001_11110;


                // T

                6'd20:
                    glyph35 =
                    35'b11111_00100_00100_00100_00100_00100_00100;


                // U

                6'd21:
                    glyph35 =
                    35'b10001_10001_10001_10001_10001_10001_01110;


                // V

                6'd22:
                    glyph35 =
                    35'b10001_10001_10001_10001_10001_01010_00100;


                // W

                6'd23:
                    glyph35 =
                    35'b10001_10001_10001_10101_10101_10101_01010;


                // X

                6'd24:
                    glyph35 =
                    35'b10001_10001_01010_00100_01010_10001_10001;


                // Y

                6'd25:
                    glyph35 =
                    35'b10001_10001_01010_00100_00100_00100_00100;


                // Z

                6'd26:
                    glyph35 =
                    35'b11111_00001_00010_00100_01000_10000_11111;


                // 0

                6'd27:
                    glyph35 =
                    35'b01110_10001_10011_10101_11001_10001_01110;


                // 1

                6'd28:
                    glyph35 =
                    35'b00100_01100_00100_00100_00100_00100_01110;


                // 2

                6'd29:
                    glyph35 =
                    35'b01110_10001_00001_00010_00100_01000_11111;


                // 3

                6'd30:
                    glyph35 =
                    35'b11110_00001_00001_01110_00001_00001_11110;


                // 4

                6'd31:
                    glyph35 =
                    35'b00010_00110_01010_10010_11111_00010_00010;


                // 5

                6'd32:
                    glyph35 =
                    35'b11111_10000_10000_11110_00001_00001_11110;


                // 6

                6'd33:
                    glyph35 =
                    35'b01110_10000_10000_11110_10001_10001_01110;


                // 7

                6'd34:
                    glyph35 =
                    35'b11111_00001_00010_00100_01000_01000_01000;


                // 8

                6'd35:
                    glyph35 =
                    35'b01110_10001_10001_01110_10001_10001_01110;


                // 9

                6'd36:
                    glyph35 =
                    35'b01110_10001_10001_01111_00001_00001_01110;


                // .

                6'd37:
                    glyph35 =
                    35'b00000_00000_00000_00000_00000_00110_00110;


                // -

                6'd38:
                    glyph35 =
                    35'b00000_00000_00000_11111_00000_00000_00000;


                // !

                6'd39:
                    glyph35 =
                    35'b00100_00100_00100_00100_00100_00000_00100;


                // ?

                6'd40:
                    glyph35 =
                    35'b01110_10001_00001_00010_00100_00000_00100;


                // :

                6'd41:
                    glyph35 =
                    35'b00000_00100_00100_00000_00100_00100_00000;


                default:
                    glyph35 =
                    35'b00000_00000_00000_00000_00000_00000_00000;

            endcase

        end

    endfunction


endmodule



// ============================================================================
// UART RECEIVER
//
// 9600 baud
// 8 data bits
// No parity
// 1 stop bit
//
// 25.175 MHz / 9600 = approximately 2622 clocks/bit
//
// Fixed constants are intentionally width-matched to clk_count to avoid
// Width-matched constants avoid width-expansion lint warnings
// ============================================================================

module uart_rx (

    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,

    output wire [7:0] data_out,
    output wire       data_valid

);


    // 2622 < 4096, so a 12-bit counter is sufficient.

    localparam [11:0] CLKS_PER_BIT =
        12'd2622;

    localparam [11:0] HALF_CLKS_PER_BIT =
        12'd1311;


    localparam [1:0] S_IDLE =
        2'd0;

    localparam [1:0] S_START =
        2'd1;

    localparam [1:0] S_DATA =
        2'd2;

    localparam [1:0] S_STOP =
        2'd3;


    reg rx_meta;
    reg rx_sync;

    reg [1:0] state;

    reg [11:0] clk_count;

    reg [2:0] bit_index;

    reg [7:0] rx_shift;


    // ------------------------------------------------------------
    // UART outputs
    //
    // rx_shift already contains the complete received byte when
    // the stop bit is checked.
    // ------------------------------------------------------------

    assign data_out =
        rx_shift;


    assign data_valid =

        (state == S_STOP) &&

        (
            clk_count ==
            (CLKS_PER_BIT - 12'd1)
        ) &&

        rx_sync;


    // ------------------------------------------------------------
    // Two-flop synchronizer
    // ------------------------------------------------------------

    always @(posedge clk) begin

        if (!rst_n) begin

            rx_meta <= 1'b1;
            rx_sync <= 1'b1;

        end

        else begin

            rx_meta <= rx;
            rx_sync <= rx_meta;

        end

    end


    // ------------------------------------------------------------
    // UART state machine
    // ------------------------------------------------------------

    always @(posedge clk) begin

        if (!rst_n) begin

            state     <= S_IDLE;

            clk_count <= 12'd0;
            bit_index <= 3'd0;

            rx_shift  <= 8'd0;

        end

        else begin

            case (state)


                // =================================================
                // IDLE
                // =================================================

                S_IDLE: begin

                    clk_count <= 12'd0;
                    bit_index <= 3'd0;

                    if (!rx_sync)
                        state <= S_START;

                end


                // =================================================
                // START BIT
                //
                // Sample in middle of start bit.
                // =================================================

                S_START: begin

                    if (
                        clk_count ==
                        (HALF_CLKS_PER_BIT - 12'd1)
                    ) begin

                        clk_count <= 12'd0;

                        if (!rx_sync)
                            state <= S_DATA;
                        else
                            state <= S_IDLE;

                    end

                    else begin

                        clk_count
                            <= clk_count + 12'd1;

                    end

                end


                // =================================================
                // DATA BITS
                //
                // UART transmits LSB first.
                // =================================================

                S_DATA: begin

                    if (
                        clk_count ==
                        (CLKS_PER_BIT - 12'd1)
                    ) begin

                        clk_count <= 12'd0;

                        rx_shift[bit_index]
                            <= rx_sync;


                        if (bit_index == 3'd7) begin

                            bit_index <= 3'd0;
                            state     <= S_STOP;

                        end

                        else begin

                            bit_index
                                <= bit_index + 3'd1;

                        end

                    end

                    else begin

                        clk_count
                            <= clk_count + 12'd1;

                    end

                end


                // =================================================
                // STOP BIT
                // =================================================

                S_STOP: begin

                    if (
                        clk_count ==
                        (CLKS_PER_BIT - 12'd1)
                    ) begin

                        clk_count <= 12'd0;
                        state     <= S_IDLE;

                    end

                    else begin

                        clk_count
                            <= clk_count + 12'd1;

                    end

                end


                default: begin

                    state <= S_IDLE;

                end

            endcase

        end

    end


endmodule



// ============================================================================
// VGA TIMING GENERATOR
//
// Resolution: 640 x 480
//
// Horizontal:
//
// Visible      640
// Front porch   16
// Sync          96
// Back porch    48
// -----------------
// Total        800
//
// Vertical:
//
// Visible      480
// Front porch   10
// Sync           2
// Back porch    33
// -----------------
// Total        525
//
// Pixel clock approximately 25.175 MHz
// Frame rate approximately 59.94 Hz
// ============================================================================

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


    // ------------------------------------------------------------
    // Horizontal / vertical counters
    // ------------------------------------------------------------

    always @(posedge clk) begin

        if (!rst_n) begin

            h_count <= 10'd0;
            v_count <= 10'd0;

        end

        else begin

            if (h_count == 10'd799) begin

                h_count <= 10'd0;

                if (v_count == 10'd524)
                    v_count <= 10'd0;
                else
                    v_count <= v_count + 10'd1;

            end

            else begin

                h_count <= h_count + 10'd1;

            end

        end

    end


    // ------------------------------------------------------------
    // Visible display area
    // ------------------------------------------------------------

    assign video_active =

        (h_count < 10'd640) &&
        (v_count < 10'd480);


    // ------------------------------------------------------------
    // Horizontal sync
    //
    // Active low from 656 to 751.
    // ------------------------------------------------------------

    assign hsync = ~(

        (h_count >= 10'd656) &&
        (h_count <  10'd752)

    );


    // ------------------------------------------------------------
    // Vertical sync
    //
    // Active low on lines 490 and 491.
    // ------------------------------------------------------------

    assign vsync = ~(

        (v_count >= 10'd490) &&
        (v_count <  10'd492)

    );


    // ------------------------------------------------------------
    // One pulse at end of every complete VGA frame
    // ------------------------------------------------------------

    assign frame_tick =

        (h_count == 10'd799) &&
        (v_count == 10'd524);


endmodule


`default_nettype wire
