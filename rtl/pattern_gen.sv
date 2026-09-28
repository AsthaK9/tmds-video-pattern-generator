//=============================================================================
// Module: pattern_gen
//
// Purpose:
//   Generates synthetic 24-bit RGB test video patterns based on raster
//   coordinates (X, Y) and register control settings:
//     - Pattern 0: Standard 8 Color Bars (White, Yellow, Cyan, Green, Magenta, Red, Blue, Black).
//     - Pattern 1: Horizontal smooth gradient (grayscale ramp from 0 to 255).
//     - Pattern 2: Checkerboard pattern (square size configurable via parameter).
//     - Pattern 3: Solid color defined by 24-bit configuration register (solid_rgb).
//
// Ports:
//   - clk         : Pixel clock.
//   - rst_n       : Active-low asynchronous reset (sync deasserted).
//   - pattern_sel : 2-bit pattern selector.
//   - enable      : Display enable (1 = pattern active, 0 = black video with active sync).
//   - solid_rgb   : 24-bit solid color configuration {R[7:0], G[7:0], B[7:0]}.
//   - hsync_in    : Horizontal sync input from video_timing.
//   - vsync_in    : Vertical sync input from video_timing.
//   - de_in       : Data enable input from video_timing.
//   - x_in        : Horizontal coordinate [11:0].
//   - y_in        : Vertical coordinate [11:0].
//   - r           : Registered 8-bit Red channel output.
//   - g           : Registered 8-bit Green channel output.
//   - b           : Registered 8-bit Blue channel output.
//   - hsync_out   : Registered horizontal sync (delayed by 1 cycle to match RGB).
//   - vsync_out   : Registered vertical sync (delayed by 1 cycle to match RGB).
//   - de_out      : Registered data enable (delayed by 1 cycle to match RGB).
//
// Latency:
//   Exactly 1 clock cycle register latency from input coordinates and timing
//   signals to all output ports.
//
// Key Design Decisions:
//   - Sync signals (hsync, vsync, de) are pipelined alongside pixel data in
//     matching registers to maintain strict phase alignment across all pipeline stages.
//   - When enable=0, active video is forced to black (0,0,0) while DE and sync
//     timing remain intact so TMDS downstream encoders continue transmitting valid
//     timing control tokens.
//=============================================================================

`timescale 1ns / 1ps

module pattern_gen #(
    parameter int H_ACTIVE    = 1280,
    parameter int V_ACTIVE    = 720,
    parameter int SQUARE_SIZE = 16
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [1:0]  pattern_sel,
    input  logic        enable,
    input  logic [23:0] solid_rgb,
    input  logic        hsync_in,
    input  logic        vsync_in,
    input  logic        de_in,
    input  logic [11:0] x_in,
    input  logic [11:0] y_in,
    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b,
    output logic        hsync_out,
    output logic        vsync_out,
    output logic        de_out
);

    // Combinational next-pixel values
    logic [7:0] r_comb;
    logic [7:0] g_comb;
    logic [7:0] b_comb;

    // Pattern 0: Color bars calculation
    localparam int BAR_WIDTH = (H_ACTIVE >= 8) ? (H_ACTIVE / 8) : 1;
    logic [2:0] bar_idx;
    assign bar_idx = (x_in < H_ACTIVE) ? 3'(x_in / BAR_WIDTH) : 3'd0;

    logic [7:0] cb_r, cb_g, cb_b;
    always_comb begin
        case (bar_idx)
            3'd0:    begin cb_r = 8'hFF; cb_g = 8'hFF; cb_b = 8'hFF; end // White
            3'd1:    begin cb_r = 8'hFF; cb_g = 8'hFF; cb_b = 8'h00; end // Yellow
            3'd2:    begin cb_r = 8'h00; cb_g = 8'hFF; cb_b = 8'hFF; end // Cyan
            3'd3:    begin cb_r = 8'h00; cb_g = 8'hFF; cb_b = 8'h00; end // Green
            3'd4:    begin cb_r = 8'hFF; cb_g = 8'h00; cb_b = 8'hFF; end // Magenta
            3'd5:    begin cb_r = 8'hFF; cb_g = 8'h00; cb_b = 8'h00; end // Red
            3'd6:    begin cb_r = 8'h00; cb_g = 8'h00; cb_b = 8'hFF; end // Blue
            default: begin cb_r = 8'h00; cb_g = 8'h00; cb_b = 8'h00; end // Black
        endcase
    end

    // Pattern 1: Horizontal gradient calculation
    logic [7:0] grad_val;
    assign grad_val = 8'((20'(x_in) * 20'd255) / ((H_ACTIVE > 1) ? (H_ACTIVE - 1) : 1));

    // Pattern 2: Checkerboard calculation
    logic check_bit;
    assign check_bit = ((x_in / SQUARE_SIZE) ^ (y_in / SQUARE_SIZE)) & 1'b1;

    // Pattern selection multiplexer
    always_comb begin
        if (!enable || !de_in) begin
            r_comb = 8'h00;
            g_comb = 8'h00;
            b_comb = 8'h00;
        end else begin
            case (pattern_sel)
                2'b00: begin // Color Bars
                    r_comb = cb_r;
                    g_comb = cb_g;
                    b_comb = cb_b;
                end
                2'b01: begin // Horizontal Gradient
                    r_comb = grad_val;
                    g_comb = grad_val;
                    b_comb = grad_val;
                end
                2'b10: begin // Checkerboard
                    r_comb = check_bit ? 8'hFF : 8'h00;
                    g_comb = check_bit ? 8'hFF : 8'h00;
                    b_comb = check_bit ? 8'hFF : 8'h00;
                end
                2'b11: begin // Solid Color
                    r_comb = solid_rgb[23:16];
                    g_comb = solid_rgb[15:8];
                    b_comb = solid_rgb[7:0];
                end
            endcase
        end
    end

    // 1-cycle pipeline register for data and control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r         <= 8'h00;
            g         <= 8'h00;
            b         <= 8'h00;
            hsync_out <= 1'b0;
            vsync_out <= 1'b0;
            de_out    <= 1'b0;
        end else begin
            r         <= r_comb;
            g         <= g_comb;
            b         <= b_comb;
            hsync_out <= hsync_in;
            vsync_out <= vsync_in;
            de_out    <= de_in;
        end
    end

endmodule
