//=============================================================================
// Module: cdc_sync (contains cdc_bit_sync and cdc_toggle_handshake)
//
// Purpose:
//   Provides robust, glitch-free Clock Domain Crossing (CDC) primitives:
//     1. cdc_bit_sync: Classic 2-flip-flop synchronizer for quasi-static or
//        single-bit control pulses crossing between asynchronous clock domains.
//     2. cdc_toggle_handshake: Quasi-static toggle-based handshake protocol to
//        safely transfer multi-bit configuration buses across unrelated clocks.
//
// Why CDC Safety is Critical:
//   Directly synchronizing multi-bit buses with individual 2-flop synchronizers
//   causes "mixed-value corruption" due to physical route skew across bits: the
//   destination domain can capture a corrupt intermediate hybrid word containing
//   some bits from the old configuration and some from the new configuration.
//
//   cdc_toggle_handshake guarantees data integrity by keeping the multi-bit
//   holding register static and stable on the source domain while a single toggle
//   bit is safely synchronized across domains. The destination captures the bus
//   ONLY on the synchronized toggle edge, when data setup and hold requirements
//   are guaranteed to have been satisfied for multiple clock cycles.
//
// Protocol Limitation:
//   The source domain must not update or initiate a new transfer until the
//   destination acknowledges the current transfer (indicated by src_busy=0).
//=============================================================================

`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
// Primitive (a): 2-Flop Bit Synchronizer
//-----------------------------------------------------------------------------
module cdc_bit_sync #(
    parameter bit RESET_VAL = 1'b0
)(
    input  logic clk,
    input  logic rst_n,
    input  logic d_in,
    output logic q_out
);

    (* ASYNC_REG = "TRUE" *) logic sync_stage0;
    (* ASYNC_REG = "TRUE" *) logic sync_stage1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_stage0 <= RESET_VAL;
            sync_stage1 <= RESET_VAL;
        end else begin
            sync_stage0 <= d_in;
            sync_stage1 <= sync_stage0;
        end
    end

    assign q_out = sync_stage1;

endmodule


//-----------------------------------------------------------------------------
// Primitive (b): Multi-bit Toggle Handshake Synchronizer
//-----------------------------------------------------------------------------
module cdc_toggle_handshake #(
    parameter int WIDTH = 27
)(
    // Source clock domain
    input  logic             src_clk,
    input  logic             src_rst_n,
    input  logic [WIDTH-1:0] src_data,
    input  logic             src_req,
    output logic             src_busy,

    // Destination clock domain
    input  logic             dst_clk,
    input  logic             dst_rst_n,
    output logic [WIDTH-1:0] dst_data,
    output logic             dst_valid
);

    // Source domain registers
    logic [WIDTH-1:0] src_data_hold;
    logic             src_req_toggle;
    logic             src_ack_sync;
    logic             src_ack_d1;

    // Destination domain registers
    logic             dst_req_sync;
    logic             dst_req_d1;
    logic             dst_ack_toggle;
    logic [WIDTH-1:0] dst_data_reg;
    logic             dst_valid_reg;

    // Edge detect on destination
    logic dst_req_edge;
    assign dst_req_edge = dst_req_sync ^ dst_req_d1;

    // Edge detect on source
    logic src_ack_edge;
    assign src_ack_edge = src_ack_sync ^ src_ack_d1;

    //-------------------------------------------------------------------------
    // Synchronizers
    //-------------------------------------------------------------------------
    // Synchronize request toggle to destination clock
    cdc_bit_sync #(.RESET_VAL(1'b0)) sync_req_to_dst (
        .clk  (dst_clk),
        .rst_n(dst_rst_n),
        .d_in (src_req_toggle),
        .q_out(dst_req_sync)
    );

    // Synchronize acknowledge toggle back to source clock
    cdc_bit_sync #(.RESET_VAL(1'b0)) sync_ack_to_src (
        .clk  (src_clk),
        .rst_n(src_rst_n),
        .d_in (dst_ack_toggle),
        .q_out(src_ack_sync)
    );

    //-------------------------------------------------------------------------
    // Source Domain Logic
    //-------------------------------------------------------------------------
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_data_hold  <= '0;
            src_req_toggle <= 1'b0;
            src_busy       <= 1'b0;
            src_ack_d1     <= 1'b0;
        end else begin
            src_ack_d1 <= src_ack_sync;

            if (src_req && !src_busy) begin
                src_data_hold  <= src_data;
                src_req_toggle <= ~src_req_toggle;
                src_busy       <= 1'b1;
            end else if (src_busy && src_ack_edge) begin
                src_busy <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Destination Domain Logic
    //-------------------------------------------------------------------------
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_req_d1     <= 1'b0;
            dst_ack_toggle <= 1'b0;
            dst_data_reg   <= '0;
            dst_valid_reg  <= 1'b0;
        end else begin
            dst_req_d1 <= dst_req_sync;

            if (dst_req_edge) begin
                // Safely capture multi-bit data holding register
                dst_data_reg   <= src_data_hold;
                dst_valid_reg  <= 1'b1;
                dst_ack_toggle <= ~dst_ack_toggle;
            end else begin
                dst_valid_reg  <= 1'b0;
            end
        end
    end

    assign dst_data  = dst_data_reg;
    assign dst_valid = dst_valid_reg;

endmodule
