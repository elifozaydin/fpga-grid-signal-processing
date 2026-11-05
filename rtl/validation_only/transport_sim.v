`timescale 1ns / 1ps

// ============================================================
//  Transport Test Top - Synthetic Input Verification
// ============================================================
//  Interface
//  ---------
//  Input          : Raw unsigned 12-bit samples in 8 MHz domain
//  Packet format  : [20-bit sequence, 12-bit ADC] 00 A3
//  Session header : 55 AA 55 AA D4 06
//  Clock domains  : 8 MHz write / 12 MHz SPI and FIFO read
//  SPI mode       : Mode 1, MSB-first, 1 MHz nominal
//
//  Replicates the base_top transport path using synthetic ADC
//  samples. Sequence numbers track all valid inputs, including
//  samples dropped when the serializer is busy.
// ============================================================

module transport_sim (
    input  wire        clk_8mhz,
    input  wire        clk_sys,
    input  wire        reset_8mhz,
    input  wire        reset_sys,
    input  wire        acq_en,
    input  wire        sample_valid,
    input  wire [11:0] sample_in,
    output wire        prog_full,
    input  wire        cs,
    input  wire        sclk,
    output wire        miso
);

    reg acq_en_prev;
    wire acq_start = acq_en && !acq_en_prev;
    reg [19:0] sample_sequence;
    wire [31:0] sample_data = {sample_sequence, sample_in};

    // Count all input samples, not only successfully queued frames.
    always @(posedge clk_8mhz) begin
        if (reset_8mhz || !acq_en || acq_start)
            sample_sequence <= 20'd0;
        else if (sample_valid)
            sample_sequence <= sample_sequence + 1'b1;
    end

    // -- Packet formatting and serialization -------------------

    reg [47:0] frame_data;
    reg        frame_pending;
    reg [2:0]  frame_byte_idx;
    reg        header_pending;
    reg [2:0]  header_byte_idx;

    wire       fifo_wr;
    reg [7:0]  fifo_din;
    wire       fifo_full;

    wire frame_last = frame_pending && !header_pending && fifo_wr &&
                      (frame_byte_idx == 3'd5);

    wire frame_ready = !frame_pending || frame_last;

    assign fifo_wr = !reset_8mhz && !fifo_full &&
                     (header_pending || frame_pending);

    always @(*) begin
        fifo_din = 8'h00;

        if (header_pending) begin
            case (header_byte_idx)
                3'd0: fifo_din = 8'h55;
                3'd1: fifo_din = 8'hAA;
                3'd2: fifo_din = 8'h55;
                3'd3: fifo_din = 8'hAA;
                3'd4: fifo_din = 8'hD4;
                3'd5: fifo_din = 8'h06;
                default: fifo_din = 8'h00;
            endcase
        end else if (frame_pending) begin
            case (frame_byte_idx)
                3'd0: fifo_din = frame_data[47:40];
                3'd1: fifo_din = frame_data[39:32];
                3'd2: fifo_din = frame_data[31:24];
                3'd3: fifo_din = frame_data[23:16];
                3'd4: fifo_din = frame_data[15:8];
                3'd5: fifo_din = frame_data[7:0];
                default: fifo_din = 8'h00;
            endcase
        end
    end

    always @(posedge clk_8mhz) begin
        if (reset_8mhz) begin
            acq_en_prev     <= 1'b0;
            frame_data      <= 48'd0;
            frame_pending   <= 1'b0;
            frame_byte_idx  <= 3'd0;
            header_pending  <= 1'b0;
            header_byte_idx <= 3'd0;
        end else begin
            acq_en_prev <= acq_en;

            // ESP32 must drain the previous session before restart.
            if (acq_start && !frame_pending && !header_pending) begin
                header_pending  <= 1'b1;
                header_byte_idx <= 3'd0;
            end

            if (fifo_wr) begin
                if (header_pending) begin
                    if (header_byte_idx == 3'd5) begin
                        header_pending  <= 1'b0;
                        header_byte_idx <= 3'd0;
                    end else begin
                        header_byte_idx <= header_byte_idx + 1'b1;
                    end
                end else begin
                    if (frame_byte_idx == 3'd5) begin
                        frame_pending  <= 1'b0;
                        frame_byte_idx <= 3'd0;
                    end else begin
                        frame_byte_idx <= frame_byte_idx + 1'b1;
                    end
                end
            end

            if (acq_en && sample_valid) begin
                if (frame_ready) begin
                    frame_data     <= {sample_data, 8'h00, 8'hA3};
                    frame_pending  <= 1'b1;
                    frame_byte_idx <= 3'd0;
                end

            end
        end
    end

    // -- Asynchronous FIFO -------------------------------------

    wire       fifo_rd;
    wire [7:0] fifo_dout;
    wire       fifo_empty;
    wire       fifo_valid;
    wire       fifo_prog_full;

    fifo_generator_0_1 u_fifo (
        .wr_clk   (clk_8mhz),
        .rd_clk   (clk_sys),
        .rst      (reset_sys),
        .din      (fifo_din),
        .wr_en    (fifo_wr),
        .rd_en    (fifo_rd),
        .dout     (fifo_dout),
        .full     (fifo_full),
        .empty    (fifo_empty),
        .valid    (fifo_valid),
        .prog_full(fifo_prog_full)
    );

    // -- ESP32 flow control ------------------------------------
    // During acquisition, the FPGA asserts prog_full when the FIFO
    // reaches its programmable threshold, signaling the ESP32 to
    // initiate a 512-byte SPI burst read.
    // After acquisition stops, the FPGA asserts prog_full whenever
    // data remains, allowing the ESP32 to drain the FIFO until it is empty.

    (* ASYNC_REG = "TRUE" *) reg [1:0] acq_sys_sync  = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] full_sys_sync = 2'b00;

    always @(posedge clk_sys) begin
        if (reset_sys) begin
            acq_sys_sync  <= 2'b00;
            full_sys_sync <= 2'b00;
        end else begin
            acq_sys_sync  <= {acq_sys_sync[0], acq_en};
            full_sys_sync <= {full_sys_sync[0], fifo_prog_full};
        end
    end

    assign prog_full = !reset_sys &&
                       (acq_sys_sync[1] ? full_sys_sync[1] : !fifo_empty);

    // -- SPI slave ---------------------------------------------
    // The 12 MHz FPGA clock samples the ESP32's 1 MHz SPI clock
    // and drives FIFO-to-MISO transmission (SPI mode 1).

    SPI_slave u_spi (
        .reset_sync(reset_sys),
        .clk_sys    (clk_sys),
        .cs         (cs),
        .sclk       (sclk),
        .miso       (miso),
        .fifo_empty (fifo_empty),
        .fifo_valid (fifo_valid),
        .fifo_dout  (fifo_dout),
        .fifo_rd    (fifo_rd)
    );

endmodule
