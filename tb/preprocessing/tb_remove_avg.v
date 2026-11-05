// ============================================================
//  Testbench - DC Offset Removal Verification
// ============================================================
//
//  Test Cases
//  ----------
//  TC1 - Zero-mean calibration and positive output
//  TC2 - Full-scale calibration and negative output
//  TC3 - Mean rounding at the half-integer boundary
//  TC4 - Input-valid gaps and exact calibration length
//  TC5 - Held-high start_cal (single rising-edge request)
//  TC6 - Restart during and after calibration
//  TC7 - Reset during and after calibration
//
//  Verification
//  ------------
//  Self-checking cycle-by-cycle reference model.
//  Checks calibration status, stored mean, output data,
//  and output-valid timing after every clock edge.
// ============================================================

`timescale 1ns / 1ps

module tb_remove_avg;

    // ── DUT parameters and signals ──────────────────────────────────────────
    localparam integer DATA_WIDTH = 12;
    localparam integer N_SAMPLES  = 4274;
    localparam integer MAX_SAMPLE = (1 << DATA_WIDTH) - 1;

    reg                       clk;
    reg                       rst;
    reg                       start_cal;
    reg                       valid_in;
    reg  [DATA_WIDTH-1:0]      sample_in_u;

    wire                      calib_done;
    wire                      valid_out;
    wire signed [DATA_WIDTH:0] sample_out_s;
    wire [DATA_WIDTH-1:0]     mean_u_dbg;

    remove_avg #(
        .DATA_WIDTH(DATA_WIDTH),
        .N_SAMPLES(N_SAMPLES)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start_cal(start_cal),
        .valid_in(valid_in),
        .sample_in_u(sample_in_u),
        .calib_done(calib_done),
        .valid_out(valid_out),
        .sample_out_s(sample_out_s),
        .mean_u_dbg(mean_u_dbg)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ── Independent reference model ─────────────────────────────────────────
    integer ref_sum;
    integer ref_count;
    integer ref_mean;
    integer ref_sample_out;

    reg ref_collecting;
    reg ref_start_d;
    reg ref_done;
    reg ref_valid_out;

    integer errors;
    integer cases_run;
    integer cases_failed;
    integer case_errors_before;
    integer checks_run;
    reg [8*48-1:0] case_name;

    // ── Cycle driver and scoreboard ─────────────────────────────────────────
    // Drive inputs on the falling edge and check registered outputs
    // after the following rising edge.
    task tick;
        input integer sample;
        input integer accept;
        input integer start;
        input integer reset_now;
        reg start_pulse;

        begin
            if (sample < 0 || sample > MAX_SAMPLE)
                $fatal(1, "Testbench input outside ADC range");

            @(negedge clk);
            sample_in_u = sample;
            valid_in    = (accept != 0);
            start_cal   = (start != 0);
            rst         = (reset_now != 0);

            start_pulse  = (start != 0) && !ref_start_d;
            ref_valid_out = 1'b0;

            if (reset_now != 0) begin
                ref_sum        = 0;
                ref_count      = 0;
                ref_mean       = 0;
                ref_sample_out = 0;
                ref_collecting = 1'b0;
                ref_start_d    = 1'b0;
                ref_done       = 1'b0;

            end else begin
                ref_start_d = (start != 0);

                if (start_pulse) begin
                    // Restart calibration; discard this cycle's input.
                    ref_sum        = 0;
                    ref_count      = 0;
                    ref_mean       = 0;
                    ref_sample_out = 0;
                    ref_collecting = 1'b1;
                    ref_done       = 1'b0;

                end else if (ref_collecting) begin
                    if (accept != 0) begin
                        ref_sum   = ref_sum + sample;
                        ref_count = ref_count + 1;

                        if (ref_count == N_SAMPLES) begin
                            ref_mean = (ref_sum + N_SAMPLES/2) / N_SAMPLES;
                            ref_collecting = 1'b0;
                            ref_done = 1'b1;
                        end
                    end

                end else if (ref_done && accept != 0) begin
                    ref_sample_out = sample - ref_mean;
                    ref_valid_out  = 1'b1;
                end
            end

            @(posedge clk);
            #1; // Allow nonblocking assignments to settle.
            checks_run = checks_run + 1;

            if (calib_done !== ref_done) begin
                errors = errors + 1;
                $display("ERROR [%0s] calib_done: expected=%b actual=%b at %0t",
                         case_name, ref_done, calib_done, $time);
            end

            if (valid_out !== ref_valid_out) begin
                errors = errors + 1;
                $display("ERROR [%0s] valid_out: expected=%b actual=%b at %0t",
                         case_name, ref_valid_out, valid_out, $time);
            end

            if (sample_out_s !== ref_sample_out) begin
                errors = errors + 1;
                $display("ERROR [%0s] sample_out_s: expected=%0d actual=%0d at %0t",
                         case_name, ref_sample_out, sample_out_s, $time);
            end

            if (mean_u_dbg !== ref_mean) begin
                errors = errors + 1;
                $display("ERROR [%0s] mean_u_dbg: expected=%0d actual=%0d at %0t",
                         case_name, ref_mean, mean_u_dbg, $time);
            end
        end
    endtask

    // ── Test reporting ───────────────────────────────────────────────────────
    task start_case;
        input [8*48-1:0] name;
        begin
            case_name = name;
            cases_run = cases_run + 1;
            case_errors_before = errors;
            tick(0, 0, 0, 1);
        end
    endtask

    task end_case;
        begin
            if (errors == case_errors_before)
                $display("PASS %-30s", case_name);
            else begin
                cases_failed = cases_failed + 1;
                $display("FAIL %-30s (%0d errors)",
                         case_name, errors - case_errors_before);
            end
        end
    endtask

    // ── TC1: Zero-mean calibration ───────────────────────────────────────────
    task test_zero_mean;
        integer i;
        begin
            start_case("TC1: Zero mean and positive output");

            tick(1234, 1, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(0, 1, 0, 0);

            tick(4095, 1, 0, 0);
            tick(123, 0, 0, 0);

            end_case;
        end
    endtask

    // ── TC2: Full-scale mean calibration ────────────────────────────────────
    task test_full_scale_mean;
        integer i;
        begin
            start_case("TC2: Full-scale mean and negative output");

            tick(0, 0, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(MAX_SAMPLE, 1, 0, 0);

            tick(0, 1, 0, 0);
            tick(MAX_SAMPLE, 1, 0, 0);

            end_case;
        end
    endtask

    // ── TC3: Mean rounding boundaries ───────────────────────────────────────
    task test_rounding;
        integer i;
        begin
            start_case("TC3a: Mean rounding below half");

            tick(0, 0, 1, 0);

            // 2136 ones / 4274 samples: mean < 0.5.
            for (i = 0; i < N_SAMPLES; i = i+1)
                tick((i < N_SAMPLES/2 - 1) ? 1 : 0, 1, 0, 0);

            tick(0, 1, 0, 0);
            end_case;

            start_case("TC3b: Mean rounding at half");

            tick(0, 0, 1, 0);

            // 2137 ones / 4274 samples: mean = 0.5.
            for (i = 0; i < N_SAMPLES; i = i+1)
                tick((i < N_SAMPLES/2) ? 1 : 0, 1, 0, 0);

            tick(0, 1, 0, 0);
            end_case;
        end
    endtask

    // ── TC4: Input-valid gaps ────────────────────────────────────────────────
    task test_valid_gaps;
        integer i;
        begin
            start_case("TC4: Valid gaps and exact sample count");

            tick(0, 0, 1, 0);

            for (i = 0; i < N_SAMPLES*3; i = i+1)
                tick((i*37) % (MAX_SAMPLE+1),
                     (i % 3 == 0), 0, 0);

            tick(2000, 0, 0, 0);
            tick(2000, 1, 0, 0);
            tick(3000, 0, 0, 0);
            tick(4000, 1, 0, 0);

            end_case;
        end
    endtask

    // ── TC5: Held-high calibration request ──────────────────────────────────
    task test_held_start;
        integer i;
        begin
            start_case("TC5: Held-high start is one request");

            tick(1234, 1, 1, 0);
            tick(1111, 1, 1, 0);
            tick(2222, 1, 1, 0);

            for (i = 0; i < N_SAMPLES-2; i = i+1)
                tick(2048, 1, 0, 0);

            tick(2048, 0, 0, 0);
            tick(3000, 1, 0, 0);

            end_case;
        end
    endtask

    // ── TC6: Calibration restart ────────────────────────────────────────────
    task test_restart;
        integer i;
        begin
            start_case("TC6a: Restart during calibration");

            tick(0, 0, 1, 0);

            for (i = 0; i < 250; i = i+1)
                tick(4095, 1, 0, 0);

            tick(0, 1, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(500, 1, 0, 0);

            tick(0, 1, 0, 0);
            end_case;

            start_case("TC6b: Restart after calibration");

            tick(0, 0, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(4095, 1, 0, 0);

            tick(0, 1, 0, 0);
            tick(2345, 1, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(100, 1, 0, 0);

            tick(200, 1, 0, 0);
            end_case;
        end
    endtask

    // ── TC7: Reset behavior ─────────────────────────────────────────────────
    task test_reset;
        integer i;
        begin
            start_case("TC7a: Reset during calibration");

            tick(0, 0, 1, 0);

            for (i = 0; i < 100; i = i+1)
                tick(3333, 1, 0, 0);

            tick(4095, 1, 1, 1);
            tick(1234, 1, 0, 0);
            tick(0, 0, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(700, 1, 0, 0);

            tick(800, 1, 0, 0);
            end_case;

            start_case("TC7b: Reset after calibration");

            tick(0, 0, 1, 0);

            for (i = 0; i < N_SAMPLES; i = i+1)
                tick(123, 1, 0, 0);

            tick(456, 1, 0, 0);
            tick(0, 0, 0, 1);
            tick(123, 1, 0, 0);

            end_case;
        end
    endtask

    // ── Main stimulus and summary ───────────────────────────────────────────
    initial begin
        rst            = 1'b0;
        start_cal      = 1'b0;
        valid_in       = 1'b0;
        sample_in_u    = 0;

        ref_sum        = 0;
        ref_count      = 0;
        ref_mean       = 0;
        ref_sample_out = 0;
        ref_collecting = 1'b0;
        ref_start_d    = 1'b0;
        ref_done       = 1'b0;
        ref_valid_out  = 1'b0;

        errors       = 0;
        cases_run    = 0;
        cases_failed = 0;
        checks_run   = 0;
        case_name    = 0;

        $display("DC OFFSET REMOVAL TESTBENCH: DATA_WIDTH=%0d N_SAMPLES=%0d",
                 DATA_WIDTH, N_SAMPLES);

        test_zero_mean();
        test_full_scale_mean();
        test_rounding();
        test_valid_gaps();
        test_held_start();
        test_restart();
        test_reset();

        $display("============================================================");
        $display("  DC Offset Removal Verification");
        $display("  Tests: %0d | Failed: %0d | Cycles: %0d | Errors: %0d",
                 cases_run, cases_failed, checks_run, errors);
        $display("============================================================");

        if (errors != 0)
            $fatal(1, "DC offset removal verification FAILED");

        $display("PASS: All DC offset removal tests passed.");
        $finish;
    end

    // ── Timeout watchdog ────────────────────────────────────────────────────
    initial begin
        #5000000;
        $fatal(1, "DC offset removal testbench timeout");
    end

endmodule
