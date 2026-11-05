# System Clock (12 MHz) 
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports clk_sys]
create_clock -period 83.333 -name clk_sys [get_ports clk_sys]

# Reset
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports reset]

# XADC Analog Inputs
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports A0_p]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports A0_n]

set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports A1_p]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports A1_n]

set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports A2_p]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports A2_n]

set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports A3_p]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS33} [get_ports A3_n]

set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports A4_p]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports A4_n]

set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports A5_p]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports A5_n]

# ESP32 SPI Interface 
set_property -dict {PACKAGE_PIN P13 IOSTANDARD LVCMOS33} [get_ports cs]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports sclk]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports miso]

# Enable acquisition (ESP32 -> FPGA)
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports acq_en_async]

# Request SPI reads (FPGA -> ESP32)
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVCMOS33} [get_ports prog_full]

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
