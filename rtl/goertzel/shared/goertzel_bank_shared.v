`timescale 1ns / 1ps

// Seven-bin shared engine. Accept only when sample_valid && sample_ready.
// Boundary flags belong to the accepted sample. One non-overlapping window.
// Results retain their previous values until all seven bins are published.
// Default coefficients: k=1944..1950, N=32000, Q2.24.
// Supported widths: INPUT_WIDTH <= STATE_WIDTH; 0 <= COEFF_FRAC < PRODUCT_WIDTH.
module goertzel_bank_shared #(
    parameter integer INPUT_WIDTH = 16,
    parameter integer STATE_WIDTH = 36,
    parameter integer COEFF_WIDTH = 26,
    parameter integer COEFF_FRAC  = 24,

    parameter signed [COEFF_WIDTH-1:0] COEFF_0 = 26'sd31139567, // k=1944
    parameter signed [COEFF_WIDTH-1:0] COEFF_1 = 26'sd31137112, // k=1945
    parameter signed [COEFF_WIDTH-1:0] COEFF_2 = 26'sd31134656, // k=1946
    parameter signed [COEFF_WIDTH-1:0] COEFF_3 = 26'sd31132199, // k=1947
    parameter signed [COEFF_WIDTH-1:0] COEFF_4 = 26'sd31129741, // k=1948
    parameter signed [COEFF_WIDTH-1:0] COEFF_5 = 26'sd31127281, // k=1949
    parameter signed [COEFF_WIDTH-1:0] COEFF_6 = 26'sd31124821  // k=1950
)(
    input  wire clk,
    input  wire rst,
    input  wire sample_valid,
    input  wire sample_first,
    input  wire sample_last,
    input  wire signed [INPUT_WIDTH-1:0] sample_in,

    output wire sample_ready,
    output reg result_valid,
    output reg signed [7*STATE_WIDTH-1:0] s1_out,
    output reg signed [7*STATE_WIDTH-1:0] s2_out
);


    localparam integer PRODUCT_WIDTH = STATE_WIDTH + COEFF_WIDTH;
    localparam integer ACC_WIDTH = PRODUCT_WIDTH + 2;
    localparam [2:0] IDLE=0, LOAD=1, MULTIPLY=2, UPDATE=3, PUBLISH=4;

    reg [2:0] state, bin_index;
    reg signed [INPUT_WIDTH-1:0] sample_hold;
    reg first_hold, last_hold;
    reg signed [STATE_WIDTH-1:0] s1 [0:6];
    reg signed [STATE_WIDTH-1:0] s2 [0:6];
    reg signed [STATE_WIDTH-1:0] prev_s1, prev_s2;
    reg signed [COEFF_WIDTH-1:0] coefficient;
    reg signed [PRODUCT_WIDTH-1:0] product;
    reg [7*STATE_WIDTH-1:0] stage_s1, stage_s2;
    integer j;

    assign sample_ready = !rst && (state == IDLE);

    function signed [COEFF_WIDTH-1:0] coeff_at;
        input [2:0] index;
        begin
            case (index)
                0: coeff_at = COEFF_0;
                1: coeff_at = COEFF_1;
                2: coeff_at = COEFF_2;
                3: coeff_at = COEFF_3;
                4: coeff_at = COEFF_4;
                5: coeff_at = COEFF_5;
                6: coeff_at = COEFF_6;
                default: coeff_at = 0;
            endcase
        end
    endfunction

    wire signed [PRODUCT_WIDTH-1:0] scaled_product;
    wire signed [ACC_WIDTH-1:0] scaled_ext, input_ext, prev_s2_ext;
    wire signed [ACC_WIDTH-1:0] next_state_full;
    wire signed [STATE_WIDTH-1:0] next_s1;
    assign scaled_product = product >>> COEFF_FRAC;
    assign scaled_ext = {{(ACC_WIDTH-PRODUCT_WIDTH){scaled_product[PRODUCT_WIDTH-1]}}, scaled_product};
    assign input_ext = {{(ACC_WIDTH-INPUT_WIDTH){sample_hold[INPUT_WIDTH-1]}}, sample_hold};
    assign prev_s2_ext = {{(ACC_WIDTH-STATE_WIDTH){prev_s2[STATE_WIDTH-1]}}, prev_s2};
    assign next_state_full = input_ext + scaled_ext - prev_s2_ext;
    assign next_s1 = next_state_full[STATE_WIDTH-1:0];

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            bin_index <= 0;
            sample_hold <= 0;
            first_hold <= 0;
            last_hold <= 0;
            prev_s1 <= 0;
            prev_s2 <= 0;
            coefficient <= 0;
            product <= 0;
            stage_s1 <= 0;
            stage_s2 <= 0;
            s1_out <= 0;
            s2_out <= 0;
            result_valid <= 0;
            for (j=0; j<7; j=j+1) begin
                s1[j] <= 0;
                s2[j] <= 0;
            end
        end else begin
            result_valid <= 0;
            case (state)
                IDLE: if (sample_valid) begin
                    sample_hold <= sample_in;
                    first_hold <= sample_first;
                    last_hold <= sample_last;
                    bin_index <= 0;
                    state <= LOAD;
                end
                LOAD: begin
                    prev_s1 <= first_hold ? {STATE_WIDTH{1'b0}} : s1[bin_index];
                    prev_s2 <= first_hold ? {STATE_WIDTH{1'b0}} : s2[bin_index];
                    coefficient <= coeff_at(bin_index);
                    state <= MULTIPLY;
                end
                MULTIPLY: begin
                    product <= $signed(coefficient) * $signed(prev_s1);
                    state <= UPDATE;
                end
                UPDATE: begin
                    s1[bin_index] <= next_s1;
                    s2[bin_index] <= prev_s1;
                    if (last_hold) begin
                        stage_s1[bin_index*STATE_WIDTH +: STATE_WIDTH] <= next_s1;
                        stage_s2[bin_index*STATE_WIDTH +: STATE_WIDTH] <= prev_s1;
                    end
                    if (bin_index == 6)
                        state <= last_hold ? PUBLISH : IDLE;
                    else begin
                        bin_index <= bin_index + 1'b1;
                        state <= LOAD;
                    end
                end
                PUBLISH: begin
                    s1_out <= stage_s1;
                    s2_out <= stage_s2;
                    result_valid <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
