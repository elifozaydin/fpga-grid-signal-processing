`timescale 1ns / 1ps

// ============================================================
// Seven-Bin Parallel Goertzel Bank 
//
// Instantiates seven independent goertzel_bin cores.
// All cores receive identical sample and window controls.
// Each core uses its own constant recurrence coefficient.
//
// Configuration (Experiment 3F, Configuration B):
//   Fs          = 986.193294 Hz
//   N           = 32000 samples
//   Bins        = 1944 through 1950
//   Input       = signed 16-bit
//   States      = signed 36-bit
//   Coefficient = Q2.24, signed 26-bit
//
// sample_first and sample_last must be asserted with
// sample_valid on the first and last samples, respectively.
//
// Output packing:
//   s1_out[STATE_WIDTH*0 +: STATE_WIDTH] = bin 0 (k=1944)
//   s1_out[STATE_WIDTH*1 +: STATE_WIDTH] = bin 1 (k=1945)
//   ...
//   s1_out[STATE_WIDTH*6 +: STATE_WIDTH] = bin 6 (k=1950)
//
// The same packing convention applies to s2_out.
//
// Supports one non-overlapping observation at a time.
// Overlapping observations require separate state banks.
// ============================================================

module goertzel_bank #(
    parameter integer INPUT_WIDTH = 16,
    parameter integer STATE_WIDTH = 36,
    parameter integer COEFF_WIDTH = 26,
    parameter integer COEFF_FRAC  = 24,

    // Q2.24 coefficients from Experiment 3F
    //
    // Cint = round(2*cos(2*pi*k/N) * 2^24)
    //
    // Fs = 986.193294 Hz, N = 32000
    // k  = 1944 through 1950

    parameter signed [COEFF_WIDTH-1:0] COEFF_0 = 26'sd31139567,
    parameter signed [COEFF_WIDTH-1:0] COEFF_1 = 26'sd31137112,
    parameter signed [COEFF_WIDTH-1:0] COEFF_2 = 26'sd31134656,
    parameter signed [COEFF_WIDTH-1:0] COEFF_3 = 26'sd31132199,
    parameter signed [COEFF_WIDTH-1:0] COEFF_4 = 26'sd31129741,
    parameter signed [COEFF_WIDTH-1:0] COEFF_5 = 26'sd31127281,
    parameter signed [COEFF_WIDTH-1:0] COEFF_6 = 26'sd31124821
)(
    input  wire clk,
    input  wire rst,

    input  wire sample_valid,
    input  wire sample_first,
    input  wire sample_last,
    input  wire signed [INPUT_WIDTH-1:0] sample_in,

    output wire result_valid,
    output wire signed [7*STATE_WIDTH-1:0] s1_out,
    output wire signed [7*STATE_WIDTH-1:0] s2_out
);

    // Each core generates its own result_valid pulse.
    wire [6:0] bin_result_valid;

    // --------------------------------------------------------
    // Seven parallel Goertzel cores
    // --------------------------------------------------------

    genvar i;

    generate
        for (i = 0; i < 7; i = i + 1) begin : g_bin

            // Select coefficient at elaboration time.
            // No runtime multiplexer is required.

            localparam signed [COEFF_WIDTH-1:0] BIN_COEFF =
                (i == 0) ? COEFF_0 :
                (i == 1) ? COEFF_1 :
                (i == 2) ? COEFF_2 :
                (i == 3) ? COEFF_3 :
                (i == 4) ? COEFF_4 :
                (i == 5) ? COEFF_5 :
                           COEFF_6;

            goertzel_bin #(
                .INPUT_WIDTH(INPUT_WIDTH),
                .STATE_WIDTH(STATE_WIDTH),
                .COEFF_WIDTH(COEFF_WIDTH),
                .COEFF_FRAC (COEFF_FRAC),
                .COEFF      (BIN_COEFF)
            ) u_bin (
                .clk          (clk),
                .rst          (rst),

                .sample_valid (sample_valid),
                .sample_first (sample_first),
                .sample_last  (sample_last),
                .sample_in    (sample_in),

                .result_valid (bin_result_valid[i]),

                .s1_out       (
                    s1_out[i*STATE_WIDTH +: STATE_WIDTH]
                ),

                .s2_out       (
                    s2_out[i*STATE_WIDTH +: STATE_WIDTH]
                )
            );

        end
    endgenerate

    // --------------------------------------------------------
    // Combined result-valid signal
    //
    // Since all seven cores receive the same sample controls,
    // their result_valid pulses should occur simultaneously.
    // --------------------------------------------------------

    assign result_valid = &bin_result_valid;

endmodule
