//=============================================================================
// Module: video_timing
//
// Purpose:
//   Generates raster video timing signals (HSYNC, VSYNC, DE, frame_start, and
//   pixel coordinates X, Y) for standard video resolutions (default 720p60)
//   or arbitrary parameterized smaller geometries for simulation.
//
// Ports:
//   - clk         : Pixel clock input (e.g. 74.25 MHz for 720p60).
//   - rst_n       : Active-low asynchronous reset (sync deasserted).
//   - hsync       : Horizontal synchronization pulse (polarity set by H_POL).
//   - vsync       : Vertical synchronization pulse (polarity set by V_POL).
//   - de          : Data enable (high during active display region).
//   - frame_start : Single-cycle pulse at pixel (x=0, y=0) of each active frame.
//   - x           : Horizontal pixel coordinate [0 .. H_ACTIVE-1] (0 outside active).
//   - y           : Vertical line coordinate [0 .. V_ACTIVE-1] (0 outside active).
//
// Latency:
//   1 clock cycle register latency from internal counters to all output ports.
//
// Key Design Decisions:
//   - All primary outputs are registered directly at the top level of this module
//     to prevent glitching on sync/DE lines and ensure clean timing closure.
//   - Pixel coordinates (X, Y) are clamped to 0 outside the active region to
//     prevent downstream arithmetic logic from executing on non-zero porch values.
//   - Parametric geometry enables fast simulation verification using a compact
//     preset (e.g. 64x48) while synthesizing to production 720p60 standards.
//=============================================================================

`timescale 1ns / 1ps

module video_timing #(
    parameter int H_ACTIVE = 1280,
    parameter int H_FP     = 110,
    parameter int H_SYNC   = 40,
    parameter int H_BP     = 220,
    parameter int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP, // 1650
    parameter int V_ACTIVE = 720,
    parameter int V_FP     = 5,
    parameter int V_SYNC   = 5,
    parameter int V_BP     = 20,
    parameter int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP, // 750
    parameter bit H_POL    = 1'b1, // 1 = positive polarity, 0 = negative
    parameter bit V_POL    = 1'b1  // 1 = positive polarity, 0 = negative
)(
    input  logic        clk,
    input  logic        rst_n,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        frame_start,
    output logic [11:0] x,
    output logic [11:0] y
);

    // Coordinate counter widths
    localparam int H_WIDTH = $clog2(H_TOTAL + 1);
    localparam int V_WIDTH = $clog2(V_TOTAL + 1);

    logic [H_WIDTH-1:0] h_cnt;
    logic [V_WIDTH-1:0] v_cnt;

    // Next-state combinational signals
    logic [H_WIDTH-1:0] h_cnt_next;
    logic [V_WIDTH-1:0] v_cnt_next;

    always_comb begin
        if (h_cnt == H_TOTAL - 1) begin
            h_cnt_next = '0;
            if (v_cnt == V_TOTAL - 1) begin
                v_cnt_next = '0;
            end else begin
                v_cnt_next = v_cnt + 1'b1;
            end
        end else begin
            h_cnt_next = h_cnt + 1'b1;
            v_cnt_next = v_cnt;
        end
    end

    // Sequential counter and output registers (1-cycle latency)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt       <= '0;
            v_cnt       <= '0;
            hsync       <= ~H_POL;
            vsync       <= ~V_POL;
            de          <= 1'b0;
            frame_start <= 1'b0;
            x           <= 12'd0;
            y           <= 12'd0;
        end else begin
            h_cnt <= h_cnt_next;
            v_cnt <= v_cnt_next;

            // Generate HSYNC
            if (h_cnt >= (H_ACTIVE + H_FP) && h_cnt < (H_ACTIVE + H_FP + H_SYNC)) begin
                hsync <= H_POL;
            end else begin
                hsync <= ~H_POL;
            end

            // Generate VSYNC
            if (v_cnt >= (V_ACTIVE + V_FP) && v_cnt < (V_ACTIVE + V_FP + V_SYNC)) begin
                vsync <= V_POL;
            end else begin
                vsync <= ~V_POL;
            end

            // Generate DE and (X, Y)
            if (h_cnt < H_ACTIVE && v_cnt < V_ACTIVE) begin
                de <= 1'b1;
                x  <= 12'(h_cnt);
                y  <= 12'(v_cnt);
            end else begin
                de <= 1'b0;
                x  <= 12'd0;
                y  <= 12'd0;
            end

            // Single-cycle pulse at start of active display frame
            if (h_cnt == 0 && v_cnt == 0) begin
                frame_start <= 1'b1;
            end else begin
                frame_start <= 1'b0;
            end
        end
    end

endmodule
