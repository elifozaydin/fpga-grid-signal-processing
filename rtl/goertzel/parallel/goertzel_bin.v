`timescale 1ns / 1ps

// ============================================================
// Single-Bin Fixed-Point Goertzel Core 
//
// Initial configuration (Experiment 3F, configuration B):
//   Input        : signed 16-bit integer
//   States       : signed 36-bit integer
//   Coefficient  : signed Q2.24 (26-bit)
//
// On each accepted sample:
//   s0 = x + ((COEFF * s1) >>> COEFF_FRAC) - s2
//   s2 = s1
//   s1 = s0
//
// Multiplication uses the full signed product width.
// Arithmetic right shift rounds toward negative infinity.
// State assignment intentionally wraps modulo 2^STATE_WIDTH.
//
// sample_first and sample_last must accompany sample_valid.
// sample_first uses zero recurrence history for that sample.
// sample_last captures the updated s1 and s2 into the outputs.
// result_valid pulses for one clock period on a completed window.
//
// One observation is active at a time. A higher-level controller
// must provide separate cores/state banks for overlapping windows.
// ============================================================

module goertzel_bin #(
    parameter integer INPUT_WIDTH = 16,
    parameter integer STATE_WIDTH = 36,
    parameter integer COEFF_WIDTH = 26,
    parameter integer COEFF_FRAC  = 24,
    parameter signed [COEFF_WIDTH-1:0] COEFF = {COEFF_WIDTH{1'b0}}
)(
    input  wire clk,
    input  wire rst,

    input  wire sample_valid,
    input  wire sample_first,
    input  wire sample_last,
    input  wire signed [INPUT_WIDTH-1:0] sample_in,

    output reg  result_valid,
    output reg  signed [STATE_WIDTH-1:0] s1_out,
    output reg  signed [STATE_WIDTH-1:0] s2_out
);

    localparam integer PRODUCT_WIDTH = STATE_WIDTH + COEFF_WIDTH;
    localparam integer ACC_WIDTH     = PRODUCT_WIDTH + 2;

    reg signed [STATE_WIDTH-1:0] s1;
    reg signed [STATE_WIDTH-1:0] s2;

    // The first valid sample of a new window starts from zero.
    wire signed [STATE_WIDTH-1:0] prev_s1;
    wire signed [STATE_WIDTH-1:0] prev_s2;
    assign prev_s1 = sample_first ? {STATE_WIDTH{1'b0}} : s1;
    assign prev_s2 = sample_first ? {STATE_WIDTH{1'b0}} : s2;

    // Full signed product: 36 x 26 = 62 bits with default params.
    wire signed [PRODUCT_WIDTH-1:0] product;
    assign product = $signed(COEFF) * $signed(prev_s1);

    // Signed arithmetic right shift = floor(product / 2^F).
    wire signed [PRODUCT_WIDTH-1:0] scaled_product;
    assign scaled_product = product >>> COEFF_FRAC;

    // Explicit sign extension avoids unintended unsigned arithmetic.
    wire signed [ACC_WIDTH-1:0] scaled_ext;
    wire signed [ACC_WIDTH-1:0] input_ext;
    wire signed [ACC_WIDTH-1:0] prev_s2_ext;

    assign scaled_ext =
        {{(ACC_WIDTH-PRODUCT_WIDTH){scaled_product[PRODUCT_WIDTH-1]}},
         scaled_product};
    assign input_ext =
        {{(ACC_WIDTH-INPUT_WIDTH){sample_in[INPUT_WIDTH-1]}},
         sample_in};
    assign prev_s2_ext =
        {{(ACC_WIDTH-STATE_WIDTH){prev_s2[STATE_WIDTH-1]}},
         prev_s2};

    wire signed [ACC_WIDTH-1:0] next_state_full;
    assign next_state_full = input_ext + scaled_ext - prev_s2_ext;

    // Retain low STATE_WIDTH bits: intentional two's-complement wrap.
    wire signed [STATE_WIDTH-1:0] next_s1;
    assign next_s1 = next_state_full[STATE_WIDTH-1:0];

    always @(posedge clk) begin
        if (rst) begin
            s1           <= {STATE_WIDTH{1'b0}};
            s2           <= {STATE_WIDTH{1'b0}};
            s1_out       <= {STATE_WIDTH{1'b0}};
            s2_out       <= {STATE_WIDTH{1'b0}};
            result_valid <= 1'b0;
        end else begin
            result_valid <= 1'b0;

            if (sample_valid) begin
                s1 <= next_s1;
                s2 <= prev_s1;

                if (sample_last) begin
                    // Both results include the final accepted sample.
                    s1_out       <= next_s1;
                    s2_out       <= prev_s1;
                    result_valid <= 1'b1;
                end
            end
        end
    end

endmodule
