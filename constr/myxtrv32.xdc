#============================================================================
#  MyXTRV32 v0.1  --  pin / clock constraints for xc7z020clg400-2
#  Source of truth: IO_ZYNQ7020.xlsx
#    PL_CLK_MRCC  100 MHz   N18
#    RS232/expansion UART  TX = L14, RX = M15 (RX is unused by this core)
#    LED RUN      P18
#    LED ERROR    N17
#  All banks used here are 3.3 V on this board (BK34 = 3V3, extension
#  header BK35 = 3V3 setting must match; change to LVCMOS18 if BK35 is
#  actually strapped to 1.8 V).
#============================================================================

create_clock -period 10.000 -name sys_clk [get_ports clk]

set_property PACKAGE_PIN N18 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

set_property PACKAGE_PIN L14 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

set_property PACKAGE_PIN P18 [get_ports led_run]
set_property IOSTANDARD LVCMOS33 [get_ports led_run]

set_property PACKAGE_PIN N17 [get_ports led_error]
set_property IOSTANDARD LVCMOS33 [get_ports led_error]

#---------------------------------------------------------------------------
#  Configuration bank voltage (Zynq-7000 PL)
#---------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
