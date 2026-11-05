`timescale 1ns / 1ps

// Goertzel-only signal-processing path, Verilog-2001.
// Input is the registered signed 32-bit CIC output with a one-cycle valid.
// Processing: arithmetic shift/saturation -> 32000-sample window counter
//             -> seven parallel Q2.24 Goertzel recurrences.
// No raw streaming, packet formatting, FIFO or SPI in this module.
module goertzel_sim #(
    parameter integer CIC_SHIFT   = 16,
    parameter integer INPUT_WIDTH = 16,
    parameter integer STATE_WIDTH = 36,
    parameter integer WINDOW_N    = 32000
)(
    input  wire clk,
    input  wire rst,
    input  wire cic_valid,
    input  wire signed [31:0] cic_sample,

    output wire result_valid,
    output wire signed [7*STATE_WIDTH-1:0] s1_out,
    output wire signed [7*STATE_WIDTH-1:0] s2_out,

    // Observability for the stand-alone verification testbench.
    output wire signed [INPUT_WIDTH-1:0] sample_scaled,
    output wire sample_accept,
    output wire sample_first,
    output wire sample_last
);
    // Verilog-2001 function: smallest counter width, at least 1 bit.
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
            if (clog2 < 1) clog2 = 1;
        end
    endfunction

    localparam integer COUNT_WIDTH = clog2(WINDOW_N);
    localparam signed [31:0] INPUT_MAX = (32'sd1 <<< (INPUT_WIDTH-1)) - 1;
    localparam signed [31:0] INPUT_MIN = -(32'sd1 <<< (INPUT_WIDTH-1));

    wire signed [31:0] shifted = $signed(cic_sample) >>> CIC_SHIFT;
    assign sample_scaled = (shifted > INPUT_MAX) ? INPUT_MAX[INPUT_WIDTH-1:0] :
                           (shifted < INPUT_MIN) ? INPUT_MIN[INPUT_WIDTH-1:0] :
                           shifted[INPUT_WIDTH-1:0];

    reg [COUNT_WIDTH-1:0] sample_index;
    assign sample_accept = cic_valid && !rst;
    assign sample_first = sample_accept && (sample_index == 0);
    assign sample_last  = sample_accept && (sample_index == WINDOW_N-1);

    always @(posedge clk) begin
        if (rst)
            sample_index <= {COUNT_WIDTH{1'b0}};
        else if (sample_accept) begin
            if (sample_last)
                sample_index <= {COUNT_WIDTH{1'b0}};
            else
                sample_index <= sample_index + 1'b1;
        end
    end

    // Defaults in goertzel_bank.v are the Q2.24 coefficients for
    // Fs~=986.193294 Hz, N=32000, k=1944..1950.
    goertzel_bank #(
        .INPUT_WIDTH(INPUT_WIDTH),
        .STATE_WIDTH(STATE_WIDTH),
        .COEFF_WIDTH(26),
        .COEFF_FRAC(24)
    ) u_bank (
        .clk(clk), .rst(rst),
        .sample_valid(sample_accept),
        .sample_first(sample_first),
        .sample_last(sample_last),
        .sample_in(sample_scaled),
        .result_valid(result_valid),
        .s1_out(s1_out), .s2_out(s2_out)
    );
    
endmodule
