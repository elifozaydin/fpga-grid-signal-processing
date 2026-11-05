// ============================================================
//  CIC Decimator
// ============================================================
//
//  Specifications
//  --------------
//  Architecture : Cascaded Integrator-Comb (CIC)
//  Stages       : 4 integrators + 4 combs
//  Decimation   : 26 (R = 26)
//  Diff. delay  : 1 (M = 1)
//  Input        : 13-bit signed
//  Output       : 32-bit signed
//  Arithmetic   : Modulo-2^32 (two's-complement wraparound)
//  DC gain      : (R*M)^N = 26^4 = 456,976
//
//  Operation
//  ---------
//  Integrators update on each valid input sample.
//  Comb stages update once every 26 accepted samples.
//  output_valid pulses for one clock cycle per output.
//
// ============================================================

`timescale 1ns / 1ps

module cic_decimator (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [12:0] data_in,
    input  wire               input_valid,

    output reg  signed [31:0] data_out,
    output reg                output_valid
);

    // ── State registers ──────────────────────────────────────────
    reg [4:0] sample_count;

    reg signed [31:0] integrator1, integrator2, integrator3, integrator4;
    reg signed [31:0] comb_delay1, comb_delay2, comb_delay3, comb_delay4;

    wire signed [31:0] extended_input;
    wire signed [31:0] i1_next, i2_next, i3_next, i4_next;
    wire signed [31:0] c1_next, c2_next, c3_next, c4_next;

    // ── Integrator chain (input sample rate) ─────────────────────
    // Sign-extend the 13-bit input to the 32-bit datapath.
    assign extended_input = {{19{data_in[12]}}, data_in};

    // Use next-state values so the current sample propagates
    // through all four integrators before the decimation decision.
    assign i1_next = integrator1 + extended_input;
    assign i2_next = integrator2 + i1_next;
    assign i3_next = integrator3 + i2_next;
    assign i4_next = integrator4 + i3_next;

    // ── Comb chain (decimated sample rate) ───────────────────────
    // M = 1: subtract the previous input to each comb stage.
    // Fixed-width additions/subtractions wrap modulo 2^32.
    assign c1_next = i4_next - comb_delay1;
    assign c2_next = c1_next - comb_delay2;
    assign c3_next = c2_next - comb_delay3;
    assign c4_next = c3_next - comb_delay4;

    // ── Sequential state updates ─────────────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            sample_count <= 5'd0;

            integrator1  <= 32'sd0;
            integrator2  <= 32'sd0;
            integrator3  <= 32'sd0;
            integrator4  <= 32'sd0;

            comb_delay1  <= 32'sd0;
            comb_delay2  <= 32'sd0;
            comb_delay3  <= 32'sd0;
            comb_delay4  <= 32'sd0;

            data_out     <= 32'sd0;
            output_valid <= 1'b0;

        end else begin
            output_valid <= 1'b0;

            if (input_valid) begin
                // Update integrators on each accepted input sample.
                integrator1 <= i1_next;
                integrator2 <= i2_next;
                integrator3 <= i3_next;
                integrator4 <= i4_next;

                if (sample_count == 5'd25) begin
                    sample_count <= 5'd0;

                    // Update comb delays only at decimation instants.
                    comb_delay1 <= i4_next;
                    comb_delay2 <= c1_next;
                    comb_delay3 <= c2_next;
                    comb_delay4 <= c3_next;

                    data_out     <= c4_next;
                    output_valid <= 1'b1;

                end else begin
                    sample_count <= sample_count + 5'd1;
                end
            end
        end
    end

endmodule
