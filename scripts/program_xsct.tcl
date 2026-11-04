# Program the MyXTRV32 bitstream through hw_server (no cs_server needed).
#   D:\Xilinx\Vitis\2024.2\bin\xsct.bat scripts/program_xsct.tcl

set bit "D:/dev27/z7skytum/myxtrv32/out/myxtrv32_top.bit"

connect
puts "== connected to hw_server =="
puts [jtag targets]

fpga -file $bit
puts "== programmed: $bit =="
exit
