`timescale 1ns / 1ps

// ============================================================
//  FPGA Transport - Hardware Verification Top
// ============================================================
//  Data Path
//  ---------
//  Deterministic Test Pattern -> Packet Formatter -> FIFO -> SPI
//
//  Clock Domains
//  -------------
//  clk_sys (12 MHz) : SPI slave and FIFO read interface
//  clk_8mhz         : Test generator and FIFO write interface
//
//  Frame Format (6 bytes)
//  ----------------------
//  Session header : 55 AA 55 AA D4 06
//  Sample frame   : [20-bit sequence, 12-bit test pattern] 00 A3
//  Sample rate    : 1000 frames/s
// ============================================================

module transport_hw (
    input  wire reset,
    input  wire clk_sys,
    input  wire acq_en_async,
    output wire prog_full,
    input  wire cs,
    input  wire sclk,
    output wire miso
);

    // -- Clock generation and reset synchronization ------------
    
    wire clk_8mhz;
    clk_wiz_0 u_clk_wiz (
        .clk_out1(clk_8mhz),
        .clk_in1 (clk_sys)
    );
    
    // Asynchronous assertion, synchronous release.
    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sys_sync = 2'b11;
    always @(posedge clk_sys or posedge reset) begin
        if (reset) rst_sys_sync <= 2'b11;
        else rst_sys_sync <= {rst_sys_sync[0], 1'b0};
    end
    
    wire reset_sys = rst_sys_sync[1];
    
    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_8mhz_sync = 2'b11;
    always @(posedge clk_8mhz or posedge reset) begin
        if (reset) rst_8mhz_sync <= 2'b11;
        else rst_8mhz_sync <= {rst_8mhz_sync[0], 1'b0};
    end
    
    wire reset_8mhz = rst_8mhz_sync[1];

    // -- Acquisition enable synchronization --------------------
    // ESP32 acquisition GPIO is asynchronous to the 8 MHz domain.

    (* ASYNC_REG = "TRUE" *) reg [1:0] acq_en_sync = 2'b00;
    always @(posedge clk_8mhz) begin
        if (reset_8mhz) acq_en_sync <= 2'b00;
        else acq_en_sync <= {acq_en_sync[0], acq_en_async};
    end

    wire acq_en = acq_en_sync[1];

    // -- Deterministic sample generator ------------------------
    // 8 MHz / 8000 cycles = 1000 test frames per second.

    localparam integer SAMPLE_INTERVAL = 8000;
    reg [12:0] sample_timer;
    reg [19:0] sample_sequence;
    reg acq_en_prev;
    wire acq_start = acq_en && !acq_en_prev;
    wire sample_valid = acq_en && (sample_timer == SAMPLE_INTERVAL-1);

    function [11:0] test_pattern;
        input [2:0] index;
        begin
            case (index)
                3'd0: test_pattern = 12'h123;
                3'd1: test_pattern = 12'hFFF;
                3'd2: test_pattern = 12'h000;
                3'd3: test_pattern = 12'hA55;
                3'd4: test_pattern = 12'h5AA;
                3'd5: test_pattern = 12'h800;
                3'd6: test_pattern = 12'h001;
                3'd7: test_pattern = 12'hDAD;
            endcase
        end
    endfunction

    wire [31:0] sample_data = {sample_sequence,
                               test_pattern(sample_sequence[2:0])};

    always @(posedge clk_8mhz) begin
        if (reset_8mhz) begin
            acq_en_prev <= 1'b0;
            sample_timer <= 13'd0;
            sample_sequence <= 20'd0;
        end else begin
            acq_en_prev <= acq_en;
            if (!acq_en || acq_start) begin
                sample_timer <= 13'd0;
                sample_sequence <= 20'd0;
            end else if (sample_valid) begin
                sample_timer <= 13'd0;
                sample_sequence <= sample_sequence + 1'b1;
            end else begin
                sample_timer <= sample_timer + 1'b1;
            end
        end
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
            frame_data      <= 48'd0;
            frame_pending   <= 1'b0;
            frame_byte_idx  <= 3'd0;
            header_pending  <= 1'b0;
            header_byte_idx <= 3'd0;
        end else begin
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
