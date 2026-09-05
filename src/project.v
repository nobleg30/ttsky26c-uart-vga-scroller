/*
 * UART-programmable VGA scrolling text display for Tiny Tapeout SKY26C
 *
 * Clock    : 25.175 MHz
 * UART     : 9600 baud, 8-N-1
 * UART RX  : ui_in[3]
 * VGA      : uo_out[7:0], TinyVGA RGB222 + HSYNC/VSYNC
 *
 * Message length : 32 characters maximum
 * Font           : 5x7, scaled 4x
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
    // Storage = 32 x 6 = 192 bits
    // ============================================================

    reg [5:0] msg_mem [0:31];

    // 6 bits are required because msg_len/write_ptr must represent 32.
    reg [5:0] msg_len;
    reg [5:0] write_ptr;

    integer i;


    // ------------------------------------------------------------
    // ASCII to compact 6-bit code
    // ------------------------------------------------------------

    function [5:0] ascii_to_code;

        input [7:0] ascii;

        begin

            if ((ascii >= 8'h41) &&
                (ascii <= 8'h5A)) begin

                ascii_to_code = ascii[5:0];

            end

            else if ((ascii >= 8'h61) &&
                     (ascii <= 8'h7A)) begin

                ascii_to_code =
                    ascii[5:0] - 6'd32;

            end

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
    // ------------------------------------------------------------

    always @(posedge clk) begin

        if (!rst_n) begin

            msg_len   <= 6'd0;
            write_ptr <= 6'd0;

            for (i = 0; i < 32; i = i + 1)
                msg_mem[i] <= 6'd0;

        end

        else begin

            if (rx_valid) begin

                if ((rx_data == 8'h0D) ||
                    (rx_data == 8'h0A)) begin

                    write_ptr <= 6'd0;

                end

                else if ((rx_data >= 8'h20) &&
                         (rx_data <= 8'h7E)) begin

                    if (write_ptr < 6'd32) begin

                        msg_mem[write_ptr[4:0]]
                            <= ascii_to_code(rx_data);

                        msg_len
                            <= write_ptr + 6'd1;

                        write_ptr
                            <= write_ptr + 6'd1;

                    end

                end

            end

        end

    end


    // ============================================================
    // SCROLL CONTROL
    //
    // 4x font scaling uses a 32-pixel-wide character cell.
    // Maximum message width = 32 x 32 = 1024 pixels.
    //
    // The full scroll distance is therefore:
    //
    //     640 + message_width
    //
    // which can reach 1664 pixels.
    //
    // scroll_pos and scroll_limit still fit in 11 bits, but
    // h_count + scroll_pos can reach 2462, so x_sum/rel_x
    // are widened to 12 bits.
    // ============================================================

    reg [10:0] scroll_pos;

    wire [10:0] msg_width;
    wire [10:0] scroll_limit;
    wire [10:0] scroll_step;

    wire rx_enter;


    // 32 pixels per character:
    // msg_width = msg_len << 5
    assign msg_width =
        {msg_len, 5'b00000};


    assign scroll_limit =
        11'd640 + msg_width;


    assign scroll_step =
        11'd1 << ui_in[1:0];


    assign rx_enter =
        rx_valid &&
        (
            (rx_data == 8'h0D) ||
            (rx_data == 8'h0A)
        );


    always @(posedge clk) begin

        if (!rst_n) begin

            scroll_pos <= 11'd0;

        end

        else if (rx_enter) begin

            scroll_pos <= 11'd0;

        end

        else if (
            frame_tick &&
            !ui_in[2] &&
            (msg_len != 6'd0)
        ) begin

            if (
                (scroll_pos + scroll_step)
                >= scroll_limit
            ) begin

                scroll_pos <= 11'd0;

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
    // Character cell : 32 x 32 pixels
    // Font           : 5 x 7
    // Scale          : 4 x
    //
    // Visible glyph  : 20 x 28 pixels
    //
    // The 32x32 cell leaves margins around the scaled glyph.
    // ============================================================

    wire [11:0] x_sum;
    wire [11:0] rel_x;

    wire [4:0] char_index;

    wire [2:0] glyph_col;
    wire [2:0] glyph_row;

    wire [5:0] current_code;

    wire [34:0] glyph_bits;
    wire [4:0]  glyph_row_bits;


    assign x_sum =
        {2'b00, h_count}
        +
        {1'b0, scroll_pos};


    assign rel_x =
        x_sum - 12'd640;


    // 32 pixels per character -> divide by 32.
    // Five index bits select one of 32 message entries.
    assign char_index =
        rel_x[9:5];


    // 4x horizontal scaling -> divide cell x coordinate by 4.
    assign glyph_col =
        rel_x[4:2];


    // Text window begins at y=224, which is aligned to 32 pixels.
    // v_count[4:2] therefore directly gives rows 0..7.
    assign glyph_row =
        v_count[4:2];


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
    //
    // 32-pixel-high cell centered vertically around the same
    // region used by the previous 2x version.
    //
    // y = 224 ... 255
    // ============================================================

    wire text_window;
    wire pixel_on;


    assign text_window =

        video_active &&

        (v_count >= 10'd224) &&
        (v_count <  10'd256) &&

        (x_sum >= 12'd640) &&

        (rel_x < {1'b0, msg_width}) &&

        ({1'b0, char_index} < msg_len);


    assign pixel_on =
        text_window &&
        glyph_pixel &&
        ena;


    // ============================================================
    // VGA COLOUR SELECTION
    //
    // ui_in[5:4] : text colour preset
    //
    //   00 = White
    //   01 = Yellow
    //   10 = Cyan
    //   11 = Magenta
    //
    // ui_in[7:6] : background colour preset
    //
    //   00 = Black
    //   01 = Dark blue
    //   10 = Dark green
    //   11 = Dark red
    //
    // RGB format below is:
    //
    //   { R[1:0], G[1:0], B[1:0] }
    //
    // During VGA blanking, RGB is forced to black.
    // ============================================================

    reg [5:0] text_rgb;
    reg [5:0] background_rgb;

    wire [5:0] selected_rgb;

    wire [1:0] red;
    wire [1:0] green;
    wire [1:0] blue;


    always @* begin

        case (ui_in[5:4])

            2'b00:
                text_rgb = 6'b11_11_11;  // white

            2'b01:
                text_rgb = 6'b11_11_00;  // yellow

            2'b10:
                text_rgb = 6'b00_11_11;  // cyan

            default:
                text_rgb = 6'b11_00_11;  // magenta

        endcase

    end


    always @* begin

        case (ui_in[7:6])

            2'b00:
                background_rgb = 6'b00_00_00;  // black

            2'b01:
                background_rgb = 6'b00_00_01;  // dark blue

            2'b10:
                background_rgb = 6'b00_01_00;  // dark green

            default:
                background_rgb = 6'b01_00_00;  // dark red

        endcase

    end


    assign selected_rgb =
        !video_active
        ? 6'b00_00_00
        : (
            pixel_on
            ? text_rgb
            : background_rgb
        );


    assign red =
        selected_rgb[5:4];


    assign green =
        selected_rgb[3:2];


    assign blue =
        selected_rgb[1:0];


    // ============================================================
    // TinyVGA OUTPUT MAPPING
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
    // ============================================================

    assign uio_out =
        8'b00000000;

    assign uio_oe =
        8'b00000000;


    wire _unused;

    assign _unused =
        &{
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
    // ============================================================

    function [34:0] glyph35;

        input [5:0] code;

        begin

            case (code)

                6'd0:
                    glyph35 =
                    35'b00000_00000_00000_00000_00000_00000_00000;

                6'd1:
                    glyph35 =
                    35'b01110_10001_10001_11111_10001_10001_10001;

                6'd2:
                    glyph35 =
                    35'b11110_10001_10001_11110_10001_10001_11110;

                6'd3:
                    glyph35 =
                    35'b01111_10000_10000_10000_10000_10000_01111;

                6'd4:
                    glyph35 =
                    35'b11110_10001_10001_10001_10001_10001_11110;

                6'd5:
                    glyph35 =
                    35'b11111_10000_10000_11110_10000_10000_11111;

                6'd6:
                    glyph35 =
                    35'b11111_10000_10000_11110_10000_10000_10000;

                6'd7:
                    glyph35 =
                    35'b01111_10000_10000_10111_10001_10001_01111;

                6'd8:
                    glyph35 =
                    35'b10001_10001_10001_11111_10001_10001_10001;

                6'd9:
                    glyph35 =
                    35'b11111_00100_00100_00100_00100_00100_11111;

                6'd10:
                    glyph35 =
                    35'b00111_00010_00010_00010_00010_10010_01100;

                6'd11:
                    glyph35 =
                    35'b10001_10010_10100_11000_10100_10010_10001;

                6'd12:
                    glyph35 =
                    35'b10000_10000_10000_10000_10000_10000_11111;

                6'd13:
                    glyph35 =
                    35'b10001_11011_10101_10101_10001_10001_10001;

                6'd14:
                    glyph35 =
                    35'b10001_11001_10101_10011_10001_10001_10001;

                6'd15:
                    glyph35 =
                    35'b01110_10001_10001_10001_10001_10001_01110;

                6'd16:
                    glyph35 =
                    35'b11110_10001_10001_11110_10000_10000_10000;

                6'd17:
                    glyph35 =
                    35'b01110_10001_10001_10001_10101_10010_01101;

                6'd18:
                    glyph35 =
                    35'b11110_10001_10001_11110_10100_10010_10001;

                6'd19:
                    glyph35 =
                    35'b01111_10000_10000_01110_00001_00001_11110;

                6'd20:
                    glyph35 =
                    35'b11111_00100_00100_00100_00100_00100_00100;

                6'd21:
                    glyph35 =
                    35'b10001_10001_10001_10001_10001_10001_01110;

                6'd22:
                    glyph35 =
                    35'b10001_10001_10001_10001_10001_01010_00100;

                6'd23:
                    glyph35 =
                    35'b10001_10001_10001_10101_10101_10101_01010;

                6'd24:
                    glyph35 =
                    35'b10001_10001_01010_00100_01010_10001_10001;

                6'd25:
                    glyph35 =
                    35'b10001_10001_01010_00100_00100_00100_00100;

                6'd26:
                    glyph35 =
                    35'b11111_00001_00010_00100_01000_10000_11111;

                6'd27:
                    glyph35 =
                    35'b01110_10001_10011_10101_11001_10001_01110;

                6'd28:
                    glyph35 =
                    35'b00100_01100_00100_00100_00100_00100_01110;

                6'd29:
                    glyph35 =
                    35'b01110_10001_00001_00010_00100_01000_11111;

                6'd30:
                    glyph35 =
                    35'b11110_00001_00001_01110_00001_00001_11110;

                6'd31:
                    glyph35 =
                    35'b00010_00110_01010_10010_11111_00010_00010;

                6'd32:
                    glyph35 =
                    35'b11111_10000_10000_11110_00001_00001_11110;

                6'd33:
                    glyph35 =
                    35'b01110_10000_10000_11110_10001_10001_01110;

                6'd34:
                    glyph35 =
                    35'b11111_00001_00010_00100_01000_01000_01000;

                6'd35:
                    glyph35 =
                    35'b01110_10001_10001_01110_10001_10001_01110;

                6'd36:
                    glyph35 =
                    35'b01110_10001_10001_01111_00001_00001_01110;

                6'd37:
                    glyph35 =
                    35'b00000_00000_00000_00000_00000_00110_00110;

                6'd38:
                    glyph35 =
                    35'b00000_00000_00000_11111_00000_00000_00000;

                6'd39:
                    glyph35 =
                    35'b00100_00100_00100_00100_00100_00000_00100;

                6'd40:
                    glyph35 =
                    35'b01110_10001_00001_00010_00100_00000_00100;

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
// ============================================================================

module uart_rx (

    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,

    output wire [7:0] data_out,
    output wire       data_valid

);


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


    assign data_out =
        rx_shift;


    assign data_valid =

        (state == S_STOP) &&

        (
            clk_count ==
            (CLKS_PER_BIT - 12'd1)
        ) &&

        rx_sync;


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


    always @(posedge clk) begin

        if (!rst_n) begin

            state     <= S_IDLE;

            clk_count <= 12'd0;
            bit_index <= 3'd0;

            rx_shift  <= 8'd0;

        end

        else begin

            case (state)

                S_IDLE: begin

                    clk_count <= 12'd0;
                    bit_index <= 3'd0;

                    if (!rx_sync)
                        state <= S_START;

                end


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


    assign video_active =

        (h_count < 10'd640) &&
        (v_count < 10'd480);


    assign hsync = ~(

        (h_count >= 10'd656) &&
        (h_count <  10'd752)

    );


    assign vsync = ~(

        (v_count >= 10'd490) &&
        (v_count <  10'd492)

    );


    assign frame_tick =

        (h_count == 10'd799) &&
        (v_count == 10'd524);


endmodule


`default_nettype wire
