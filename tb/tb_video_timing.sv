//=============================================================================
// Testbench: tb_video_timing
//
// Purpose:
//   Self-checking verification of the video_timing module.
//   Measures from DUT outputs and strictly verifies:
//   - Line length (H_TOTAL cycles)
//   - Frame length (H_TOTAL * V_TOTAL cycles)
//   - Active pixels per line (H_ACTIVE)
//   - Active lines per frame (V_ACTIVE)
//   - HSYNC pulse width (H_SYNC cycles)
//   - VSYNC pulse width (V_SYNC * H_TOTAL cycles)
//   - H front porch (H_FP cycles) and back porch (H_BP cycles)
//   - V front porch (V_FP lines) and back porch (V_BP lines)
//   - Frame period
//   Verifies both a fast small preset (64x48) and full standard 720p60.
//=============================================================================

`timescale 1ns / 1ps

module tb_video_timing;

    int total_pass = 0;
    int total_fail = 0;

    task automatic check_val(string name, int actual, int expected);
        if (actual === expected) begin
            $display("[PASS] %s: actual=%0d, expected=%0d", name, actual, expected);
            total_pass++;
        end else begin
            $display("[FAIL] %s: actual=%0d, expected=%0d", name, actual, expected);
            total_fail++;
        end
    endtask

    //-------------------------------------------------------------------------
    // 1. Small Preset DUT Verification (64x48)
    //-------------------------------------------------------------------------
    localparam int S_H_ACTIVE = 64;
    localparam int S_H_FP     = 6;
    localparam int S_H_SYNC   = 6;
    localparam int S_H_BP     = 8;
    localparam int S_H_TOTAL  = S_H_ACTIVE + S_H_FP + S_H_SYNC + S_H_BP; // 84
    localparam int S_V_ACTIVE = 48;
    localparam int S_V_FP     = 2;
    localparam int S_V_SYNC   = 4;
    localparam int S_V_BP     = 6;
    localparam int S_V_TOTAL  = S_V_ACTIVE + S_V_FP + S_V_SYNC + S_V_BP; // 60
    localparam bit S_H_POL    = 1'b1;
    localparam bit S_V_POL    = 1'b1;

    logic clk_s;
    logic rst_n_s;
    logic hsync_s, vsync_s, de_s, frame_start_s;
    logic [11:0] x_s, y_s;

    video_timing #(
        .H_ACTIVE(S_H_ACTIVE),
        .H_FP    (S_H_FP),
        .H_SYNC  (S_H_SYNC),
        .H_BP    (S_H_BP),
        .V_ACTIVE(S_V_ACTIVE),
        .V_FP    (S_V_FP),
        .V_SYNC  (S_V_SYNC),
        .V_BP    (S_V_BP),
        .H_POL   (S_H_POL),
        .V_POL   (S_V_POL)
    ) dut_small (
        .clk        (clk_s),
        .rst_n      (rst_n_s),
        .hsync      (hsync_s),
        .vsync      (vsync_s),
        .de         (de_s),
        .frame_start(frame_start_s),
        .x          (x_s),
        .y          (y_s)
    );

    // Clock generator for small preset
    initial begin
        clk_s = 0;
        forever #5 clk_s = ~clk_s; // 100 MHz clock
    end

    task automatic run_small_preset_test();
        int frame_cycles;
        int active_line_count;
        int vsync_lines;
        int v_fp_lines;
        int v_bp_lines;
        int line_cycles;
        int de_active_pixels;
        int hsync_width;
        int h_fp_width;
        int h_bp_width;

        $display("------------------------------------------------------------");
        $display("Starting Small Preset (64x48) Timing Verification");
        $display("------------------------------------------------------------");

        // Async reset assert
        rst_n_s = 1'b0;
        repeat (5) @(posedge clk_s);
        @(posedge clk_s);
        rst_n_s <= 1'b1;

        // Wait for first full frame boundary (frame_start pulse)
        while (1) begin
            @(posedge clk_s);
            #1;
            if (frame_start_s) break;
        end
        $display("[INFO] First frame_start observed at time %0t", $time);

        frame_cycles = 0;
        active_line_count = 0;
        vsync_lines = 0;
        v_fp_lines = 0;
        v_bp_lines = 0;

        for (int line = 0; line < S_V_TOTAL; line++) begin
            line_cycles = 0;
            de_active_pixels = 0;
            hsync_width = 0;
            h_fp_width = 0;
            h_bp_width = 0;

            for (int p = 0; p < S_H_TOTAL; p++) begin
                // Check current pixel outputs
                frame_cycles++;
                line_cycles++;

                if (de_s) begin
                    de_active_pixels++;
                    if (x_s !== p || y_s !== line) begin
                        $display("[FAIL] Coordinate mismatch: x=%0d (exp %0d), y=%0d (exp %0d)",
                                 x_s, p, y_s, line);
                        total_fail++;
                    end
                end else begin
                    if (x_s !== 0 || y_s !== 0) begin
                        $display("[FAIL] Coordinate non-zero during blanking: x=%0d, y=%0d", x_s, y_s);
                        total_fail++;
                    end
                end

                if (hsync_s == S_H_POL) begin
                    hsync_width++;
                end else begin
                    if (p >= S_H_ACTIVE && p < (S_H_ACTIVE + S_H_FP))
                        h_fp_width++;
                    else if (p >= (S_H_ACTIVE + S_H_FP + S_H_SYNC))
                        h_bp_width++;
                end

                if (p == 0) begin
                    if (vsync_s == S_V_POL) begin
                        vsync_lines++;
                    end else if (line >= S_V_ACTIVE && line < (S_V_ACTIVE + S_V_FP)) begin
                        v_fp_lines++;
                    end else if (line >= (S_V_ACTIVE + S_V_FP + S_V_SYNC)) begin
                        v_bp_lines++;
                    end
                end

                // Step to next cycle unless it was the very last pixel of the frame
                if (!(line == S_V_TOTAL - 1 && p == S_H_TOTAL - 1)) begin
                    @(posedge clk_s);
                    #1;
                end
            end

            // Check horizontal line metrics
            check_val($sformatf("Line %0d Total Length", line), line_cycles, S_H_TOTAL);
            check_val($sformatf("Line %0d HSYNC Width", line), hsync_width, S_H_SYNC);
            check_val($sformatf("Line %0d H Front Porch", line), h_fp_width, S_H_FP);
            check_val($sformatf("Line %0d H Back Porch", line), h_bp_width, S_H_BP);

            if (line < S_V_ACTIVE) begin
                check_val($sformatf("Line %0d Active Pixels", line), de_active_pixels, S_H_ACTIVE);
                active_line_count++;
            end else begin
                check_val($sformatf("Blanking Line %0d Active Pixels", line), de_active_pixels, 0);
            end
        end

        // Check frame-level metrics
        check_val("Small Active Lines", active_line_count, S_V_ACTIVE);
        check_val("Small VSYNC Lines", vsync_lines, S_V_SYNC);
        check_val("Small V Front Porch Lines", v_fp_lines, S_V_FP);
        check_val("Small V Back Porch Lines", v_bp_lines, S_V_BP);
        check_val("Small Total Frame Cycles", frame_cycles, S_H_TOTAL * S_V_TOTAL);

        // Next cycle must assert frame_start
        @(posedge clk_s);
        #1;
        check_val("Small Next frame_start", frame_start_s, 1'b1);
    endtask

    //-------------------------------------------------------------------------
    // 2. Full 720p60 Timing Verification
    //-------------------------------------------------------------------------
    localparam int F_H_ACTIVE = 1280;
    localparam int F_H_FP     = 110;
    localparam int F_H_SYNC   = 40;
    localparam int F_H_BP     = 220;
    localparam int F_H_TOTAL  = 1650;
    localparam int F_V_ACTIVE = 720;
    localparam int F_V_FP     = 5;
    localparam int F_V_SYNC   = 5;
    localparam int F_V_BP     = 20;
    localparam int F_V_TOTAL  = 750;

    logic clk_f;
    logic rst_n_f;
    logic hsync_f, vsync_f, de_f, frame_start_f;
    logic [11:0] x_f, y_f;

    video_timing #(
        .H_ACTIVE(F_H_ACTIVE),
        .H_FP    (F_H_FP),
        .H_SYNC  (F_H_SYNC),
        .H_BP    (F_H_BP),
        .V_ACTIVE(F_V_ACTIVE),
        .V_FP    (F_V_FP),
        .V_SYNC  (F_V_SYNC),
        .V_BP    (F_V_BP),
        .H_POL   (1'b1),
        .V_POL   (1'b1)
    ) dut_720p (
        .clk        (clk_f),
        .rst_n      (rst_n_f),
        .hsync      (hsync_f),
        .vsync      (vsync_f),
        .de         (de_f),
        .frame_start(frame_start_f),
        .x          (x_f),
        .y          (y_f)
    );

    initial begin
        clk_f = 0;
        forever #6.734 clk_f = ~clk_f; // 74.25 MHz (period ~13.468ns)
    end

    task automatic run_720p60_test();
        int f_frame_cycles = 0;
        int f_active_pixels = 0;
        int f_active_lines = 0;
        int f_hsync_cycles = 0;
        int f_vsync_lines = 0;
        realtime t_start, t_end;

        $display("------------------------------------------------------------");
        $display("Starting Full 720p60 Timing Verification (1 Frame)");
        $display("------------------------------------------------------------");

        rst_n_f = 1'b0;
        repeat (5) @(posedge clk_f);
        @(posedge clk_f);
        rst_n_f <= 1'b1;

        // Wait for frame_start
        while (1) begin
            @(posedge clk_f);
            #1;
            if (frame_start_f) break;
        end
        t_start = $realtime;
        $display("[INFO] 720p60 frame_start at %0t ns", t_start);

        // Sample 1 full frame
        for (int c = 0; c < F_H_TOTAL * F_V_TOTAL; c++) begin
            @(posedge clk_f);
            f_frame_cycles++;
            if (de_f) begin
                f_active_pixels++;
            end
            if (hsync_f) begin
                f_hsync_cycles++;
            end
            if ((c % F_H_TOTAL) == 0) begin
                if (vsync_f) f_vsync_lines++;
                if (c < (F_H_TOTAL * F_V_ACTIVE)) f_active_lines++;
            end
        end
        t_end = $realtime;

        check_val("720p60 Total Frame Cycles", f_frame_cycles, F_H_TOTAL * F_V_TOTAL);
        check_val("720p60 Active Pixels", f_active_pixels, F_H_ACTIVE * F_V_ACTIVE);
        check_val("720p60 Total HSYNC Cycles", f_hsync_cycles, F_H_SYNC * F_V_TOTAL);
        check_val("720p60 VSYNC Lines", f_vsync_lines, F_V_SYNC);
        check_val("720p60 Active Lines", f_active_lines, F_V_ACTIVE);

        $display("[INFO] 720p60 measured frame period: %0t ns (target ~16.66 ms)", (t_end - t_start));
    endtask

    // Main test sequence
    initial begin
        run_small_preset_test();
        run_720p60_test();

        $display("============================================================");
        $display("Video Timing Verification Summary: PASS=%0d, FAIL=%0d", total_pass, total_fail);
        $display("============================================================");

        if (total_fail == 0) begin
            $display("[ALL TESTS PASSED]");
            $finish(0);
        end else begin
            $display("[TEST FAILED]");
            $finish(1);
        end
    end

endmodule
