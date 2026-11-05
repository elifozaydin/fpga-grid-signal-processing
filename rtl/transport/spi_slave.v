`timescale 1ns / 1ps

// ============================================================
// Transfers FPGA FIFO data to the ESP32 over SPI.
// The ESP32 acts as the SPI master and initiates read transactions.
//
// SPI mode 1 (CPOL=0, CPHA=1).
// The FPGA's 12 MHz system clock samples the ESP32's 1 MHz
// SPI clock, detects rising edges, and shifts data onto MISO.
//
// FIFO interface assumes FWFT mode.
// ============================================================

module SPI_slave (
    input  wire       reset_sync,
    input  wire       clk_sys,

    input  wire       cs,
    input  wire       sclk,
    output reg        miso,

    input  wire       fifo_empty,
    input  wire       fifo_valid,
    input  wire [7:0] fifo_dout,
    output reg        fifo_rd
);

    // -- SPI input synchronization -----------------------------

    (* ASYNC_REG = "TRUE" *) reg [1:0] cs_sync   = 2'b11;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sclk_sync = 2'b00;

    reg sclk_prev = 1'b0;

    wire cs_active     = ~cs_sync[1];
    wire sclk_rising   = sclk_sync[1] && !sclk_prev;
    wire fifo_has_data = fifo_valid && !fifo_empty;

    // -- SPI transmission state --------------------------------

    reg [2:0] bit_cnt   = 3'd0;
    reg [7:0] shift_reg = 8'h00;

    always @(posedge clk_sys) begin
        if (reset_sync) begin
            cs_sync   <= 2'b11;
            sclk_sync <= 2'b00;
            sclk_prev <= 1'b0;

            bit_cnt   <= 3'd0;
            shift_reg <= 8'h00;
            miso      <= 1'b0;
            fifo_rd   <= 1'b0;

        end else begin
            cs_sync   <= {cs_sync[0], cs};
            sclk_sync <= {sclk_sync[0], sclk};
            sclk_prev <= sclk_sync[1];

            fifo_rd <= 1'b0;

            if (!cs_active) begin
                bit_cnt   <= 3'd0;
                shift_reg <= 8'h00;
                miso      <= 1'b0;

            end else if (sclk_rising) begin
                if (bit_cnt == 3'd0) begin
                    // Load a new byte, most significant bit first.
                    if (fifo_has_data) begin
                        miso      <= fifo_dout[7];
                        shift_reg <= {fifo_dout[6:0], 1'b0};
                        fifo_rd   <= 1'b1;
                    end else begin
                        miso      <= 1'b0;
                        shift_reg <= 8'b0;
                    end

                    bit_cnt <= 3'd1;

                end else begin
                    // Transmit the remaining seven bits.
                    miso      <= shift_reg[7];
                    shift_reg <= {shift_reg[6:0], 1'b0};

                    bit_cnt <= (bit_cnt == 3'd7)
                             ? 3'd0 : bit_cnt + 3'd1;
                end
            end
        end
    end

endmodule
