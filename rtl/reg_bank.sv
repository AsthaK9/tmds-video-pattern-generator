//=============================================================================
// Module: reg_bank
//
// Purpose:
//   Memory-mapped register bank operating in the sys_clk domain with CDC-safe
//   configuration distribution to the pixel_clk domain.
//
// Register Map:
//   - 0x0 (ID)        : Read-only identification constant (0x544D4453 = "TMDS").
//   - 0x4 (CTRL)      : [1:0] pattern_sel (0=bars, 1=grad, 2=check, 3=solid),
//                       [2]   enable (1=active pattern, 0=black video).
//   - 0x8 (SOLID_RGB) : [23:0] 24-bit RGB solid color configuration.
//   - 0xC (STATUS)    : [15:0] Frame counter synchronized from pixel domain.
//                       [31]   Busy/pending flag (cdc_busy || pending: 1 = config
//                              update in progress or pending transfer to pixel domain).
//
// Ports:
//   - sys_clk           : System register bus clock.
//   - sys_rst_n         : Active-low system reset.
//   - reg_addr          : 4-bit byte address [3:0].
//   - reg_wdata         : 32-bit write data.
//   - reg_wen           : Write enable.
//   - reg_rdata         : 32-bit read data (registered).
//   - pixel_clk         : Pixel clock domain for CDC.
//   - pixel_rst_n       : Active-low pixel reset.
//   - pixel_frame_start : Single-cycle pulse per frame from video_timing.
//   - cfg_pattern_sel   : Synchronized 2-bit pattern select in pixel domain.
//   - cfg_enable        : Synchronized enable flag in pixel domain.
//   - cfg_solid_rgb     : Synchronized 24-bit solid RGB in pixel domain.
//
// Key Design Decisions:
//   - All configuration writes set a pending flag. Combinational cdc_req = pending && !cdc_busy
//     triggers the CDC transfer when idle. If writes occur while cdc_busy is asserted,
//     updates coalesce into the latest register values and are dispatched once CDC is free,
//     preventing lost updates while guaranteeing zero multi-bit skew.
//   - STATUS[31] reflects (cdc_busy || pending) so software polling accurately indicates
//     when all configuration changes have arrived in the pixel domain.
//   - The frame counter crosses into the sys domain via toggle edge detection
//     using 2-flop synchronizers, preventing pulse swallowing across clock frequencies.
//=============================================================================

`timescale 1ns / 1ps

module reg_bank (
    // System Bus Interface (sys_clk)
    input  logic        sys_clk,
    input  logic        sys_rst_n,
    input  logic [3:0]  reg_addr,
    input  logic [31:0] reg_wdata,
    input  logic        reg_wen,
    output logic [31:0] reg_rdata,

    // Pixel Domain Interface (pixel_clk)
    input  logic        pixel_clk,
    input  logic        pixel_rst_n,
    input  logic        pixel_frame_start,

    // Synchronized Outputs in pixel_clk domain
    output logic [1:0]  cfg_pattern_sel,
    output logic        cfg_enable,
    output logic [23:0] cfg_solid_rgb
);

    // Register constants
    localparam logic [31:0] REG_ID_VAL = 32'h544D4453; // "TMDS"

    // Configuration registers in sys domain
    logic [1:0]  ctrl_pattern_sel;
    logic        ctrl_enable;
    logic [23:0] reg_solid_rgb;

    // CDC transfer signals
    localparam int CFG_WIDTH = 27; // {pattern_sel[1:0], enable, solid_rgb[23:0]}
    logic [CFG_WIDTH-1:0] src_cfg_bus;
    logic [CFG_WIDTH-1:0] dst_cfg_bus;
    logic                 pending;
    logic                 cdc_req;
    logic                 cdc_busy;
    logic                 dst_valid;

    assign src_cfg_bus = {ctrl_pattern_sel, ctrl_enable, reg_solid_rgb};
    assign cdc_req     = pending && !cdc_busy;

    // Frame counter CDC from pixel_clk to sys_clk
    logic        pixel_frame_toggle;
    logic        sys_frame_toggle_sync;
    logic        sys_frame_toggle_d1;
    logic [15:0] sys_frame_counter;

    // Toggle on pixel domain
    always_ff @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            pixel_frame_toggle <= 1'b0;
        end else if (pixel_frame_start) begin
            pixel_frame_toggle <= ~pixel_frame_toggle;
        end
    end

    // 2-Flop bit synchronizer for frame toggle
    cdc_bit_sync #(.RESET_VAL(1'b0)) sync_frame_toggle (
        .clk  (sys_clk),
        .rst_n(sys_rst_n),
        .d_in (pixel_frame_toggle),
        .q_out(sys_frame_toggle_sync)
    );

    // Count synchronized frame pulses in sys domain
    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sys_frame_toggle_d1 <= 1'b0;
            sys_frame_counter   <= 16'd0;
        end else begin
            sys_frame_toggle_d1 <= sys_frame_toggle_sync;
            if (sys_frame_toggle_sync ^ sys_frame_toggle_d1) begin
                sys_frame_counter <= sys_frame_counter + 1'b1;
            end
        end
    end

    // CDC toggle handshake instance
    cdc_toggle_handshake #(.WIDTH(CFG_WIDTH)) cdc_inst (
        .src_clk  (sys_clk),
        .src_rst_n(sys_rst_n),
        .src_data (src_cfg_bus),
        .src_req  (cdc_req),
        .src_busy (cdc_busy),

        .dst_clk  (pixel_clk),
        .dst_rst_n(pixel_rst_n),
        .dst_data (dst_cfg_bus),
        .dst_valid(dst_valid)
    );

    // Initial default register values on pixel domain
    logic [CFG_WIDTH-1:0] pixel_cfg_reg;
    always_ff @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            // Default: pattern 0 (color bars), enable=1, solid=0
            pixel_cfg_reg <= {2'b00, 1'b1, 24'h000000};
        end else if (dst_valid) begin
            pixel_cfg_reg <= dst_cfg_bus;
        end
    end

    assign cfg_pattern_sel = pixel_cfg_reg[26:25];
    assign cfg_enable      = pixel_cfg_reg[24];
    assign cfg_solid_rgb   = pixel_cfg_reg[23:0];

    logic cfg_wen;
    assign cfg_wen = reg_wen && (reg_addr == 4'h4 || reg_addr == 4'h8);

    // System bus write and read handling
    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ctrl_pattern_sel <= 2'b00;
            ctrl_enable      <= 1'b1;
            reg_solid_rgb    <= 24'h000000;
            pending          <= 1'b0;
            reg_rdata        <= 32'd0;
        end else begin
            // Pending management: write sets pending (priority over clear)
            if (cfg_wen) begin
                pending <= 1'b1;
            end else if (cdc_req) begin
                pending <= 1'b0;
            end

            if (reg_wen) begin
                case (reg_addr)
                    4'h4: begin
                        ctrl_pattern_sel <= reg_wdata[1:0];
                        ctrl_enable      <= reg_wdata[2];
                    end
                    4'h8: begin
                        reg_solid_rgb <= reg_wdata[23:0];
                    end
                    default: ;
                endcase
            end

            // Read bus mux (registered)
            case (reg_addr)
                4'h0: reg_rdata <= REG_ID_VAL;
                4'h4: reg_rdata <= {29'd0, ctrl_enable, ctrl_pattern_sel};
                4'h8: reg_rdata <= {8'd0, reg_solid_rgb};
                4'hC: reg_rdata <= {(cdc_busy || pending), 15'd0, sys_frame_counter};
                default: reg_rdata <= 32'hDEADBEEF;
            endcase
        end
    end

endmodule
