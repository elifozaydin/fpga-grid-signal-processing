`timescale 1ns / 1ps

// ============================================================
//  Goertzel Path - Functional Verification Testbench
//
//  DUT
//  ---
//  goertzel_sim.v
//    -> goertzel_bank.v
//       -> 7 x goertzel_bin.v
//
//  Verification
//  ------------
//  1. Signed CIC scaling and saturation
//  2. Reset during an incomplete window
//  3. Accepted-sample counting with valid gaps
//  4. Back-to-back valid samples
//  5. First and last sample alignment
//  6. Exact result_valid timing and pulse width
//  7. Recurrence reset between consecutive windows
//  8. Output retention until the next completed window
//
//  Window 1: Nonzero periodic input
//  Window 2: All-zero input
//
//  This testbench verifies functional behavior.
//  Bit-exact numerical accuracy is tested separately
//  against the MATLAB fixed-point reference.
// ============================================================

module tb_goertzel_parallel;

    localparam integer CIC_SHIFT    = 16;
    localparam integer INPUT_WIDTH  = 16;
    localparam integer STATE_WIDTH  = 36;
    localparam integer NUM_BINS     = 7;
    localparam integer WINDOW_N     = 32000;
    localparam integer RESULT_WIDTH = NUM_BINS*STATE_WIDTH;

    // --------------------------------------------------------
    // Clock and DUT signals
    // --------------------------------------------------------

    reg clk = 1'b0;
    always #62.5 clk = ~clk;  // 8 MHz

    reg rst = 1'b1;
    reg cic_valid = 1'b0;
    reg signed [31:0] cic_sample = 32'sd0;

    wire result_valid;

    wire signed [RESULT_WIDTH-1:0] s1_out;
    wire signed [RESULT_WIDTH-1:0] s2_out;

    wire signed [INPUT_WIDTH-1:0] sample_scaled;

    wire sample_accept;
    wire sample_first;
    wire sample_last;

    goertzel_sim #(
        .CIC_SHIFT   (CIC_SHIFT),
        .INPUT_WIDTH (INPUT_WIDTH),
        .STATE_WIDTH (STATE_WIDTH),
        .WINDOW_N    (WINDOW_N)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .cic_valid     (cic_valid),
        .cic_sample    (cic_sample),
        .result_valid  (result_valid),
        .s1_out        (s1_out),
        .s2_out        (s2_out),
        .sample_scaled (sample_scaled),
        .sample_accept (sample_accept),
        .sample_first  (sample_first),
        .sample_last   (sample_last)
    );

    // --------------------------------------------------------
    // Testbench state
    // --------------------------------------------------------

    integer errors = 0;

    integer accepts = 0;
    integer first_count = 0;
    integer last_count = 0;
    integer result_count = 0;

    integer i;

    reg expected_result_valid = 1'b0;

    reg [RESULT_WIDTH-1:0] retained_s1 = {RESULT_WIDTH{1'b0}};
    reg [RESULT_WIDTH-1:0] retained_s2 = {RESULT_WIDTH{1'b0}};

    reg have_result = 1'b0;

    // Independent cycle-accurate integer reference for all seven bins.
    reg signed [STATE_WIDTH-1:0] ref_s1 [0:6];
    reg signed [STATE_WIDTH-1:0] ref_s2 [0:6];
    reg [RESULT_WIDTH-1:0] expected_s1 = 0;
    reg [RESULT_WIDTH-1:0] expected_s2 = 0;
    reg signed [63:0] ref_product, ref_term, ref_sum;
    reg signed [STATE_WIDTH-1:0] prior_s1, prior_s2, updated_s1;
    integer bin;

    function signed [25:0] coeff_at;
        input integer idx;
        begin
            case (idx)
                0: coeff_at = 26'sd31139567;
                1: coeff_at = 26'sd31137112;
                2: coeff_at = 26'sd31134656;
                3: coeff_at = 26'sd31132199;
                4: coeff_at = 26'sd31129741;
                5: coeff_at = 26'sd31127281;
                6: coeff_at = 26'sd31124821;
                default: coeff_at = 0;
            endcase
        end
    endfunction

    task reset_reference;
        integer j;
        begin
            expected_s1 = 0;
            expected_s2 = 0;
            for (j=0;j<NUM_BINS;j=j+1) begin
                ref_s1[j] = 0;
                ref_s2[j] = 0;
            end
        end
    endtask

    task reference_accept;
        input signed [INPUT_WIDTH-1:0] x;
        input first;
        input last;
        integer j;
        begin
            for (j=0;j<NUM_BINS;j=j+1) begin
                prior_s1 = first ? 0 : ref_s1[j];
                prior_s2 = first ? 0 : ref_s2[j];
                ref_product = $signed(prior_s1) * $signed(coeff_at(j));
                ref_term = ref_product >>> 24;
                ref_sum = $signed(x) + ref_term - $signed(prior_s2);
                updated_s1 = ref_sum[STATE_WIDTH-1:0];
                ref_s1[j] = updated_s1;
                ref_s2[j] = prior_s1;
                if (last) begin
                    expected_s1[j*STATE_WIDTH +: STATE_WIDTH] = updated_s1;
                    expected_s2[j*STATE_WIDTH +: STATE_WIDTH] = prior_s1;
                end
            end
        end
    endtask

    // --------------------------------------------------------
    // Failure reporting
    // --------------------------------------------------------

    task fail;
        input [8*160-1:0] description;
        begin
            errors = errors + 1;
            $display("FAIL (%0t): %0s", $time, description);
            $fatal(1);
        end
    endtask

    // --------------------------------------------------------
    // Input stimulus
    // --------------------------------------------------------

    // Drive inputs on falling edges to avoid races with
    // the DUT's rising-edge state updates.

    task send_cic;
        input signed [31:0] value;
        begin
            @(negedge clk);
            cic_sample = value;
            cic_valid = 1'b1;

            @(negedge clk);
            cic_valid = 1'b0;

            repeat (2) @(negedge clk);
        end
    endtask

    // Drive consecutive accepted samples with no valid gaps.
    task send_cic_continuous;
        input signed [31:0] value;
        begin
            @(negedge clk);
            cic_sample = value;
            cic_valid = 1'b1;
        end
    endtask

    // --------------------------------------------------------
    // Functional monitor
    // --------------------------------------------------------

    // This monitor observes registered DUT outputs from the
    // preceding rising edge, before the current NBA updates.
    //
    // Therefore result_valid must equal sample_last from
    // the preceding accepted-sample clock edge.

    always @(posedge clk) begin

        if (rst) begin

            expected_result_valid <= 1'b0;
            reset_reference;

        end else begin

            // Check completion timing, including cycles
            // where cic_valid is low.
            if (result_valid !== expected_result_valid)
                fail("result_valid timing mismatch");

            expected_result_valid <= sample_last;
            if (sample_accept)
                reference_accept(sample_scaled,sample_first,sample_last);

            // Count accepted samples.
            if (sample_accept) begin

                accepts = accepts + 1;

                if (sample_first) begin

                    first_count = first_count + 1;

                    if (((accepts-1) % WINDOW_N) != 0)
                        fail("sample_first alignment incorrect");

                end else if (((accepts-1) % WINDOW_N) == 0) begin

                    fail("Missing sample_first");

                end

                if (sample_last) begin

                    last_count = last_count + 1;

                    if ((accepts % WINDOW_N) != 0)
                        fail("sample_last alignment incorrect");

                end else if ((accepts % WINDOW_N) == 0) begin

                    fail("Missing sample_last");

                end

            end

            // Check that completed results remain unchanged
            // until the next result is published.
            if (have_result && !result_valid) begin

                if ((s1_out !== retained_s1) ||
                    (s2_out !== retained_s2))
                    fail("Output states changed before next result");

            end

            // Check completed results.
            if (result_valid) begin

                result_count = result_count + 1;
                if (s1_out !== expected_s1 || s2_out !== expected_s2)
                    fail("Exact Goertzel states mismatch");

                if (result_count == 1) begin

                    if ((s1_out === {RESULT_WIDTH{1'b0}}) &&
                        (s2_out === {RESULT_WIDTH{1'b0}}))
                        fail("Nonzero window returned zero states");

                end else if (result_count == 2) begin

                    if ((s1_out !== {RESULT_WIDTH{1'b0}}) ||
                        (s2_out !== {RESULT_WIDTH{1'b0}}))
                        fail("Zero window retained previous recurrence history");

                end else begin

                    fail("Unexpected extra result_valid pulse");

                end

                retained_s1 = s1_out;
                retained_s2 = s2_out;

                have_result = 1'b1;

            end

        end

    end

    // --------------------------------------------------------
    // Test sequence
    // --------------------------------------------------------

    initial begin

        $display("Starting standalone Goertzel path verification");

        // ----------------------------------------------------
        // Initial reset
        // ----------------------------------------------------

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // ----------------------------------------------------
        // Test 1: Signed scaling and saturation
        // ----------------------------------------------------

        // cic_valid remains low, so these values do not
        // enter the recurrence engines.

        cic_sample = 32'sh7fffffff;
        #1;

        if (sample_scaled !== 16'sd32767)
            fail("Positive full-scale CIC scaling incorrect");

        cic_sample = -32'sd2147483647 - 1;
        #1;

        if (sample_scaled !== -16'sd32768)
            fail("Negative full-scale CIC scaling incorrect");

        cic_sample = -32'sd65536;
        #1;

        if (sample_scaled !== -16'sd1)
            fail("Negative arithmetic shift incorrect");

        cic_sample = 32'sd65536;
        #1;

        if (sample_scaled !== 16'sd1)
            fail("Positive arithmetic shift incorrect");

        // ----------------------------------------------------
        // Test 2: Reset during an incomplete window
        // ----------------------------------------------------

        $display("Testing reset during partial window...");

        // Accept several nonzero samples without completing
        // the observation window.

        for (i = 0; i < 20; i = i + 1)
            send_cic(32'sd65536000);

        @(negedge clk);
        rst = 1'b1;
        cic_valid = 1'b0;

        repeat (3) @(negedge clk);

        if (s1_out !== {RESULT_WIDTH{1'b0}} ||
            s2_out !== {RESULT_WIDTH{1'b0}})
            fail("Reset did not clear output registers");

        if (result_valid !== 1'b0)
            fail("Reset did not clear result_valid");

        // Reset testbench counters for the main tests.
        accepts = 0;
        first_count = 0;
        last_count = 0;
        result_count = 0;

        retained_s1 = {RESULT_WIDTH{1'b0}};
        retained_s2 = {RESULT_WIDTH{1'b0}};
        have_result = 1'b0;

        @(negedge clk);
        rst = 1'b0;

        // ----------------------------------------------------
        // Test 3: Window 1 - Nonzero periodic input
        // ----------------------------------------------------

        $display("Processing window 1...");

        // First 32 samples are sent back-to-back to exercise
        // the one-sample-per-clock parallel architecture.

        for (i = 0; i < 32; i = i + 1) begin

            if ((i % 16) == 0)
                send_cic_continuous(32'sd65536000);
            else
                send_cic_continuous(32'sd0);

        end

        @(negedge clk);
        cic_valid = 1'b0;

        // Remaining samples include gaps between valid
        // pulses to verify accepted-sample counting.

        for (i = 32; i < WINDOW_N; i = i + 1) begin

            if ((i % 16) == 0)
                send_cic(32'sd65536000);
            else
                send_cic(32'sd0);

        end

        repeat (3) @(negedge clk);

        if (result_count != 1)
            fail("Expected one result after first window");

        // ----------------------------------------------------
        // Test 4: Window 2 - All-zero input
        // ----------------------------------------------------

        $display("Processing window 2...");

        for (i = 0; i < WINDOW_N; i = i + 1)
            send_cic(32'sd0);

        repeat (3) @(negedge clk);

        if (result_count != 2)
            fail("Expected two completed windows");

        // ----------------------------------------------------
        // Final checks
        // ----------------------------------------------------

        if (accepts != 2*WINDOW_N)
            fail("Incorrect accepted sample count");

        if (first_count != 2)
            fail("Incorrect number of sample_first pulses");

        if (last_count != 2)
            fail("Incorrect number of sample_last pulses");

        if ((s1_out !== {RESULT_WIDTH{1'b0}}) ||
            (s2_out !== {RESULT_WIDTH{1'b0}}))
            fail("Final outputs were not retained");

        if (errors == 0)
            $display("PASS: Goertzel path functional verification");
        else
            $fatal(1, "FAIL: %0d Goertzel path errors", errors);

        $finish;

    end

endmodule
