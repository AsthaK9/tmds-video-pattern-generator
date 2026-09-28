//=============================================================================
// Testbench: tb_top
//
// Purpose:
//   Comprehensive system-level self-checking verification of top.sv:
//     - Operates with asynchronous, unrelated clock frequencies:
//         sys_clk   = 50.00 MHz (period 20.000 ns)
//         pixel_clk = 74.25 MHz (period 13.468 ns)
//     - Uses small preset geometry (64x48) for high simulation speed.
//     - Tests MMIO register bus (read/write, ID verification, readback).
//     - Verifies CDC safety: monitors pixel domain config and asserts that
//       it transitions atomically from old_cfg to new_cfg with NEVER a
//       mixed or corrupted intermediate value.
//     - Exercises all 4 patterns (0..3) for 2 full frames each.
//     - Decodes TMDS symbols from all 3 channels on the fly during the second
//       frame of each pattern and dumps:
//         * out/frame_sel<N>.ppm (ASCII PPM image)
//         * out/frame_sel<N>_tmds.hex (Raw 10-bit TMDS hex symbols)
//     - Verifies STATUS register frame counter synchronization.
//     - Prints coverage and disparity telemetry summary.
//=============================================================================

`timescale 1ns / 1ps

module tb_top;

    int total_pass = 0;
    int total_fail = 0;

    // Small Preset Video Geometry
    localparam int H_ACTIVE    = 64;
    localparam int H_FP        = 6;
    localparam int H_SYNC      = 6;
    localparam int H_BP        = 8;
    localparam int H_TOTAL     = H_ACTIVE + H_FP + H_SYNC + H_BP; // 84
    localparam int V_ACTIVE    = 48;
    localparam int V_FP        = 2;
    localparam int V_SYNC      = 4;
    localparam int V_BP        = 6;
    localparam int V_TOTAL     = V_ACTIVE + V_FP + V_SYNC + V_BP; // 60
    localparam int SQUARE_SIZE = 8;

    // Clocks and Resets
    logic sys_clk;
    logic sys_rst_n;
    logic pixel_clk;
    logic pixel_rst_n;

    // Register Bus Interface
    logic [3:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic        reg_wen;
    logic [31:0] reg_rdata;

    // TMDS Channels
    logic [9:0]  tmds_ch0;
    logic [9:0]  tmds_ch1;
    logic [9:0]  tmds_ch2;

    // Debug Video Signals
    logic        debug_hsync;
    logic        debug_vsync;
    logic        debug_de;

    // Top DUT instance
    top #(
        .H_ACTIVE   (H_ACTIVE),
        .H_FP       (H_FP),
        .H_SYNC     (H_SYNC),
        .H_BP       (H_BP),
        .V_ACTIVE   (V_ACTIVE),
        .V_FP       (V_FP),
        .V_SYNC     (V_SYNC),
        .V_BP       (V_BP),
        .SQUARE_SIZE(SQUARE_SIZE)
    ) dut (
        .sys_clk    (sys_clk),
        .sys_rst_n  (sys_rst_n),
        .pixel_clk  (pixel_clk),
        .pixel_rst_n(pixel_rst_n),
        .reg_addr   (reg_addr),
        .reg_wdata  (reg_wdata),
        .reg_wen    (reg_wen),
        .reg_rdata  (reg_rdata),
        .tmds_ch0   (tmds_ch0),
        .tmds_ch1   (tmds_ch1),
        .tmds_ch2   (tmds_ch2),
        .debug_hsync(debug_hsync),
        .debug_vsync(debug_vsync),
        .debug_de   (debug_de)
    );

    // Clock Generators (Unrelated frequencies)
    // sys_clk = 50.00 MHz (period 20ns)
    initial begin
        sys_clk = 0;
        forever #10 sys_clk = ~sys_clk;
    end

    // pixel_clk = 74.25 MHz (period ~13.468ns)
    initial begin
        pixel_clk = 0;
        forever #6.734 pixel_clk = ~pixel_clk;
    end

    // TMDS Reference Decoder
    function automatic [7:0] tmds_decode(input [9:0] sym);
        logic [7:0] q_m;
        logic [7:0] dec;
        logic q_m8;

        if (sym[9])
            q_m = ~sym[7:0];
        else
            q_m = sym[7:0];

        q_m8 = sym[8];

        if (q_m8) begin
            dec[0] = q_m[0];
            for (int i = 1; i < 8; i++) begin
                dec[i] = q_m[i] ^ q_m[i-1];
            end
        end else begin
            dec[0] = q_m[0];
            for (int i = 1; i < 8; i++) begin
                dec[i] = q_m[i] ~^ q_m[i-1];
            end
        end
        return dec;
    endfunction

    // Bus access tasks
    task automatic bus_write(input [3:0] addr, input [31:0] data);
        @(posedge sys_clk);
        reg_addr  <= addr;
        reg_wdata <= data;
        reg_wen   <= 1'b1;
        @(posedge sys_clk);
        reg_wen   <= 1'b0;
        #1;
    endtask

    task automatic bus_read(input [3:0] addr, output [31:0] data);
        @(posedge sys_clk);
        reg_addr <= addr;
        reg_wen  <= 1'b0;
        @(posedge sys_clk);
        #1;
        data = reg_rdata;
    endtask

    // CDC Safety Checker: monitor synchronized config on pixel_clk
    localparam int MAX_VALID_CFGS = 8;
    logic [26:0] valid_cfgs[MAX_VALID_CFGS];
    int          num_valid_cfgs = 0;
    logic        cdc_check_active = 0;

    function automatic bit is_valid_cfg(input logic [26:0] val);
        for (int i = 0; i < num_valid_cfgs; i++) begin
            if (val === valid_cfgs[i]) return 1'b1;
        end
        return 1'b0;
    endfunction

    always @(posedge pixel_clk) begin
        if (pixel_rst_n && cdc_check_active) begin
            logic [26:0] current_pixel_cfg;
            current_pixel_cfg = {dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb};
            if (!is_valid_cfg(current_pixel_cfg)) begin
                $display("[FAIL] CDC MIXED VALUE CORRUPTION DETECTED at time %0t: cfg=0x%07h not in valid list",
                         $time, current_pixel_cfg);
                total_fail++;
            end
        end
    end

    // Telemetry tracking
    int patterns_exercised[4];
    int disp_min_ch0 = 0, disp_max_ch0 = 0;
    int disp_min_ch1 = 0, disp_max_ch1 = 0;
    int disp_min_ch2 = 0, disp_max_ch2 = 0;

    always @(posedge pixel_clk) begin
        if (pixel_rst_n) begin
            if (dut.u_tmds_ch0.disparity < disp_min_ch0) disp_min_ch0 = dut.u_tmds_ch0.disparity;
            if (dut.u_tmds_ch0.disparity > disp_max_ch0) disp_max_ch0 = dut.u_tmds_ch0.disparity;

            if (dut.u_tmds_ch1.disparity < disp_min_ch1) disp_min_ch1 = dut.u_tmds_ch1.disparity;
            if (dut.u_tmds_ch1.disparity > disp_max_ch1) disp_max_ch1 = dut.u_tmds_ch1.disparity;

            if (dut.u_tmds_ch2.disparity < disp_min_ch2) disp_min_ch2 = dut.u_tmds_ch2.disparity;
            if (dut.u_tmds_ch2.disparity > disp_max_ch2) disp_max_ch2 = dut.u_tmds_ch2.disparity;
        end
    end

    // Task to capture and dump active frame pixels to PPM and TMDS hex
    task automatic dump_active_frame(input int pat_num);
        string ppm_filename;
        string hex_filename;
        int ppm_fd;
        int hex_fd;
        int pixel_count;
        logic [7:0] r_dec, g_dec, b_dec;

        ppm_filename = $sformatf("out/frame_sel%0d.ppm", pat_num);
        hex_filename = $sformatf("out/frame_sel%0d_tmds.hex", pat_num);

        ppm_fd = $fopen(ppm_filename, "w");
        hex_fd = $fopen(hex_filename, "w");

        if (ppm_fd == 0 || hex_fd == 0) begin
            $display("[FAIL] Could not open output files for pattern %0d", pat_num);
            total_fail++;
            return;
        end

        // Write PPM header
        $fwrite(ppm_fd, "P3\n%0d %0d\n255\n", H_ACTIVE, V_ACTIVE);

        // Wait for frame_start of frame 2
        while (1) begin
            @(posedge pixel_clk);
            #1;
            if (dut.u_video_timing.frame_start) break;
        end
        $display("[INFO] Capturing frame for pattern %0d...", pat_num);

        pixel_count = 0;
        // Collect active pixels across the entire frame
        for (int line = 0; line < V_TOTAL; line++) begin
            for (int p = 0; p < H_TOTAL; p++) begin
                // Check if this pixel is in active region (accounting for 2 pipeline delays from timing)
                if (debug_de) begin
                    r_dec = tmds_decode(tmds_ch2);
                    g_dec = tmds_decode(tmds_ch1);
                    b_dec = tmds_decode(tmds_ch0);

                    $fwrite(ppm_fd, "%0d %0d %0d\n", r_dec, g_dec, b_dec);
                    $fwrite(hex_fd, "%03h %03h %03h\n", tmds_ch2, tmds_ch1, tmds_ch0);
                    pixel_count++;
                end
                @(posedge pixel_clk);
                #1;
            end
        end

        $fclose(ppm_fd);
        $fclose(hex_fd);

        if (pixel_count === H_ACTIVE * V_ACTIVE) begin
            $display("[PASS] Pattern %0d: Captured exactly %0d active pixels to %s",
                     pat_num, pixel_count, ppm_filename);
            total_pass++;
        end else begin
            $display("[FAIL] Pattern %0d: Pixel count mismatch! Got %0d, expected %0d",
                     pat_num, pixel_count, H_ACTIVE * V_ACTIVE);
            total_fail++;
        end
    endtask

    task automatic wait_cdc_idle();
        logic [31:0] stat;
        do begin
            bus_read(4'hC, stat);
        end while (stat[31]);
    endtask

    task automatic write_cfg_safe(input [3:0] addr, input [31:0] data, input [26:0] exp_new);
        valid_cfgs[0]  = {dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb};
        valid_cfgs[1]  = exp_new;
        num_valid_cfgs = 2;
        cdc_check_active = 1;
        bus_write(addr, data);
        wait_cdc_idle();
        repeat (10) @(posedge sys_clk);
        cdc_check_active = 0;

        // Verify destination reached new value
        if ({dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb} === exp_new) begin
            $display("[PASS] CDC transferred config 0x%07h atomically without corruption", exp_new);
            total_pass++;
        end else begin
            $display("[FAIL] CDC transfer failed: exp=0x%07h, got=0x%07h",
                     exp_new, {dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb});
            total_fail++;
        end
    endtask

    // Main Test Sequence
    logic [31:0] read_val;
    int current_frame_cnt;

    initial begin

        patterns_exercised[0] = 0;
        patterns_exercised[1] = 0;
        patterns_exercised[2] = 0;
        patterns_exercised[3] = 0;

        $display("============================================================");
        $display("Starting tb_top System Verification");
        $display("============================================================");

        // Initialize resets
        sys_rst_n   = 1'b0;
        pixel_rst_n = 1'b0;
        reg_addr    = 4'h0;
        reg_wdata   = 32'h0;
        reg_wen     = 1'b0;

        repeat (10) @(posedge sys_clk);
        @(posedge sys_clk);   sys_rst_n   <= 1'b1;
        @(posedge pixel_clk); pixel_rst_n <= 1'b1;
        repeat (10) @(posedge sys_clk);

        //---------------------------------------------------------------------
        // 1. Check ID and Register Readback
        //---------------------------------------------------------------------
        $display("--- 1. Testing Register Bank Read / Write ---");

        // Read ID register (0x0)
        bus_read(4'h0, read_val);
        if (read_val === 32'h544D4453) begin
            $display("[PASS] ID register matches: 0x%08h ('TMDS')", read_val);
            total_pass++;
        end else begin
            $display("[FAIL] ID register mismatch: 0x%08h (expected 0x544D4453)", read_val);
            total_fail++;
        end

        // Read default CTRL (0x4)
        bus_read(4'h4, read_val);
        if (read_val[2:0] === 3'b100) begin // enable=1, pattern_sel=0
            $display("[PASS] Default CTRL matches: 0x%08h", read_val);
            total_pass++;
        end else begin
            $display("[FAIL] Default CTRL mismatch: 0x%08h", read_val);
            total_fail++;
        end

        // Write SOLID_RGB (0x8) and read back
        bus_write(4'h8, 32'h00A5C35A);
        wait_cdc_idle();
        repeat (10) @(posedge sys_clk);
        bus_read(4'h8, read_val);
        if (read_val[23:0] === 24'hA5C35A) begin
            $display("[PASS] SOLID_RGB readback matches: 0x%06h", read_val[23:0]);
            total_pass++;
        end else begin
            $display("[FAIL] SOLID_RGB readback mismatch: 0x%06h", read_val[23:0]);
            total_fail++;
        end

        //---------------------------------------------------------------------
        // 2. Exercise Patterns 0..3 for 2 frames each & Dump Images
        //---------------------------------------------------------------------
        for (int p = 0; p < 4; p++) begin
            $display("--- Running Pattern %0d for 2 Frames ---", p);

            // Configure pattern via MMIO with CDC safety checks
            if (p == 3) begin
                // Solid color pattern: first update color, then select pattern 3
                write_cfg_safe(4'h8, 32'h0000E5FF, {2'b10, 1'b1, 24'h00E5FF});
                write_cfg_safe(4'h4, {29'd0, 1'b1, 2'b11}, {2'b11, 1'b1, 24'h00E5FF});
            end else begin
                logic [23:0] cur_rgb;
                cur_rgb = dut.cfg_solid_rgb;
                write_cfg_safe(4'h4, {29'd0, 1'b1, 2'(p)}, {2'(p), 1'b1, cur_rgb});
            end

            patterns_exercised[p] = 1;

            // Frame 1: allow pipeline to settle
            while (1) begin
                @(posedge pixel_clk);
                #1;
                if (dut.u_video_timing.frame_start) break;
            end

            // Frame 2: capture and dump
            dump_active_frame(p);
        end

        //---------------------------------------------------------------------
        // 3. Verify STATUS Register (Frame Counter)
        //---------------------------------------------------------------------
        $display("--- 3. Testing STATUS Frame Counter ---");
        repeat (50) @(posedge sys_clk);
        bus_read(4'hC, read_val);
        current_frame_cnt = read_val[15:0];
        $display("[INFO] STATUS register read: 0x%08h (Frame counter = %0d)",
                 read_val, current_frame_cnt);

        if (current_frame_cnt >= 8) begin
            $display("[PASS] Synchronized frame counter >= 8 (counted %0d frames)",
                     current_frame_cnt);
            total_pass++;
        end else begin
            $display("[FAIL] Frame counter too low: %0d", current_frame_cnt);
            total_fail++;
        end

        //---------------------------------------------------------------------
        // 4. Testing Back-to-Back Config Writes with CDC Coalescing
        //---------------------------------------------------------------------
        $display("--- 4. Testing Back-to-Back Config Writes (Coalescing) ---");
        begin
            logic [26:0] b2b_old_cfg;
            logic [26:0] b2b_step1_cfg;
            logic [26:0] b2b_step2_cfg;
            logic [26:0] b2b_final_cfg;

            b2b_old_cfg = {dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb};

            // 3 back-to-back writes: CTRL, SOLID_RGB, CTRL
            // Step 1: CTRL -> pattern_sel=1, enable=1
            b2b_step1_cfg = {2'b01, 1'b1, b2b_old_cfg[23:0]};
            // Step 2: SOLID_RGB -> 24'h55AA33
            b2b_step2_cfg = {2'b01, 1'b1, 24'h55AA33};
            // Step 3: CTRL -> pattern_sel=2, enable=1
            b2b_final_cfg = {2'b10, 1'b1, 24'h55AA33};

            valid_cfgs[0]  = b2b_old_cfg;
            valid_cfgs[1]  = b2b_step1_cfg;
            valid_cfgs[2]  = b2b_step2_cfg;
            valid_cfgs[3]  = b2b_final_cfg;
            num_valid_cfgs = 4;
            cdc_check_active = 1;

            // Issue 3 back-to-back config writes with NO wait_cdc_idle between them
            bus_write(4'h4, {29'd0, 1'b1, 2'b01}); // CTRL: pattern 1
            bus_write(4'h8, 32'h0055AA33);         // SOLID_RGB: 0x55AA33
            bus_write(4'h4, {29'd0, 1'b1, 2'b10}); // CTRL: pattern 2

            // Wait for idle plus a few clocks
            wait_cdc_idle();
            repeat (10) @(posedge sys_clk);
            cdc_check_active = 0;

            // Check pixel-domain config equals final register values
            if ({dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb} === b2b_final_cfg) begin
                $display("[PASS] Back-to-back writes coalesced cleanly to final config: 0x%07h", b2b_final_cfg);
                total_pass++;
            end else begin
                $display("[FAIL] Back-to-back writes failed: exp=0x%07h, got=0x%07h",
                         b2b_final_cfg, {dut.cfg_pattern_sel, dut.cfg_enable, dut.cfg_solid_rgb});
                total_fail++;
            end
        end

        //---------------------------------------------------------------------
        // 5. Coverage and Telemetry Summary
        //---------------------------------------------------------------------
        $display("============================================================");
        $display("Verification Coverage & Telemetry Summary:");
        $display("  Patterns Exercised: 0=%0d, 1=%0d, 2=%0d, 3=%0d",
                 patterns_exercised[0], patterns_exercised[1],
                 patterns_exercised[2], patterns_exercised[3]);
        $display("  Disparity Range Ch0 (Blue):  [%0d, %0d]", disp_min_ch0, disp_max_ch0);
        $display("  Disparity Range Ch1 (Green): [%0d, %0d]", disp_min_ch1, disp_max_ch1);
        $display("  Disparity Range Ch2 (Red):   [%0d, %0d]", disp_min_ch2, disp_max_ch2);
        $display("  Frames Synchronized: %0d", current_frame_cnt);
        $display("  Total Checks: PASS=%0d, FAIL=%0d", total_pass, total_fail);
        $display("============================================================");

        if (total_fail == 0 &&
            disp_min_ch0 >= -8 && disp_max_ch0 <= 8 &&
            disp_min_ch1 >= -8 && disp_max_ch1 <= 8 &&
            disp_min_ch2 >= -8 && disp_max_ch2 <= 8) begin
            $display("[ALL TESTS PASSED]");
            $finish(0);
        end else begin
            $display("[TEST FAILED]");
            $finish(1);
        end
    end

endmodule
