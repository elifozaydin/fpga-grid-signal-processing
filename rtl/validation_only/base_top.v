`timescale 1ns / 1ps

// ============================================================
//  Base Acquisition and SPI Transport
// ============================================================
//  Data Path
//  ---------
//  XADC -> Packet Formatter -> FIFO -> SPI
//
//  Clock Domains
//  -------------
//  clk_sys (12 MHz) : SPI slave and FIFO read interface
//  clk_8mhz         : XADC, packet formatter, FIFO write interface
//
//  Data Format (6 bytes per frame)
//  -------------------------------
//  Session header : 55 AA 55 AA D4 06
//  ADC sample     : [20-bit sequence, 12-bit ADC] [00] [A3]
//
//  Each frame contains a 20-bit sample sequence number and
//  the raw 12-bit unsigned ADC code. Sequence numbers advance
//  on every valid sample, including samples not packetized.
// ============================================================

module base_top (
    input  wire reset,
    input  wire clk_sys,
    input  wire acq_en_async,
    output wire prog_full,
    input  wire cs,
    input  wire sclk,
    output wire miso,
    input  wire A0_p, A0_n,
    input  wire A1_p, A1_n,
    input  wire A2_p, A2_n,
    input  wire A3_p, A3_n,
    input  wire A4_p, A4_n,
    input  wire A5_p, A5_n
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

    // -- XADC interface and DRP control ------------------------

    wire        xadc_drdy;
    wire        xadc_eoc;
    wire [15:0] xadc_data;
    wire [4:0]  xadc_channel;

    reg xadc_eoc_prev;
    wire xadc_eoc_pulse = xadc_eoc && !xadc_eoc_prev;

    always @(posedge clk_8mhz) begin
        if (reset_8mhz)
            xadc_eoc_prev <= 1'b0;
        else
            xadc_eoc_prev <= xadc_eoc;
    end

    reg [4:0] pending_channel;
    reg       pending_valid;
    reg       drp_busy;
    reg       drp_enable;
    reg [6:0] drp_address;
    reg [4:0] requested_channel;

    xadc_3 u_xadc (
        .dclk_in    (clk_8mhz),
        .reset_in   (reset_8mhz),
        .den_in     (drp_enable),
        .dwe_in     (1'b0),
        .di_in      (16'h0000),
        .daddr_in   (drp_address),
        .do_out     (xadc_data),
        .drdy_out   (xadc_drdy),
        .eoc_out    (xadc_eoc),
        .channel_out(xadc_channel),
        .vauxp0    (A0_p),  .vauxn0  (A0_n),
        .vauxp1    (A1_p),  .vauxn1  (A1_n),
        .vauxp9    (A2_p),  .vauxn9  (A2_n),
        .vauxp2    (A3_p),  .vauxn2  (A3_n),
        .vauxp10   (A4_p),  .vauxn10 (A4_n),
        .vauxp11   (A5_p),  .vauxn11 (A5_n),
        .vp_in     (1'b0),  .vn_in   (1'b0)
    );

    always @(posedge clk_8mhz) begin
        if (reset_8mhz) begin
            pending_channel   <= 5'd0;
            pending_valid     <= 1'b0;
            drp_busy          <= 1'b0;
            drp_enable        <= 1'b0;
            drp_address       <= 7'd0;
            requested_channel <= 5'd0;
        end else begin
            drp_enable <= 1'b0;

            if (acq_en && xadc_eoc_pulse && !pending_valid) begin
                pending_channel <= xadc_channel;
                pending_valid   <= 1'b1;
            end

            if (acq_en && pending_valid && !drp_busy) begin
                drp_address       <= {2'b00, pending_channel};
                requested_channel <= pending_channel;
                drp_enable        <= 1'b1;
                drp_busy          <= 1'b1;
                pending_valid     <= 1'b0;
            end

            if (!acq_en)
                pending_valid <= 1'b0;

            if (xadc_drdy)
                drp_busy <= 1'b0;
        end
    end

    wire [11:0] adc_sample = xadc_data[15:4];

    wire adc_a3_valid = acq_en && drp_busy && xadc_drdy &&
                        (requested_channel == 5'h12);

    // -- Raw ADC sample path -----------------------------------

    wire sample_valid = adc_a3_valid;
    reg [19:0] sample_sequence;
    wire [31:0] sample_data = {sample_sequence, adc_sample};

    // Count all valid XADC samples, even when the serializer is busy.
    always @(posedge clk_8mhz) begin
        if (reset_8mhz || !acq_en || acq_start)
            sample_sequence <= 20'd0;
        else if (sample_valid)
            sample_sequence <= sample_sequence + 1'b1;
    end

    reg acq_en_prev;
    wire acq_start = acq_en && !acq_en_prev;

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
