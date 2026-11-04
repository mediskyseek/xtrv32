#============================================================================
#  MyXTRV32 v0.1  --  Vivado batch build (in-memory / non-project flow)
#    vivado -mode batch -source scripts/build.tcl
#
#  Runs synthesis, implementation and bitstream generation in the current
#  process (no launch_runs sub-processes) and writes reports to out/.
#============================================================================
set root [file normalize [file dirname [file dirname [info script]]]]
set out  [file normalize "$root/out"]
set rtl  [file normalize "$root/rtl"]
set part "xc7z020clg400-2"

file mkdir $out

puts "== MyXTRV32 build =="
puts "   root : $root"
puts "   part : $part"

#---------------------------------------------------------------- sources
read_verilog "$rtl/myxtrv32_core.v"
read_verilog "$rtl/myxtrv32_uart_tx.v"
read_verilog "$rtl/myxtrv32_ram.v"
read_verilog "$rtl/myxtrv32_rom.v"
read_verilog "$rtl/myxtrv32_top.v"
read_xdc "$root/constr/myxtrv32.xdc"

#---------------------------------------------------------------- synthesis
synth_design -top myxtrv32_top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force "$out/post_synth.dcp"
report_utilization -file "$out/utilization_synth.rpt"

#---------------------------------------------------------------- implementation
opt_design
place_design
route_design

write_checkpoint -force "$out/post_route.dcp"

report_timing_summary -file "$out/timing_summary.rpt" -warn_on_violation
report_utilization    -file "$out/utilization.rpt" -hierarchical
report_drc            -file "$out/drc.rpt"
report_power          -file "$out/power.rpt"

#---------------------------------------------------------------- bitstream
write_bitstream -force "$out/myxtrv32_top.bit"
puts "== bitstream: $out/myxtrv32_top.bit =="

#---------------------------------------------------------------- summary
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "== TIMING: setup WNS = $wns ns, hold WHS = $whs ns =="
puts "== BUILD OK =="
