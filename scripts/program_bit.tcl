# Program a bitstream over hw_server.
#   xsct.bat scripts/program_bit.tcl out/myxtrv32_top_v4.bit
set bit [lindex $argv 0]
connect
puts [jtag targets]
fpga -file $bit
puts "== programmed: $bit =="
exit
