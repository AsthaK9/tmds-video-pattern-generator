//=============================================================================
// Testbench: tb_tmds_encoder
//
// Purpose:
//   Self-checking verification of the DVI TMDS encoder.
//   Verifies:
//   (a) Exhaustive round-trip decoding of all 256 byte values from various
//       starting disparity states (zero, positive, negative).
//   (b) 10,000 random pixel round-trip encode/decode verification.
//   (c) Control token output strictly matching Table 3-3 when de=0.
//   (d) Running disparity strictly bounded within [-8, +8].
//=============================================================================

`timescale 1ns / 1ps

module tb_tmds_encoder;

    int total_pass = 0;
    int total_fail = 0;

    logic              clk;
    logic              rst_n;
    logic [7:0]        din;
    logic              c0;
    logic              c1;
    logic              de;
    logic [9:0]        dout;
    logic signed [4:0] disparity_out;

    // Instantiate TMDS encoder DUT
    tmds_encoder dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .din          (din),
        .c0           (c0),
        .c1           (c1),
        .de           (de),
        .dout         (dout),
        .disparity_out(disparity_out)
    );

    // 100 MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Reference TMDS Decoder function (inverts bit 9, then inverts bit 8 XOR/XNOR)
    function automatic [7:0] tmds_decode(input [9:0] sym);
        logic [7:0] q_m;
        logic [7:0] dec;
        logic q_m8;

        // Undo DC-balance inversion
        if (sym[9])
            q_m = ~sym[7:0];
        else
            q_m = sym[7:0];

        q_m8 = sym[8];

        // Undo transition minimization
        if (q_m8) begin
            // XOR mode
            dec[0] = q_m[0];
            for (int i = 1; i < 8; i++) begin
                dec[i] = q_m[i] ^ q_m[i-1];
            end
        end else begin
            // XNOR mode
            dec[0] = q_m[0];
            for (int i = 1; i < 8; i++) begin
                dec[i] = q_m[i] ~^ q_m[i-1];
            end
        end
        return dec;
    endfunction

    // Helper task to check running disparity bound [-8, +8]
    task automatic check_disparity_bound(string context_str);
        if (disparity_out < -8 || disparity_out > 8) begin
            $display("[FAIL] %s: Disparity out of bounds [-8, 8]! Value=%0d",
                     context_str, disparity_out);
            total_fail++;
        end
    endtask

    // Control tokens
    localparam logic [9:0] CTRL_00 = 10'b1101010100;
    localparam logic [9:0] CTRL_01 = 10'b0010101011;
    localparam logic [9:0] CTRL_10 = 10'b0101010100;
    localparam logic [9:0] CTRL_11 = 10'b1010101011;

    logic [7:0] dec_val;
    int disp_min;
    int disp_max;

    // Test sequence
    initial begin
        disp_min = 0;
        disp_max = 0;

        $display("============================================================");
        $display("Starting TMDS Encoder Self-Checking Verification");
        $display("============================================================");

        // Reset
        rst_n = 1'b0;
        din = 8'd0;
        c0 = 1'b0;
        c1 = 1'b0;
        de = 1'b0;
        repeat (5) @(posedge clk);
        @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        //---------------------------------------------------------------------
        // Check (c): Control Tokens when de=0
        //---------------------------------------------------------------------
        $display("--- Check (c): Control Tokens during de=0 ---");
        de <= 1'b0;

        // Test {c1, c0} = 00
        c1 <= 1'b0; c0 <= 1'b0;
        @(posedge clk); #1;
        if (dout === CTRL_00 && disparity_out === 5'sd0) total_pass++;
        else begin
            $display("[FAIL] Control token 00 mismatch: dout=%b, disp=%0d", dout, disparity_out);
            total_fail++;
        end

        // Test {c1, c0} = 01
        c1 <= 1'b0; c0 <= 1'b1;
        @(posedge clk); #1;
        if (dout === CTRL_01 && disparity_out === 5'sd0) total_pass++;
        else begin
            $display("[FAIL] Control token 01 mismatch: dout=%b, disp=%0d", dout, disparity_out);
            total_fail++;
        end

        // Test {c1, c0} = 10
        c1 <= 1'b1; c0 <= 1'b0;
        @(posedge clk); #1;
        if (dout === CTRL_10 && disparity_out === 5'sd0) total_pass++;
        else begin
            $display("[FAIL] Control token 10 mismatch: dout=%b, disp=%0d", dout, disparity_out);
            total_fail++;
        end

        // Test {c1, c0} = 11
        c1 <= 1'b1; c0 <= 1'b1;
        @(posedge clk); #1;
        if (dout === CTRL_11 && disparity_out === 5'sd0) total_pass++;
        else begin
            $display("[FAIL] Control token 11 mismatch: dout=%b, disp=%0d", dout, disparity_out);
            total_fail++;
        end

        //---------------------------------------------------------------------
        // Check (a): Exhaustive 256 values with starting disparity variations
        //---------------------------------------------------------------------
        $display("--- Check (a): Exhaustive 256-value Round-Trip ---");

        // Pass 1: Zero starting disparity before each value (clear with de=0)
        for (int v = 0; v < 256; v++) begin
            de <= 1'b0;
            c0 <= 1'b0; c1 <= 1'b0;
            @(posedge clk);

            // Feed byte with de=1
            de  <= 1'b1;
            din <= 8'(v);
            @(posedge clk);
            #1; // registered dout is valid for din=v

            dec_val = tmds_decode(dout);
            if (dec_val !== 8'(v)) begin
                $display("[FAIL] Exhaustive Zero-Disp val %0d decoded as %0d", v, dec_val);
                total_fail++;
            end else begin
                total_pass++;
            end
            check_disparity_bound("Exhaustive Zero-Disp");
            if (disparity_out < disp_min) disp_min = disparity_out;
            if (disparity_out > disp_max) disp_max = disparity_out;
        end

        // Pass 2: Continuous sequence of all 256 values
        de <= 1'b1;
        for (int v = 0; v < 256; v++) begin
            din <= 8'(v);
            @(posedge clk);
            #1;
            dec_val = tmds_decode(dout);
            if (dec_val !== 8'(v)) begin
                $display("[FAIL] Continuous val %0d decoded as %0d", v, dec_val);
                total_fail++;
            end else begin
                total_pass++;
            end
            check_disparity_bound("Continuous 256");
            if (disparity_out < disp_min) disp_min = disparity_out;
            if (disparity_out > disp_max) disp_max = disparity_out;
        end

        // Pass 3: Positive disparity bias (feed 0x01 repeatedly) before each byte
        for (int v = 0; v < 256; v += 8) begin
            repeat (3) begin
                de <= 1'b1;
                din <= 8'h01;
                @(posedge clk);
            end
            din <= 8'(v);
            @(posedge clk);
            #1;
            dec_val = tmds_decode(dout);
            if (dec_val !== 8'(v)) begin
                $display("[FAIL] Pos-biased val %0d decoded as %0d", v, dec_val);
                total_fail++;
            end else begin
                total_pass++;
            end
            check_disparity_bound("Pos-biased");
            if (disparity_out < disp_min) disp_min = disparity_out;
            if (disparity_out > disp_max) disp_max = disparity_out;
        end

        // Pass 4: Negative disparity bias (feed 0xFE repeatedly) before each byte
        for (int v = 0; v < 256; v += 8) begin
            repeat (3) begin
                de <= 1'b1;
                din <= 8'hFE;
                @(posedge clk);
            end
            din <= 8'(v);
            @(posedge clk);
            #1;
            dec_val = tmds_decode(dout);
            if (dec_val !== 8'(v)) begin
                $display("[FAIL] Neg-biased val %0d decoded as %0d", v, dec_val);
                total_fail++;
            end else begin
                total_pass++;
            end
            check_disparity_bound("Neg-biased");
            if (disparity_out < disp_min) disp_min = disparity_out;
            if (disparity_out > disp_max) disp_max = disparity_out;
        end

        //---------------------------------------------------------------------
        // Check (b): 10,000 Random Pixels Round-Trip
        //---------------------------------------------------------------------
        $display("--- Check (b): 10,000 Random Pixels Round-Trip ---");
        de <= 1'b1;

        for (int k = 0; k < 10000; k++) begin
            logic [7:0] rand_byte;
            rand_byte = 8'($random);
            din <= rand_byte;
            @(posedge clk);
            #1;
            dec_val = tmds_decode(dout);
            if (dec_val !== rand_byte) begin
                $display("[FAIL] Random pixel #%0d mismatch: sent=0x%02h, got=0x%02h",
                         k, rand_byte, dec_val);
                total_fail++;
            end else begin
                total_pass++;
            end
            check_disparity_bound("Random Pixel Test");
            if (disparity_out < disp_min) disp_min = disparity_out;
            if (disparity_out > disp_max) disp_max = disparity_out;
        end

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        $display("============================================================");
        $display("TMDS Encoder Verification Summary:");
        $display("  Total PASS checks: %0d", total_pass);
        $display("  Total FAIL checks: %0d", total_fail);
        $display("  Disparity range observed: [%0d, %0d] (Spec bound: [-8, +8])",
                 disp_min, disp_max);
        $display("============================================================");

        if (total_fail == 0 && disp_min >= -8 && disp_max <= 8) begin
            $display("[ALL TESTS PASSED]");
            $finish(0);
        end else begin
            $display("[TEST FAILED]");
            $finish(1);
        end
    end

endmodule
