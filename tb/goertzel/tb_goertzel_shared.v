`timescale 1ns / 1ps

// Verilog-2001 self-checking testbench for the SINGLE-CONTEXT,
// NONOVERLAPPING goertzel_bank_shared with sample_first/sample_last.
// Change DUT module name below if your file still uses "goertzel_bank".
// Default configuration validates four full 32000-sample windows.
module tb_goertzel_shared;
    parameter integer N = 32000;
    parameter integer IW = 16;
    parameter integer SW = 36;
    parameter integer CW = 26;
    parameter integer FRAC = 24;
    parameter integer NUM_SAMPLES = 128000;
    parameter integer MAX_RESULTS = 256;

    localparam integer EXPECTED_RESULTS = NUM_SAMPLES / N;
    localparam integer PRE_RESET_SAMPLES = (N > 2) ? N/3 : 1;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg sample_valid = 1'b0;
    reg sample_first = 1'b0;
    reg sample_last = 1'b0;
    reg signed [IW-1:0] sample_in = 0;
    wire sample_ready;
    wire result_valid;
    wire signed [7*SW-1:0] s1_out, s2_out;

    goertzel_bank_shared #(
        .INPUT_WIDTH(IW), .STATE_WIDTH(SW),
        .COEFF_WIDTH(CW), .COEFF_FRAC(FRAC)
    ) dut (
        .clk(clk), .rst(rst), .sample_valid(sample_valid),
        .sample_first(sample_first), .sample_last(sample_last),
        .sample_in(sample_in), .sample_ready(sample_ready),
        .result_valid(result_valid), .s1_out(s1_out), .s2_out(s2_out)
    );

    reg signed [SW-1:0] ref_s1 [0:6];
    reg signed [SW-1:0] ref_s2 [0:6];
    reg [7*SW-1:0] expected_s1 [0:MAX_RESULTS-1];
    reg [7*SW-1:0] expected_s2 [0:MAX_RESULTS-1];
    integer accepted_count, window_position, write_ptr, read_ptr;
    integer pass_count, reset_events;
    reg in_window;
    reg signed [63:0] wide_product, shifted_product, wide_sum;
    reg signed [SW-1:0] prior_s1, prior_s2, updated_s1;
    reg [7*SW-1:0] finished_s1, finished_s2;
    reg [7*SW-1:0] last_s1, last_s2;
    reg last_result_valid, outputs_initialized;
    reg pending_completed_window;
    integer published_windows;
    integer bin_check, i, seed;
    reg signed [IW-1:0] stimulus;

    function signed [CW-1:0] coeff_at;
        input integer bin;
        begin
            case (bin)
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

    task clear_reference;
        integer k;
        begin
            accepted_count = 0;
            window_position = 0;
            write_ptr = 0;
            read_ptr = 0;
            in_window = 0;
            last_result_valid = 0;
            pending_completed_window = 0;
            published_windows = 0;
            outputs_initialized = 0;
            for (k=0; k<7; k=k+1) begin
                ref_s1[k] = 0;
                ref_s2[k] = 0;
            end
        end
    endtask

    // Independent reference, updated ONLY for accepted samples.
    task reference_accept;
        input signed [IW-1:0] x;
        input first;
        input last;
        integer k;
        begin
            if (first !== (window_position == 0) ||
                last !== (window_position == N-1)) begin
                $display("FAIL: bad boundary flags at position %0d", window_position);
                $fatal(1);
            end
            if (first) begin
                if (in_window) begin
                    $display("FAIL: first asserted during active reference window");
                    $fatal(1);
                end
                in_window = 1;
                for (k=0;k<7;k=k+1) begin
                    ref_s1[k] = 0;
                    ref_s2[k] = 0;
                end
            end
            if (!in_window) begin
                $display("FAIL: sample without active reference window");
                $fatal(1);
            end

            finished_s1 = 0;
            finished_s2 = 0;
            for (k=0;k<7;k=k+1) begin
                prior_s1 = ref_s1[k];
                prior_s2 = ref_s2[k];
                wide_product = $signed(prior_s1) * $signed(coeff_at(k));
                shifted_product = wide_product >>> FRAC;
                wide_sum = $signed(x) + shifted_product - $signed(prior_s2);
                updated_s1 = wide_sum[SW-1:0];
                ref_s1[k] = updated_s1;
                ref_s2[k] = prior_s1;
                finished_s1[k*SW +: SW] = updated_s1;
                finished_s2[k*SW +: SW] = prior_s1;
            end
            accepted_count = accepted_count + 1;
            if (last) begin
                if (write_ptr >= MAX_RESULTS) begin
                    $display("FAIL: MAX_RESULTS too small");
                    $fatal(1);
                end
                expected_s1[write_ptr] = finished_s1;
                expected_s2[write_ptr] = finished_s2;
                write_ptr = write_ptr + 1;
                in_window = 0;
                window_position = 0;
            end else begin
                window_position = window_position + 1;
            end
        end
    endtask

    // Check after nonblocking assignments have propagated.
    always @(posedge clk) begin
        if (rst) begin
            clear_reference;
        end else begin
            if (sample_ready !== (dut.state == 0 && !rst)) begin
                $display("FAIL: sample_ready violated IDLE-only handshake");
                $fatal(1);
            end
            if (sample_valid && sample_ready) begin
                if (pending_completed_window) begin
                    $display("FAIL: accepted another sample before result publication");
                    $fatal(1);
                end
                reference_accept(sample_in, sample_first, sample_last);
                if (sample_last)
                    pending_completed_window = 1;
            end
            #1;
            if (result_valid === 1'b1) begin
                if (!pending_completed_window) begin
                    $display("FAIL: result without completed accepted window");
                    $fatal(1);
                end
                pending_completed_window = 0;
                published_windows = published_windows + 1;
                if (last_result_valid) begin
                    $display("FAIL: result_valid held high for consecutive cycles");
                    $fatal(1);
                end
                if (read_ptr >= write_ptr) begin
                    $display("FAIL: extra/unexpected result (read=%0d, expected=%0d)",
                             read_ptr,write_ptr);
                    $fatal(1);
                end
                for (bin_check=0;bin_check<7;bin_check=bin_check+1) begin
                    if (s1_out[bin_check*SW +: SW] !==
                        expected_s1[read_ptr][bin_check*SW +: SW] ||
                        s2_out[bin_check*SW +: SW] !==
                        expected_s2[read_ptr][bin_check*SW +: SW]) begin
                        $display("FAIL: window=%0d bin=%0d",read_ptr,bin_check);
                        $display("  s1 expected=%h received=%h",
                            expected_s1[read_ptr][bin_check*SW +: SW],
                            s1_out[bin_check*SW +: SW]);
                        $display("  s2 expected=%h received=%h",
                            expected_s2[read_ptr][bin_check*SW +: SW],
                            s2_out[bin_check*SW +: SW]);
                        $fatal(1);
                    end
                end
                $display("PASS window %0d: all seven s1/s2 state pairs match",read_ptr);
                read_ptr = read_ptr + 1;
                pass_count = pass_count + 1;
            end else if (result_valid !== 1'b0) begin
                $display("FAIL: result_valid is X/Z");
                $fatal(1);
            end else if (outputs_initialized) begin
                if (s1_out !== last_s1 || s2_out !== last_s2) begin
                    $display("FAIL: outputs changed without result_valid");
                    $fatal(1);
                end
            end
            last_s1 = s1_out;
            last_s2 = s2_out;
            outputs_initialized = 1;
            last_result_valid = result_valid;
        end
    end

    // Valid and all payload fields remain stable until handshake.
    task send_sample;
        input signed [IW-1:0] x;
        input first;
        input last;
        integer gaps, cycles;
        reg accepted;
        begin
            gaps = ($random(seed) & 3);
            repeat (gaps) @(negedge clk);
            @(negedge clk);
            sample_in = x;
            sample_first = first;
            sample_last = last;
            sample_valid = 1'b1;
            accepted = 0;
            cycles = 0;
            while (!accepted && cycles < 100) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (sample_ready === 1'b1)
                    accepted = 1;
            end
            if (!accepted) begin
                $display("FAIL: handshake timeout for sample %0d",x);
                $fatal(1);
            end
            @(negedge clk);
            sample_valid = 1'b0;
            sample_first = 1'b0;
            sample_last = 1'b0;
        end
    endtask

    task drain_and_check;
        integer cycles;
        begin
            cycles = 0;
            while (read_ptr < write_ptr && cycles < 100) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            // Catch duplicate / late results after pipeline empties.
            repeat (100) @(negedge clk);
            if (pending_completed_window || published_windows != EXPECTED_RESULTS ||
                accepted_count != NUM_SAMPLES ||
                write_ptr != EXPECTED_RESULTS || read_ptr != EXPECTED_RESULTS) begin
                $display("FAIL: accepted=%0d/%0d expected_windows=%0d emitted=%0d/%0d",
                    accepted_count,NUM_SAMPLES,write_ptr,read_ptr,EXPECTED_RESULTS);
                $fatal(1);
            end
        end
    endtask

    initial begin
        if (N < 2 || NUM_SAMPLES < N || NUM_SAMPLES % N != 0 ||
            EXPECTED_RESULTS > MAX_RESULTS || IW > SW || SW+CW > 64) begin
            $display("FAIL: unsupported testbench parameters");
            $fatal(1);
        end
        seed = 32'h14653;
        pass_count = 0;
        reset_events = 0;
        repeat (4) @(negedge clk);
        rst = 0;

        $display("TEST 1: mid-window reset");
        for (i=0;i<PRE_RESET_SAMPLES;i=i+1)
            send_sample(i*277-1000, (i==0), 1'b0);
        @(negedge clk);
        rst = 1'b1;
        sample_valid = 1'b0;
        sample_first = 1'b0;
        sample_last = 1'b0;
        reset_events = reset_events+1;
        repeat (3) @(negedge clk);
        if (result_valid !== 1'b0 ||
            s1_out !== {7*SW{1'b0}} || s2_out !== {7*SW{1'b0}}) begin
            $display("FAIL: reset did not clear published results");
            $fatal(1);
        end
        rst = 1'b0;
        $display("Reset complete; discarded unfinished window");

        $display("TEST 2: %0d samples, N=%0d, no overlap",NUM_SAMPLES,N);
        for (i=0;i<NUM_SAMPLES;i=i+1) begin
            case (i % 11)
                0: stimulus = -32768;
                1: stimulus = 32767;
                2: stimulus = 0;
                3: stimulus = -1;
                default: stimulus = $random(seed);
            endcase
            send_sample(stimulus,(i % N == 0),(i % N == N-1));
        end
        drain_and_check;
        $display("===========================================");
        $display("PASS: nonoverlapping shared Goertzel verification");
        $display("N=%0d accepted=%0d",N,accepted_count);
        $display("Expected windows=%0d received=%0d",EXPECTED_RESULTS,read_ptr);
        $display("All seven s1/s2 state pairs matched for every window");
        $display("Mid-window resets tested=%0d",reset_events);
        $display("===========================================");
        $finish;
    end

    initial begin
        #1000000000;
        $display("FAIL: global simulation timeout");
        $fatal(1);
    end
endmodule
