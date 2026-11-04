#============================================================================
#  MyXTRV32 v0.1  --  program the bitstream into the PL over JTAG
#    vivado -mode batch -source scripts/program.tcl
#  Requires the board to be connected to the local hw_server (USB JTAG).
#============================================================================
set root [file normalize [file dirname [file dirname [info script]]]]
set bit  [file normalize "$root/out/myxtrv32_top.bit"]

if {![file exists $bit]} {
    error "bitstream not found: $bit (run scripts/build.py first)"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

puts "== programming $dev with $bit =="
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "== done =="
close_hw_manager
