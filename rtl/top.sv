//=============================================================================
// Module: top
//
// Purpose:
//   Top-level integration module for the Video Test-Pattern Generator with
//   DVI TMDS Parallel Encoding and CDC-Safe Register Bank.
//
// Clocks & Resets:
//   - sys_clk     : System bus clock domain (e.g. 50 MHz AXI/APB/generic CPU bus).
//   - sys_rst_n   : Asynchronous active-low reset for sys domain (sync deasserted).
//   - pixel_clk   : Video pixel clock domain (e.g. 74.25 MHz for 720p60).
//   - pixel_rst_n : Asynchronous active-low reset for pixel domain (sync deasserted).
//
// Primary Ports:
//   - Register interface: reg_addr, reg_wdata, reg_wen, reg_rdata.
//   - TMDS parallel 10-bit channels:
//       * tmds_ch0: Blue channel (carries HSYNC on c0, VSYNC on c1 during blanking).
//       * tmds_ch1: Green channel (c0=0, c1=0).
//       * tmds_ch2: Red channel (c0=0, c1=0).
//   - Debug video ports: debug_hsync, debug_vsync, debug_de.
//
// Pipeline Latency:
//   - video_timing: 1 cycle (counters -> timing regs)
//   - pattern_gen : 1 cycle (RGB & pipelined sync regs)
//   - tmds_encoder: 1 cycle (TMDS 10-bit symbols)
//   Total raster pipeline latency: 3 clock cycles from counter state to TMDS symbols.
//=============================================================================

`timescale 1ns / 1ps

module top #(
    parameter int H_ACTIVE    = 1280,
    parameter int H_FP        = 110,
    parameter int H_SYNC      = 40,
    parameter int H_BP        = 220,
    parameter int V_ACTIVE    = 720,
    parameter int V_FP        = 5,
    parameter int V_SYNC      = 5,
    parameter int V_BP        = 20,
    parameter int SQUARE_SIZE = 16
)(
    // Clocks and Resets
    input  logic        sys_clk,
    input  logic        sys_rst_n,
    input  logic        pixel_clk,
    input  logic        pixel_rst_n,

    // System Register Bus Interface
    input  logic [3:0]  reg_addr,
    input  logic [31:0] reg_wdata,
    input  logic        reg_wen,
    output logic [31:0] reg_rdata,

    // TMDS 10-Bit Encoded Parallel Channels
    output logic [9:0]  tmds_ch0, // Blue  + HSYNC/VSYNC
    output logic [9:0]  tmds_ch1, // Green
    output logic [9:0]  tmds_ch2, // Red

    // Debug Raster Timing Outputs
    output logic        debug_hsync,
    output logic        debug_vsync,
    output logic        debug_de
);

    //-------------------------------------------------------------------------
    // 1. Video Raster Timing Generator (pixel_clk)
    //-------------------------------------------------------------------------
    logic        vt_hsync;
    logic        vt_vsync;
    logic        vt_de;
    logic        vt_frame_start;
    logic [11:0] vt_x;
    logic [11:0] vt_y;

    video_timing #(
        .H_ACTIVE(H_ACTIVE),
        .H_FP    (H_FP),
        .H_SYNC  (H_SYNC),
        .H_BP    (H_BP),
        .V_ACTIVE(V_ACTIVE),
        .V_FP    (V_FP),
        .V_SYNC  (V_SYNC),
        .V_BP    (V_BP)
    ) u_video_timing (
        .clk        (pixel_clk),
        .rst_n      (pixel_rst_n),
        .hsync      (vt_hsync),
        .vsync      (vt_vsync),
        .de         (vt_de),
        .frame_start(vt_frame_start),
        .x          (vt_x),
        .y          (vt_y)
    );

    //-------------------------------------------------------------------------
    // 2. Register Bank with CDC Toggle Handshake
    //-------------------------------------------------------------------------
    logic [1:0]  cfg_pattern_sel;
    logic        cfg_enable;
    logic [23:0] cfg_solid_rgb;

    reg_bank u_reg_bank (
        .sys_clk          (sys_clk),
        .sys_rst_n        (sys_rst_n),
        .reg_addr         (reg_addr),
        .reg_wdata        (reg_wdata),
        .reg_wen          (reg_wen),
        .reg_rdata        (reg_rdata),

        .pixel_clk        (pixel_clk),
        .pixel_rst_n      (pixel_rst_n),
        .pixel_frame_start(vt_frame_start),

        .cfg_pattern_sel  (cfg_pattern_sel),
        .cfg_enable       (cfg_enable),
        .cfg_solid_rgb    (cfg_solid_rgb)
    );

    //-------------------------------------------------------------------------
    // 3. Test Pattern Generator (pixel_clk)
    //-------------------------------------------------------------------------
    logic [7:0] pat_r;
    logic [7:0] pat_g;
    logic [7:0] pat_b;
    logic       pat_hsync;
    logic       pat_vsync;
    logic       pat_de;

    pattern_gen #(
        .H_ACTIVE   (H_ACTIVE),
        .V_ACTIVE   (V_ACTIVE),
        .SQUARE_SIZE(SQUARE_SIZE)
    ) u_pattern_gen (
        .clk        (pixel_clk),
        .rst_n      (pixel_rst_n),
        .pattern_sel(cfg_pattern_sel),
        .enable     (cfg_enable),
        .solid_rgb  (cfg_solid_rgb),
        .hsync_in   (vt_hsync),
        .vsync_in   (vt_vsync),
        .de_in      (vt_de),
        .x_in       (vt_x),
        .y_in       (vt_y),
        .r          (pat_r),
        .g          (pat_g),
        .b          (pat_b),
        .hsync_out  (pat_hsync),
        .vsync_out  (pat_vsync),
        .de_out     (pat_de)
    );

    // Align debug timing outputs with registered TMDS encoder outputs (1-cycle latency)
    always_ff @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            debug_hsync <= 1'b0;
            debug_vsync <= 1'b0;
            debug_de    <= 1'b0;
        end else begin
            debug_hsync <= pat_hsync;
            debug_vsync <= pat_vsync;
            debug_de    <= pat_de;
        end
    end

    //-------------------------------------------------------------------------
    // 4. TMDS 8b/10b Encoders (3 Channels instantiated directly)
    //-------------------------------------------------------------------------
    // Channel 0: Blue component + HSYNC on c0, VSYNC on c1
    tmds_encoder u_tmds_ch0 (
        .clk          (pixel_clk),
        .rst_n        (pixel_rst_n),
        .din          (pat_b),
        .c0           (pat_hsync),
        .c1           (pat_vsync),
        .de           (pat_de),
        .dout         (tmds_ch0),
        .disparity_out()
    );

    // Channel 1: Green component + c0=0, c1=0
    tmds_encoder u_tmds_ch1 (
        .clk          (pixel_clk),
        .rst_n        (pixel_rst_n),
        .din          (pat_g),
        .c0           (1'b0),
        .c1           (1'b0),
        .de           (pat_de),
        .dout         (tmds_ch1),
        .disparity_out()
    );

    // Channel 2: Red component + c0=0, c1=0
    tmds_encoder u_tmds_ch2 (
        .clk          (pixel_clk),
        .rst_n        (pixel_rst_n),
        .din          (pat_r),
        .c0           (1'b0),
        .c1           (1'b0),
        .de           (pat_de),
        .dout         (tmds_ch2),
        .disparity_out()
    );

endmodule
