// ============================================================
//  Testbench - CIC Decimator Verification
// ============================================================
//
//  Test Cases
//  ----------
//  TC1 - Zero input and impulse response
//  TC2 - Positive and negative full-scale DC
//  TC3 - Alternating extremes and random signed samples
//  TC4 - Input-valid gaps and midstream reset
//  TC5 - Sinusoidal tones (60 Hz, 300 Hz, alias image)
//
//  Verification
//  ------------
//  An independently generated, unnormalized FIR equivalent
//  provides expected values. Every cycle checks output_valid
//  and the complete signed 32-bit output, including wraparound.
//  No external vectors or output files are required.
// ============================================================

`timescale 1ns / 1ps

module tb_cic_decimator;

    // ── Test parameters and DUT signals ─────────────────────────────────────
    localparam integer R = 26;
    localparam integer N = 4;
    localparam integer TAPS = N * (R - 1) + 1;
    localparam real FS_IN_HZ = 8000000.0 / (2.0 * 26.0 * 6.0);
    localparam real FS_OUT_HZ = FS_IN_HZ / R;
    localparam real PI = 3.14159265358979323846;

    reg clk;
    reg rst;
    reg signed [12:0] data_in;
    reg input_valid;
    wire signed [31:0] data_out;
    wire output_valid;

    cic_decimator dut (
        .clk(clk), .rst(rst), .data_in(data_in),
        .input_valid(input_valid), .data_out(data_out),
        .output_valid(output_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ── Independent FIR reference model ─────────────────────────────────────
    // H(z) = (1 + z^-1 + ... + z^-25)^4; 101 integer coefficients.
    // Constructed by repeated convolution, not by copying DUT arithmetic.
    integer coeff [0:TAPS-1];
    integer next_coeff [0:TAPS-1];
    integer history [0:TAPS-1];
    integer ref_count;
    reg signed [31:0] expected_data;

    integer errors;
    integer cases_run;
    integer cases_failed;
    integer outputs_checked;
    integer case_start_errors;
    integer case_outputs;
    reg [8*48-1:0] case_name;

    task start_case;
        input [8*48-1:0] name;
        begin
            case_name = name;
            cases_run = cases_run + 1;
            case_start_errors = errors;
            case_outputs = 0;
            tick(0, 0, 1);
        end
    endtask

    task end_case;
        begin
            if (errors == case_start_errors)
                $display("PASS %-32s (%0d outputs)", case_name, case_outputs);
            else begin
                cases_failed = cases_failed + 1;
                $display("FAIL %-32s (%0d errors)",
                         case_name, errors - case_start_errors);
            end
        end
    endtask

    // ── Cycle driver and scoreboard ─────────────────────────────────────────
    // Drive at negedge, then sample registered DUT outputs after posedge.
    // Only accepted inputs advance the FIR history and decimation counter.
    task tick;
        input integer sample;
        input integer accept;
        input integer reset_now;
        integer j;
        reg expected_valid;
        reg signed [63:0] fir_sum;
        begin
            if (sample < -4096 || sample > 4095)
                $fatal(1, "Testbench input outside signed 13-bit range");

            @(negedge clk);
            rst = (reset_now != 0);
            input_valid = (accept != 0);
            data_in = sample;
            expected_valid = 1'b0;

            if (reset_now != 0) begin
                ref_count = 0;
                expected_data = 0;
                for (j = 0; j < TAPS; j = j + 1)
                    history[j] = 0;
            end else if (accept != 0) begin
                for (j = TAPS-1; j > 0; j = j-1)
                    history[j] = history[j-1];
                history[0] = sample;

                ref_count = ref_count + 1;
                if (ref_count == R) begin
                    ref_count = 0;
                    fir_sum = 0;
                    for (j = 0; j < TAPS; j = j+1)
                        fir_sum = fir_sum + $signed(history[j]) * $signed(coeff[j]);
                    expected_data = fir_sum[31:0];
                    expected_valid = 1'b1;
                end
            end

            @(posedge clk);
            #1; // Wait for nonblocking DUT assignments.

            if (output_valid !== expected_valid) begin
                errors = errors + 1;
                $display("ERROR [%0s] output_valid expected=%b actual=%b at %0t",
                         case_name, expected_valid, output_valid, $time);
            end
            if (data_out !== expected_data) begin
                errors = errors + 1;
                $display("ERROR [%0s] data_out expected=%0d actual=%0d at %0t",
                         case_name, expected_data, data_out, $time);
            end
            if (expected_valid) begin
                outputs_checked = outputs_checked + 1;
                case_outputs = case_outputs + 1;
            end
        end
    endtask

    // ── TC1: Zero input and impulse response ────────────────────────────────
    task test_zero_impulse;
        integer i;
        begin
            start_case("TC1a: Zero input");
            for (i = 0; i < 150; i = i+1) tick(0, 1, 0);
            end_case;

            start_case("TC1b: Impulse response");
            tick(1000, 1, 0);
            for (i = 1; i < 200; i = i+1) tick(0, 1, 0);
            end_case;
        end
    endtask

    // ── TC2: Signed full-scale DC ────────────────────────────────────────────
    task test_dc;
        integer i;
        begin
            start_case("TC2a: Positive full-scale DC");
            for (i = 0; i < 8192; i = i+1) tick(4095, 1, 0);
            end_case;

            start_case("TC2b: Negative full-scale DC");
            for (i = 0; i < 8192; i = i+1) tick(-4096, 1, 0);
            end_case;
        end
    endtask

    // ── TC3: Extreme and randomized inputs ──────────────────────────────────
    task test_extremes_random;
        integer i;
        integer seed;
        integer sample;
        begin
            start_case("TC3a: Alternating extremes");
            for (i = 0; i < 8192; i = i+1)
                tick((i % 2 == 0) ? 4095 : -4096, 1, 0);
            end_case;

            start_case("TC3b: Random signed inputs");
            seed = 3403;
            for (i = 0; i < 8192; i = i+1) begin
                sample = $random(seed) & 8191;
                if (sample >= 4096) sample = sample - 8192;
                tick(sample, 1, 0);
            end
            end_case;
        end
    endtask

    // ── TC4: Valid gaps and reset precedence ────────────────────────────────
    task test_control;
        integer i;
        begin
            start_case("TC4a: Input-valid gaps");
            for (i = 0; i < 1200; i = i+1)
                tick((i*37 % 8192)-4096,
                     ((i % 7) != 0 && (i % 11) != 0), 0);
            end_case;

            start_case("TC4b: Midstream reset");
            for (i = 0; i < 177; i = i+1) tick(1000, 1, 0);
            tick(123, 1, 1); // Reset wins over input_valid.
            for (i = 0; i < 160; i = i+1) tick(-2000, 1, 0);
            for (i = 0; i < 17; i = i+1) tick(987, (i % 3 != 0), 0);
            tick(-345, 0, 1);
            for (i = 0; i < 160; i = i+1) tick(1234, 1, 0);
            end_case;
        end
    endtask

    // ── TC5: Representative passband and alias-image tones ─────────────────
    task test_tone;
        input [8*48-1:0] name;
        input real frequency;
        integer i;
        integer sample;
        real value;
        begin
            start_case(name);
            for (i = 0; i < 4096; i = i+1) begin
                value = 3000.0 * $cos(2.0 * PI * frequency * i / FS_IN_HZ);
                sample = $rtoi(value + ((value >= 0.0) ? 0.5 : -0.5));
                tick(sample, 1, 0);
            end
            end_case;
        end
    endtask

    // ── Main stimulus and summary ───────────────────────────────────────────
    integer i, j, k, length;
    initial begin
        rst = 0;
        data_in = 0;
        input_valid = 0;
        ref_count = 0;
        expected_data = 0;
        errors = 0;
        cases_run = 0;
        cases_failed = 0;
        outputs_checked = 0;
        case_name = 0;

        // Generate FIR coefficients by convolving N length-R boxcar filters.
        for (i = 0; i < TAPS; i = i+1) begin
            coeff[i] = (i == 0) ? 1 : 0;
            history[i] = 0;
        end
        length = 1;
        for (k = 0; k < N; k = k+1) begin
            for (i = 0; i < TAPS; i = i+1) next_coeff[i] = 0;
            for (i = 0; i < length; i = i+1)
                for (j = 0; j < R; j = j+1)
                    next_coeff[i+j] = next_coeff[i+j] + coeff[i];
            for (i = 0; i < TAPS; i = i+1) coeff[i] = next_coeff[i];
            length = length + R - 1;
        end
        if (length != TAPS) $fatal(1, "FIR reference length mismatch");

        test_zero_impulse();
        test_dc();
        test_extremes_random();
        test_control();
        test_tone("TC5a: 60 Hz tone", 60.0);
        test_tone("TC5b: 300 Hz tone", 300.0);
        test_tone("TC5c: 686 Hz alias image", FS_OUT_HZ - 300.0);

        $display("============================================================");
        $display("  CIC Verification: %0d tests, %0d failures, %0d outputs, %0d errors",
                 cases_run, cases_failed, outputs_checked, errors);
        $display("============================================================");
        if (errors != 0) $fatal(1, "CIC verification FAILED");
        $display("PASS: All CIC verification tests passed.");
        $finish;
    end

    // ── Timeout watchdog ────────────────────────────────────────────────────
    initial begin
        #100000000;
        $fatal(1, "CIC testbench timeout");
    end

endmodule
