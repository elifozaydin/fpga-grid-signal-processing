// ============================================================
//  Testbench - Transport Integration Verification
// ============================================================
//  Design Specifications
//  ---------------------
//  Input data     : Synthetic 12-bit unsigned ADC samples
//  FIFO model     : Asynchronous, first-word fall-through
//  System clock   : 12 MHz (SPI and FIFO read)
//  Sample clock   : 8 MHz (packet formatter and FIFO write)
//  SPI            : Mode 1, 1 MHz, MSB-first
//  Session header : 55 AA 55 AA D4 06
//  Sample frame   : [20-bit sequence, 12-bit ADC] 00 A3
//
//  Verification
//  ------------
//  TC1 - Session header and packet framing
//  TC2 - Full-range sample patterns and multi-frame ordering
//  TC3 - Stop acquisition and drain remaining FIFO data
//  TC4 - New acquisition produces a new header
//  TC5 - FIFO byte accounting and programmable-full flow control
//
//  The testbench checks every SPI byte against an independent
//  expected-data queue. The vendor FIFO is replaced only in
//  simulation by a behavioral model with the same port contract.
// ============================================================

`timescale 1ns / 1ps

module tb_transport_integration;

    reg clk_8mhz = 1'b0;
    reg clk_sys = 1'b0;
    always #62.5 clk_8mhz = ~clk_8mhz;
    always #41.667 clk_sys = ~clk_sys;

    reg reset_8mhz = 1'b1;
    reg reset_sys  = 1'b1;
    reg acq_en = 1'b0;
    reg sample_valid = 1'b0;
    reg [11:0] sample_in = 12'd0;
    reg cs = 1'b1;
    reg sclk = 1'b0;
    wire miso;
    wire prog_full;

    transport_sim dut (
        .clk_8mhz(clk_8mhz),
        .clk_sys(clk_sys),
        .reset_8mhz(reset_8mhz),
        .reset_sys(reset_sys),
        .acq_en(acq_en),
        .sample_valid(sample_valid),
        .sample_in(sample_in),
        .prog_full(prog_full),
        .cs(cs),
        .sclk(sclk),
        .miso(miso)
    );

    // -- Expected SPI byte stream ------------------------------

    reg [7:0] expected [0:4095];
    integer expected_count = 0;
    integer received_count = 0;
    integer checks = 0;
    integer tests = 0;
    integer fifo_write_count = 0;
    integer fifo_read_count = 0;
    reg [19:0] expected_sequence = 20'd0;

    task expect_byte;
        input [7:0] value;
        begin
            expected[expected_count] = value;
            expected_count = expected_count + 1;
        end
    endtask

    task expect_header;
        begin
            expect_byte(8'h55);
            expect_byte(8'hAA);
            expect_byte(8'h55);
            expect_byte(8'hAA);
            expect_byte(8'hD4);
            expect_byte(8'h06);
        end
    endtask

    task expect_sample;
        input [11:0] value;
        begin
            expect_byte(expected_sequence[19:12]);
            expect_byte(expected_sequence[11:4]);
            expect_byte({expected_sequence[3:0], value[11:8]});
            expect_byte(value[7:0]);
            expect_byte(8'h00);
            expect_byte(8'hA3);
            expected_sequence = expected_sequence + 1'b1;
        end
    endtask

    // -- Synthetic sample injection ----------------------------

    task send_sample;
        input [11:0] value;
        begin
            @(negedge clk_8mhz);
            sample_in = value;
            sample_valid = 1'b1;
            @(negedge clk_8mhz);
            sample_valid = 1'b0;
            expect_sample(value);
            repeat (8) @(negedge clk_8mhz);
        end
    endtask

    task begin_acquisition;
        begin
            @(negedge clk_8mhz);
            acq_en = 1'b1;
            expected_sequence = 20'd0;
            expect_header();
            repeat (10) @(negedge clk_8mhz);
        end
    endtask

    task end_acquisition;
        begin
            @(negedge clk_8mhz);
            acq_en = 1'b0;
            sample_valid = 1'b0;
            repeat (12) @(negedge clk_8mhz);
        end
    endtask

    // -- Behavioral ESP32 SPI master (Mode 1) ------------------

    task spi_begin;
        begin
            sclk = 1'b0;
            cs = 1'b0;
            #1000;
        end
    endtask

    task spi_end;
        begin
            cs = 1'b1;
            sclk = 1'b0;
            #1000;
        end
    endtask

    task check_spi_byte;
        reg [7:0] value;
        integer b;
        begin
            value = 8'h00;
            for (b = 7; b >= 0; b = b - 1) begin
                #500;
                sclk = 1'b1;
                #470;
                value[b] = miso;
                #30;
                sclk = 1'b0;
            end
            if (received_count >= expected_count) begin
                $display("FAIL: unexpected SPI byte 0x%02h", value);
                $fatal(1);
            end
            checks = checks + 1;
            if (value !== expected[received_count]) begin
                $display("FAIL: byte %0d expected=%02h received=%02h",
                         received_count, expected[received_count], value);
                $fatal(1);
            end
            received_count = received_count + 1;
        end
    endtask

    task drain_expected;
        integer n;
        begin
            // Allow FIFO write-domain data to become visible to reader.
            #2000;
            spi_begin();
            while (received_count < expected_count)
                check_spi_byte();
            spi_end();
            #1000;
            if (fifo_read_count !== received_count) begin
                $display("FAIL: FIFO reads=%0d received=%0d",
                         fifo_read_count, received_count);
                $fatal(1);
            end
        end
    endtask

    // -- FIFO write/read interface assertions ------------------

    always @(posedge clk_8mhz)
        if (!reset_8mhz && dut.fifo_wr)
            fifo_write_count = fifo_write_count + 1;

    always @(posedge clk_sys)
        if (!reset_sys && dut.fifo_rd)
            fifo_read_count = fifo_read_count + 1;

    // -- Main integration tests --------------------------------

    initial begin
        repeat (8) @(negedge clk_sys);
        reset_sys = 1'b0;
        reset_8mhz = 1'b0;
        repeat (8) @(negedge clk_8mhz);

        // TC1: Session header and one sample
        $display("[TC1] Header and sample framing");
        begin_acquisition();
        send_sample(12'h123);
        end_acquisition();
        drain_expected();
        tests = tests + 1;

        // TC2: Multi-frame ordering and boundary values
        $display("[TC2] Sample patterns and ordering");
        begin_acquisition();
        send_sample(12'h000);
        send_sample(12'hFFF);
        send_sample(12'hAAA);
        send_sample(12'h555);
        send_sample(12'h001);
        send_sample(12'h800);
        send_sample(12'h2C7);
        #500;
        checks = checks + 1;
        if (prog_full !== 1'b1) begin
            $display("FAIL: prog_full not asserted above FIFO threshold");
            $fatal(1);
        end
        end_acquisition();
        drain_expected();
        tests = tests + 1;

        // TC3: All bytes are available after acquisition stops
        $display("[TC3] Stop and drain");
        if (prog_full !== 1'b0) begin
            $display("FAIL: prog_full remains high after FIFO drain");
            $fatal(1);
        end
        tests = tests + 1;

        // TC4: Acquisition restart and fresh session header
        $display("[TC4] Acquisition restart");
        begin_acquisition();
        send_sample(12'hB4E);
        send_sample(12'h00F);
        end_acquisition();
        drain_expected();
        tests = tests + 1;

        // TC5: FIFO byte accounting after all transport transactions
        $display("[TC5] FIFO transfer accounting");
        #2000;
        checks = checks + 1;
        if (fifo_write_count !== expected_count ||
            fifo_read_count !== expected_count) begin
            $display("FAIL: expected=%0d writes=%0d reads=%0d",
                     expected_count, fifo_write_count, fifo_read_count);
            $fatal(1);
        end
        tests = tests + 1;

        $display("PASS: %0d tests, %0d checks, %0d bytes",
                 tests, checks, received_count);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: integration simulation timeout");
        $fatal(1);
    end

endmodule

// ============================================================
//  Behavioral Asynchronous FWFT FIFO (Simulation Only)
// ============================================================
//  Models the relevant full/empty/valid and read/write behavior.
//  The programmable-full threshold is 24 bytes in this model.
// ============================================================

module fifo_generator_0_1 (
    input wire wr_clk,
    input wire rd_clk,
    input wire rst,
    input wire [7:0] din,
    input wire wr_en,
    input wire rd_en,
    output wire [7:0] dout,
    output wire full,
    output wire empty,
    output wire valid,
    output wire prog_full
);

    localparam integer DEPTH = 256;
    localparam integer PROG_THRESHOLD = 24;
    reg [7:0] memory [0:DEPTH-1];
    integer wr_ptr = 0;
    integer rd_ptr = 0;

    assign empty = (wr_ptr == rd_ptr);
    assign full = ((wr_ptr - rd_ptr) >= DEPTH);
    assign valid = !empty;
    assign prog_full = ((wr_ptr - rd_ptr) >= PROG_THRESHOLD);
    assign dout = empty ? 8'h00 : memory[rd_ptr % DEPTH];

    always @(posedge wr_clk or posedge rst) begin
        if (rst)
            wr_ptr <= 0;
        else if (wr_en) begin
            if (full) begin
                $display("FAIL: write to full FIFO");
                $fatal(1);
            end
            memory[wr_ptr % DEPTH] <= din;
            wr_ptr <= wr_ptr + 1;
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst)
            rd_ptr <= 0;
        else if (rd_en) begin
            if (empty) begin
                $display("FAIL: read from empty FIFO");
                $fatal(1);
            end
            rd_ptr <= rd_ptr + 1;
        end
    end

endmodule
