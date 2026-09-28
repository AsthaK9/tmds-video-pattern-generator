//=============================================================================
// Module: tmds_encoder
//
// Purpose:
//   Standard DVI 1.0 compliant TMDS encoder for a single 8-bit color channel.
//   Performs 2-stage encoding:
//     Stage 1: Transition minimization (conditional XOR / XNOR).
//     Stage 2: DC balancing with running disparity tracking and control tokens.
//
// Ports:
//   - clk           : Pixel clock.
//   - rst_n         : Active-low asynchronous reset (sync deasserted).
//   - din           : 8-bit input color data.
//   - c0, c1        : 2-bit control inputs (e.g. HSYNC/VSYNC on Blue channel).
//   - de            : Data enable (high for active video, low for blanking).
//   - dout          : Registered 10-bit TMDS encoded symbol output.
//   - disparity_out : Registered signed 5-bit running disparity (for telemetry).
//
// Latency:
//   1 clock cycle register latency (registered dout and disparity).
//
// Key Design Decisions:
//   - Fully registered outputs ensure zero combinational glitching on the TMDS
//     parallel output bus prior to 10:1 serialization.
//   - Implements the exact DVI 1.0 DC-balancing rules: disparity is cleared to
//     0 during blanking (de=0) and control tokens maintain even DC balance.
//   - Running disparity arithmetic is strictly bounded between -8 and +8.
//=============================================================================

`timescale 1ns / 1ps

module tmds_encoder (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [7:0]       din,
    input  logic             c0,
    input  logic             c1,
    input  logic             de,
    output logic [9:0]       dout,
    output logic signed [4:0] disparity_out
);

    // Control tokens (DVI 1.0 Table 3-3)
    localparam logic [9:0] CTRL_00 = 10'b1101010100;
    localparam logic [9:0] CTRL_01 = 10'b0010101011;
    localparam logic [9:0] CTRL_10 = 10'b0101010100;
    localparam logic [9:0] CTRL_11 = 10'b1010101011;

    // Helper function: count ones in an 8-bit vector
    function automatic [3:0] count_ones_8(input [7:0] val);
        count_ones_8 = val[0] + val[1] + val[2] + val[3] +
                       val[4] + val[5] + val[6] + val[7];
    endfunction

    // Stage 1: Transition Minimization
    logic [3:0] din_ones;
    logic [8:0] q_m;

    assign din_ones = count_ones_8(din);

    always_comb begin
        if ((din_ones > 4) || (din_ones == 4 && din[0] == 1'b0)) begin
            // XNOR mode (q_m[8] = 0)
            q_m[0] = din[0];
            q_m[1] = din[1] ~^ q_m[0];
            q_m[2] = din[2] ~^ q_m[1];
            q_m[3] = din[3] ~^ q_m[2];
            q_m[4] = din[4] ~^ q_m[3];
            q_m[5] = din[5] ~^ q_m[4];
            q_m[6] = din[6] ~^ q_m[5];
            q_m[7] = din[7] ~^ q_m[6];
            q_m[8] = 1'b0;
        end else begin
            // XOR mode (q_m[8] = 1)
            q_m[0] = din[0];
            q_m[1] = din[1] ^ q_m[0];
            q_m[2] = din[2] ^ q_m[1];
            q_m[3] = din[3] ^ q_m[2];
            q_m[4] = din[4] ^ q_m[3];
            q_m[5] = din[5] ^ q_m[4];
            q_m[6] = din[6] ^ q_m[5];
            q_m[7] = din[7] ^ q_m[6];
            q_m[8] = 1'b1;
        end
    end

    // Stage 2: DC Balancing
    logic [3:0] q_m_ones;
    logic [3:0] q_m_zeros;
    assign q_m_ones  = count_ones_8(q_m[7:0]);
    assign q_m_zeros = 4'd8 - q_m_ones;

    // Running disparity register
    logic signed [4:0] disparity;
    assign disparity_out = disparity;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout      <= CTRL_00;
            disparity <= 5'sd0;
        end else begin
            if (!de) begin
                // Blanking period: send control tokens and clear running disparity
                disparity <= 5'sd0;
                case ({c1, c0})
                    2'b00: dout <= CTRL_00;
                    2'b01: dout <= CTRL_01;
                    2'b10: dout <= CTRL_10;
                    2'b11: dout <= CTRL_11;
                endcase
            end else begin
                // Active video period
                if (disparity == 5'sd0 || q_m_ones == q_m_zeros) begin
                    dout[9]   <= ~q_m[8];
                    dout[8]   <= q_m[8];
                    dout[7:0] <= (q_m[8]) ? q_m[7:0] : ~q_m[7:0];

                    if (q_m[8] == 1'b0) begin
                        disparity <= disparity + signed'(5'(q_m_zeros - q_m_ones));
                    end else begin
                        disparity <= disparity + signed'(5'(q_m_ones - q_m_zeros));
                    end
                end else begin
                    // Decision based on running disparity sign and q_m disparity
                    if ((disparity > 5'sd0 && q_m_ones > q_m_zeros) ||
                        (disparity < 5'sd0 && q_m_zeros > q_m_ones)) begin
                        dout[9]   <= 1'b1;
                        dout[8]   <= q_m[8];
                        dout[7:0] <= ~q_m[7:0];
                        disparity <= disparity + signed'((q_m[8] ? 5'sd2 : 5'sd0)) +
                                     signed'(5'(q_m_zeros - q_m_ones));
                    end else begin
                        dout[9]   <= 1'b0;
                        dout[8]   <= q_m[8];
                        dout[7:0] <= q_m[7:0];
                        disparity <= disparity - signed'((!q_m[8] ? 5'sd2 : 5'sd0)) +
                                     signed'(5'(q_m_ones - q_m_zeros));
                    end
                end
            end
        end
    end

endmodule
