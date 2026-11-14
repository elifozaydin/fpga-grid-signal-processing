`timescale 1ns / 1ps

// ============================================================
// Flow:
// XADC -> Mean Removal -> CIC -> {raw streaming + 7-bin Goertzel}
//                                -> Packet Formatter -> FIFO -> SPI
//
// Clock domains:
//   clk_sys (12 MHz): FIFO reads, SPI slave, ESP32 flow control
//   clk_8mhz        : XADC, preprocessing, timing, FIFO writes
//
// Sampling-rate measurement:
//   The FPGA counts 8 MHz clock cycles across 1024 CIC output
//   intervals to verify the actual output sampling rate.
//   MATLAB uses these measurements for accurate sample timing
//   and frequency estimation.
//
// SPI frames (6-bytes):
//   Session header: 55 AA 55 AA D4 06
//   CIC sample:     [signed 32-bit sample, BE] [00] [A3]
//   Timing:         [unsigned 32-bit cycles, BE] [80] [A3]
//   Goertzel s1 low32 : [32-bit low word, BE] [B0..B6] [A3]
//   Goertzel s2 low32 : [32-bit low word, BE] [C0..C6] [A3]
//   Goertzel s1 high4 : [zero-extended upper nibble, BE] [D0..D6] [A3]
//   Goertzel s2 high4 : [zero-extended upper nibble, BE] [E0..E6] [A3]
//   Each completed 32000-sample observation emits 28 frames.
//   To reconstruct signed 36-bit state, concatenate high[3:0]
//   with low[31:0], then sign-extend from bit 35.
//   No window identifier is encoded; frames must not be dropped.
//   Bin indices: 1944..1950 at nominal Fs = 986.193294 Hz.
//   First prototype uses nonoverlapping windows.
//
// ESP32 records the raw SPI byte stream.
// ============================================================

module top (
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

    reg acq_en_prev;
    wire acq_start = acq_en && !acq_en_prev;

    // -- XADC interface: read only the physical A3 input -------
    // A3_p/A3_n are connected to VAUX2 in this design (channel 0x12).
    // EOC marks a completed conversion; DRDY marks valid DRP data.

    localparam [4:0] A3_CHANNEL = 5'h12;

    wire        xadc_drdy;
    wire        xadc_eoc;
    wire [15:0] xadc_data;
    wire [4:0]  xadc_channel;

    wire        a3_eoc = xadc_eoc && (xadc_channel == A3_CHANNEL);
    wire        drp_enable = acq_en && !reset_8mhz && a3_eoc;
    wire [6:0]  drp_address = {2'b00, A3_CHANNEL};

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

    wire [11:0] adc_sample = xadc_data[15:4];
    wire adc_a3_valid = acq_en && !reset_8mhz && xadc_drdy;

    // -- DC offset removal -------------------------------------

    wire               centered_valid;
    wire signed [12:0] centered_sample;

    remove_avg #(
        .DATA_WIDTH(12),
        .N_SAMPLES (4274)
    ) u_remove_avg (
        .clk         (clk_8mhz),
        .rst         (reset_8mhz),
        .start_cal   (acq_en),
        .valid_in    (adc_a3_valid),
        .sample_in_u (adc_sample),
        .calib_done  (),
        .valid_out   (centered_valid),
        .sample_out_s(centered_sample),
        .mean_u_dbg  ()
    );

    // -- CIC decimation ----------------------------------------

    wire               cic_valid;
    wire signed [31:0] cic_sample;
    wire cic_reset = reset_8mhz | ~acq_en;

    cic_decimator u_cic (
        .clk         (clk_8mhz),
        .rst         (cic_reset),
        .data_in     (centered_sample),
        .input_valid (centered_valid),
        .data_out    (cic_sample),
        .output_valid(cic_valid)
    );

    // -- Fixed-point shared Goertzel --------------------------
    // Configuration B from MATLAB Experiment 3F:
    //   CIC output:  signed 32-bit
    //   input:       signed 16-bit after >>> 16, saturation
    //   state:       signed 36-bit
    //   coefficient: signed Q2.24 (26-bit)
    //   window:      32000 valid CIC samples, no overlap
    // This shift must remain consistent with MATLAB/RTL validation.
    localparam integer GOERTZEL_INPUT_SHIFT = 16;
    localparam integer GOERTZEL_N = 32000;
    localparam integer GOERTZEL_STATE_WIDTH = 36;

    wire signed [31:0] g_scaled32 =
        $signed(cic_sample) >>> GOERTZEL_INPUT_SHIFT;

    wire signed [15:0] g_sample =
        (g_scaled32 > 32'sd32767)  ? 16'sd32767 :
        (g_scaled32 < -32'sd32768) ? -16'sd32768 :
        g_scaled32[15:0];

    // Count accepted CIC outputs, not clk_8mhz cycles.
    reg [14:0] g_sample_index;
    wire g_valid = acq_en && cic_valid;
    wire g_first = g_valid && (g_sample_index == 15'd0);
    wire g_last  = g_valid && (g_sample_index == GOERTZEL_N-1);

    always @(posedge clk_8mhz) begin
        if (reset_8mhz || !acq_en)
            g_sample_index <= 15'd0;
        else if (g_valid) begin
            if (g_last)
                g_sample_index <= 15'd0;
            else
                g_sample_index <= g_sample_index + 1'b1;
        end
    end

    wire g_result_valid;
    wire signed [7*GOERTZEL_STATE_WIDTH-1:0] g_s1;
    wire signed [7*GOERTZEL_STATE_WIDTH-1:0] g_s2;
    wire g_sample_ready;

    // Shared engine processes one accepted CIC sample over multiple cycles.
    // CIC outputs are spaced by ~8112 clocks, so the engine returns to
    // ready well before the next CIC sample at the nominal sample rate.
    // Retain the established 32000-sample nonoverlapping window scheme.
    goertzel_bank_shared #(
        .INPUT_WIDTH(16),
        .STATE_WIDTH(GOERTZEL_STATE_WIDTH),
        .COEFF_WIDTH(26),
        .COEFF_FRAC(24),
        .COEFF_0(26'sd31139567),
        .COEFF_1(26'sd31137112),
        .COEFF_2(26'sd31134656),
        .COEFF_3(26'sd31132199),
        .COEFF_4(26'sd31129741),
        .COEFF_5(26'sd31127281),
        .COEFF_6(26'sd31124821)
    ) u_goertzel_bank (
        .clk(clk_8mhz),
        .rst(cic_reset),
        .sample_valid(g_valid),
        .sample_first(g_first),
        .sample_last(g_last),
        .sample_in(g_sample),
        .sample_ready(g_sample_ready),
        .result_valid(g_result_valid),
        .s1_out(g_s1),
        .s2_out(g_s2)
    );

    // Store one completed observation while it is serialized.
    // Each signed 36-bit state is sent in two existing 6-byte
    // frames: low 32 bits and a zero-extended high nibble.
    // 7 bins x 2 states x 2 frames = 28 frames.
    reg [7*GOERTZEL_STATE_WIDTH-1:0] g_saved_s1;
    reg [7*GOERTZEL_STATE_WIDTH-1:0] g_saved_s2;
    reg         g_pending;
    reg [4:0]   g_frame_index;   // 0..27
    reg         g_overrun;       // sticky debug indication
    wire        g_frame_take;

    always @(posedge clk_8mhz) begin
        if (reset_8mhz || acq_start) begin
            g_saved_s1    <= {(7*GOERTZEL_STATE_WIDTH){1'b0}};
            g_saved_s2    <= {(7*GOERTZEL_STATE_WIDTH){1'b0}};
            g_pending     <= 1'b0;
            g_frame_index <= 5'd0;
            g_overrun     <= 1'b0;
        end else begin
            if (g_result_valid) begin
                if (g_pending && !(g_frame_take && g_frame_index == 5'd27))
                    g_overrun <= 1'b1;
                else begin
                    g_saved_s1    <= g_s1;
                    g_saved_s2    <= g_s2;
                    g_pending     <= 1'b1;
                    g_frame_index <= 5'd0;
                end
            end else if (g_frame_take) begin
                if (g_frame_index == 5'd27) begin
                    g_pending     <= 1'b0;
                    g_frame_index <= 5'd0;
                end else
                    g_frame_index <= g_frame_index + 1'b1;
            end
        end
    end

    // Serialization order:
    //   0..6   s1 low32, 7..13  s1 high4
    //   14..20 s2 low32, 21..27 s2 high4
    wire [2:0] g_bin_index =
        (g_frame_index < 5'd7)  ? g_frame_index[2:0] :
        (g_frame_index < 5'd14) ? (g_frame_index - 5'd7) :
        (g_frame_index < 5'd21) ? (g_frame_index - 5'd14) :
                                   (g_frame_index - 5'd21);

    wire [GOERTZEL_STATE_WIDTH-1:0] g_selected_state =
        (g_frame_index < 5'd14) ?
            g_saved_s1[g_bin_index*GOERTZEL_STATE_WIDTH +: GOERTZEL_STATE_WIDTH] :
            g_saved_s2[g_bin_index*GOERTZEL_STATE_WIDTH +: GOERTZEL_STATE_WIDTH];

    wire g_high_part =
        ((g_frame_index >= 5'd7)  && (g_frame_index < 5'd14)) ||
        (g_frame_index >= 5'd21);

    wire [31:0] g_frame_state = g_high_part ?
        {28'd0, g_selected_state[35:32]} : g_selected_state[31:0];

    wire [7:0] g_frame_tag =
        ((g_frame_index < 5'd7) ? 8'hB0 :
         (g_frame_index < 5'd14) ? 8'hD0 :
         (g_frame_index < 5'd21) ? 8'hC0 : 8'hE0)
        + {5'd0, g_bin_index};

    // -- Sample-rate timing measurement ------------------------

    localparam integer TIMING_INTERVALS = 1024;
    localparam integer TIMING_COUNT_WIDTH = $clog2(TIMING_INTERVALS);

    // Free-running counter timestamps CIC output events in 8 MHz cycles.
    // Report elapsed cycles across 1024 consecutive output intervals.
    // Unsigned subtraction works even if cycle_counter wraps once.

    reg [31:0] cycle_counter;
    reg [31:0] timing_start_cycle;
    reg [TIMING_COUNT_WIDTH-1:0] timing_interval_count;
    reg timing_started;
    reg [31:0] timing_cycles;
    reg timing_pending;

    wire timing_due = (timing_interval_count == TIMING_INTERVALS - 1);
    wire timing_take;

    always @(posedge clk_8mhz) begin
        if (reset_8mhz) begin
            cycle_counter         <= 32'd0;
            timing_start_cycle    <= 32'd0;
            timing_interval_count <= {TIMING_COUNT_WIDTH{1'b0}};
            timing_started        <= 1'b0;
            timing_cycles         <= 32'd0;
            timing_pending        <= 1'b0;
        end else begin
            cycle_counter <= cycle_counter + 1'b1;

            if (acq_start || !acq_en) begin
                timing_started        <= 1'b0;
                timing_interval_count <= {TIMING_COUNT_WIDTH{1'b0}};
                timing_pending        <= 1'b0;
            end else begin
                if (timing_take)
                    timing_pending <= 1'b0;

                if (cic_valid) begin
                    if (!timing_started) begin
                        timing_start_cycle <= cycle_counter;
                        timing_started     <= 1'b1;
                    end else if (timing_due) begin
                        timing_start_cycle    <= cycle_counter;
                        timing_interval_count <= {TIMING_COUNT_WIDTH{1'b0}};

                        if (!timing_pending || timing_take) begin
                            timing_cycles  <= cycle_counter - timing_start_cycle;
                            timing_pending <= 1'b1;
                        end
                    end else begin
                        timing_interval_count <= timing_interval_count + 1'b1;
                    end
                end
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

    // Normal samples take priority over timing metadata.
    // A timing report is sent only in a free serialization slot.

    // Raw samples retain highest priority. Completed Goertzel
    // state fragments use idle serializer slots; timing reports come next.
    assign g_frame_take = g_pending &&
                          !(cic_valid && acq_en) &&
                          frame_ready && !header_pending;

    assign timing_take = acq_en && timing_pending &&
                         !(cic_valid && acq_en) && !g_frame_take &&
                         frame_ready && !header_pending;

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

            if (acq_en && cic_valid) begin
                if (frame_ready) begin
                    frame_data     <= {cic_sample, 8'h00, 8'hA3};
                    frame_pending  <= 1'b1;
                    frame_byte_idx <= 3'd0;
                end
            end else if (g_frame_take) begin
                frame_data     <= {g_frame_state, g_frame_tag, 8'hA3};
                frame_pending  <= 1'b1;
                frame_byte_idx <= 3'd0;
            end else if (timing_take) begin
                frame_data     <= {timing_cycles, 8'h80, 8'hA3};
                frame_pending  <= 1'b1;
                frame_byte_idx <= 3'd0;
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
