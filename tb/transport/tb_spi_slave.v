// ============================================================
//  Testbench - SPI Slave Verification
// ============================================================
//  Design Specifications
//  ---------------------
//  SPI mode       : Mode 1 (CPOL = 0, CPHA = 1)
//  System clock   : 12 MHz
//  SPI clock      : 1 MHz nominal; 500 kHz and 750 kHz tested
//  Data format    : 8-bit, MSB-first
//  FIFO interface : First-word fall-through (FWFT)
//
//  Verification
//  ------------
//  TC1 - Single-byte transmission
//  TC2 - Continuous multi-byte burst and data patterns
//  TC3 - Empty FIFO zero-fill without a read
//  TC4 - FIFO refill while chip select remains asserted
//  TC5 - Separate chip-select transactions
//  TC6 - Mid-byte transaction abort
//  TC7 - Synchronous reset recovery
//  TC8 - SPI transmission at 500 kHz
//  TC9 - SPI transmission at 750 kHz
//
//  The ESP32 master is modeled by SPI clock and chip-select
//  stimulus. Received MISO bytes and FIFO read counts are
//  checked automatically. A FIFO byte is consumed when
//  transmission of its first bit begins.
// ============================================================

`timescale 1ns / 1ps

module tb_spi_slave;

    localparam real SYS_HALF_NS = 41.667;  // 12 MHz (83.334 ns period)
    localparam integer FIFO_DEPTH  = 256;

    reg clk_sys = 1'b0;
    always #(SYS_HALF_NS) clk_sys = ~clk_sys;

    reg reset_sync = 1'b1;
    reg cs         = 1'b1;
    reg sclk       = 1'b0;
    wire miso;

    reg  [7:0] fifo_mem [0:FIFO_DEPTH-1];
    integer fifo_wr_ptr = 0;
    integer fifo_rd_ptr = 0;
    integer fifo_reads  = 0;
    integer checks      = 0;
    integer tests       = 0;
    integer spi_half_ns = 500;  // Default 1 MHz SPI SCLK

    wire fifo_empty = (fifo_rd_ptr == fifo_wr_ptr);
    wire fifo_valid = !fifo_empty;
    wire [7:0] fifo_dout = fifo_empty ? 8'h00 : fifo_mem[fifo_rd_ptr];
    wire fifo_rd;

    SPI_slave dut (
        .reset_sync(reset_sync),
        .clk_sys(clk_sys),
        .cs(cs),
        .sclk(sclk),
        .miso(miso),
        .fifo_empty(fifo_empty),
        .fifo_valid(fifo_valid),
        .fifo_dout(fifo_dout),
        .fifo_rd(fifo_rd)
    );

    // -- Behavioral FWFT FIFO and read monitor ----------------
    // The FIFO advances when it samples fifo_rd on clk_sys.
    // fifo_dout is combinationally visible before that read.

    always @(posedge clk_sys) begin
        if (fifo_rd) begin
            if (fifo_empty) begin
                $display("FAIL: FIFO read requested while empty at %0t", $time);
                $fatal(1);
            end
            fifo_rd_ptr = fifo_rd_ptr + 1;
            fifo_reads  = fifo_reads + 1;
        end
    end

    task fifo_push;
        input [7:0] value;
        begin
            @(negedge clk_sys);
            if (fifo_wr_ptr >= FIFO_DEPTH) begin
                $display("FAIL: test FIFO capacity exceeded");
                $fatal(1);
            end
            fifo_mem[fifo_wr_ptr] = value;
            fifo_wr_ptr = fifo_wr_ptr + 1;
        end
    endtask

    task assert_read_count;
        input integer expected;
        begin
            #300;  // Allow registered fifo_rd to reach FIFO.
            checks = checks + 1;
            if (fifo_reads !== expected) begin
                $display("FAIL: FIFO reads expected=%0d actual=%0d at %0t",
                         expected, fifo_reads, $time);
                $fatal(1);
            end
        end
    endtask

    // -- SPI Mode 1 master tasks -------------------------------

    task spi_begin;
        begin
            sclk = 1'b0;
            cs   = 1'b0;
            #1000;  // Ensure synchronized CS is recognized.
        end
    endtask

    task spi_end;
        begin
            cs   = 1'b1;
            sclk = 1'b0;
            #1000;
        end
    endtask

    task spi_clock_bit;
        output reg value;
        begin
            #(spi_half_ns);
            sclk = 1'b1;                // Mode 1: shift/change edge
            #(spi_half_ns - 30);
            value = miso;               // Observe setup before sample edge
            #30;
            sclk = 1'b0;                // Mode 1: sampling edge
        end
    endtask

    task spi_check_byte;
        input [7:0] expected;
        reg [7:0] received;
        reg sampled;
        integer bit_index;
        begin
            received = 8'h00;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_clock_bit(sampled);
                received[bit_index] = sampled;
            end
            checks = checks + 1;
            if (received !== expected) begin
                $display("FAIL: SPI byte expected=0x%02h received=0x%02h at %0t",
                         expected, received, $time);
                $fatal(1);
            end
        end
    endtask

    // -- Main test stimulus -----------------------------------

    initial begin
        $display("=== SPI_slave self-checking testbench ===");

        // Release synchronous reset.
        repeat (5) @(negedge clk_sys);
        reset_sync = 1'b0;
        #1000;

        // TC1: Single-byte transmission
        $display("TEST 1: single byte");
        fifo_push(8'hA5);
        spi_begin();
        spi_check_byte(8'hA5);
        spi_end();
        assert_read_count(1);
        tests = tests + 1;

        // TC2: Continuous burst and data patterns
        $display("TEST 2: multi-byte burst and patterns");
        fifo_push(8'h00);
        fifo_push(8'hFF);
        fifo_push(8'hAA);
        fifo_push(8'h55);
        fifo_push(8'h01);
        fifo_push(8'h80);
        spi_begin();
        spi_check_byte(8'h00);
        spi_check_byte(8'hFF);
        spi_check_byte(8'hAA);
        spi_check_byte(8'h55);
        spi_check_byte(8'h01);
        spi_check_byte(8'h80);
        spi_end();
        assert_read_count(7);
        tests = tests + 1;

        // TC3: Empty FIFO zero-fill
        $display("TEST 3: empty FIFO zero-fill");
        spi_begin();
        spi_check_byte(8'h00);
        spi_check_byte(8'h00);
        spi_end();
        assert_read_count(7);
        tests = tests + 1;

        // TC4: FIFO refill with CS asserted
        $display("TEST 4: FIFO refill under asserted CS");
        spi_begin();
        spi_check_byte(8'h00);
        fifo_push(8'h3C);
        spi_check_byte(8'h3C);
        spi_end();
        assert_read_count(8);
        tests = tests + 1;

        // TC5: Separate CS transactions
        $display("TEST 5: separate CS transactions");
        fifo_push(8'h96);
        fifo_push(8'h69);
        spi_begin();
        spi_check_byte(8'h96);
        spi_end();
        spi_begin();
        spi_check_byte(8'h69);
        spi_end();
        assert_read_count(10);
        tests = tests + 1;

        // TC6: Mid-byte CS abort
        $display("TEST 6: mid-byte CS abort");
        fifo_push(8'hC3);
        fifo_push(8'h5A);
        spi_begin();
        begin : abort_first_byte
            reg sampled;
            integer i;
            for (i = 0; i < 3; i = i + 1)
                spi_clock_bit(sampled);
        end
        spi_end();
        assert_read_count(11);
        spi_begin();
        spi_check_byte(8'h5A);
        spi_end();
        assert_read_count(12);
        tests = tests + 1;

        // TC7: Synchronous reset recovery
        $display("TEST 7: reset recovery");
        fifo_push(8'hF0);
        fifo_push(8'h0F);
        spi_begin();
        begin : reset_after_two_bits
            reg sampled;
            spi_clock_bit(sampled);
            spi_clock_bit(sampled);
        end
        @(negedge clk_sys);
        reset_sync = 1'b1;
        repeat (5) @(negedge clk_sys);
        cs         = 1'b1;
        reset_sync = 1'b0;
        #1000;
        assert_read_count(13);
        spi_begin();
        spi_check_byte(8'h0F);
        spi_end();
        assert_read_count(14);
        tests = tests + 1;

        // TC8: 500 kHz SPI clock
        $display("TEST 8: slower SPI clock");
        spi_half_ns = 1000;
        fifo_push(8'hD2);
        spi_begin();
        spi_check_byte(8'hD2);
        spi_end();
        assert_read_count(15);
        tests = tests + 1;

        // TC9: 750 kHz SPI clock
        $display("TEST 9: 750 kHz SPI clock");
        spi_half_ns = 667;
        fifo_push(8'hB7);
        spi_begin();
        spi_check_byte(8'hB7);
        spi_end();
        assert_read_count(16);
        tests = tests + 1;

        $display("PASS: %0d tests, %0d checks, %0d FIFO reads",
                 tests, checks, fifo_reads);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: simulation timeout");
        $fatal(1);
    end

endmodule
