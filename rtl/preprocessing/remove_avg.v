// ============================================================
//  DC Offset Removal 
// ============================================================
//
//  Overview
//  --------
//  Computes the mean of a fixed number of ADC samples and
//  subtracts it from subsequent samples to remove DC offset.
//
//  Configuration
//  -------------
//  Input width  : 12-bit unsigned (default)
//  Output width : 13-bit signed (default)
//  Cal. samples : 4,274 (default)
//  Mean         : Rounded integer average
//  Reset        : Asynchronous, active-high
//
// ============================================================

`timescale 1ns / 1ps

module remove_avg #(
    parameter integer DATA_WIDTH = 12,
    parameter integer N_SAMPLES  = 4274
)(
    input  wire                      clk,
    input  wire                      rst,
    input  wire                      start_cal,
    input  wire                      valid_in,
    input  wire [DATA_WIDTH-1:0]     sample_in_u,

    output reg                       calib_done,
    output reg                       valid_out,
    output reg signed [DATA_WIDTH:0] sample_out_s,
    output wire [DATA_WIDTH-1:0]     mean_u_dbg
);

    // ── Internal state ───────────────────────────────────────────
    localparam integer CNTW = (N_SAMPLES > 1) ? $clog2(N_SAMPLES) : 1;
    localparam integer SUMW = DATA_WIDTH + $clog2(N_SAMPLES);

    localparam [SUMW:0] DIVISOR      = N_SAMPLES;
    localparam [SUMW:0] HALF_DIVISOR = N_SAMPLES / 2;

    reg [SUMW-1:0] sum;
    reg [CNTW-1:0] count;
    reg [DATA_WIDTH-1:0] mean_u;

    reg collecting;
    reg start_d;

    // ── Mean calculation ─────────────────────────────────────────
    // Detect the rising edge of the calibration request.
    wire start_pulse = start_cal && !start_d;

    // Include the current sample in the accumulated sum.
    wire [SUMW-1:0] sum_next = sum +
        {{(SUMW-DATA_WIDTH){1'b0}}, sample_in_u};

    // Round to the nearest integer using a constant divisor.
    wire [SUMW:0] rounded_sum  = {1'b0, sum_next} + HALF_DIVISOR;
    wire [SUMW:0] rounded_mean = rounded_sum / DIVISOR;

    // Extend both operands before signed mean subtraction.
    wire signed [DATA_WIDTH:0] sample_signed =
        $signed({1'b0, sample_in_u});

    wire signed [DATA_WIDTH:0] mean_signed =
        $signed({1'b0, mean_u});

    assign mean_u_dbg = mean_u;

    // ── Calibration and output control ───────────────────────────
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sum          <= 0;
            count        <= 0;
            mean_u       <= 0;
            collecting   <= 1'b0;
            start_d      <= 1'b0;
            calib_done   <= 1'b0;
            valid_out    <= 1'b0;
            sample_out_s <= 0;

        end else begin
            start_d   <= start_cal;
            valid_out <= 1'b0;

            if (start_pulse) begin
                // Restart calibration; discard this cycle's input.
                sum          <= 0;
                count        <= 0;
                mean_u       <= 0;
                collecting   <= 1'b1;
                calib_done   <= 1'b0;
                sample_out_s <= 0;

            end else if (collecting) begin
                if (valid_in) begin
                    sum <= sum_next;

                    if (count == N_SAMPLES-1) begin
                        // Latch the mean after the final valid sample.
                        mean_u     <= rounded_mean[DATA_WIDTH-1:0];
                        collecting <= 1'b0;
                        calib_done <= 1'b1;

                    end else begin
                        count <= count + 1'b1;
                    end
                end

            end else if (calib_done && valid_in) begin
                // Subtract the fixed mean from subsequent samples.
                sample_out_s <= sample_signed - mean_signed;
                valid_out    <= 1'b1;
            end
        end
    end

endmodule
