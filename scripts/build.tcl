#============================================================================
#  MyXTRV32  --  Vivado batch build (in-memory / non-project flow)
#    vivado -mode batch -source scripts/build.tcl                       # v0.3.1
#    vivado -mode batch -source scripts/build.tcl -tclargs myxtrv32_top_v4
#
#  Runs synthesis, implementation and bitstream generation in the current
#  process (no launch_runs sub-processes) and writes reports to out/.
#============================================================================
set root [file normalize [file dirname [file dirname [info script]]]]
set out  [file normalize "$root/out"]
set rtl  [file normalize "$root/rtl"]
set part "xc7z020clg400-2"

#---- top level selection (v0.3.1 multi-cycle core vs v0.4 pipeline) --------
if {[llength $argv] > 0} {
    set top [lindex $argv 0]
} else {
    set top "myxtrv32_top"
}
# optional second argument: "perf" enables the extended performance counters
set perf_ext 0
if {[llength $argv] > 1 && [lindex $argv 1] eq "perf"} {
    set perf_ext 1
}

file mkdir $out

puts "== MyXTRV32 build =="
puts "   root : $root"
puts "   part : $part"
puts "   top  : $top"

#---------------------------------------------------------------- sources
if {$perf_ext} {
    set_property verilog_define {PERF_EXT} [current_fileset]
    puts "   perf : extended counters ENABLED"
} else {
    puts "   perf : extended counters disabled (use -tclargs $top perf to enable)"
}

read_verilog "$rtl/myxtrv32_uart_tx.v"
read_verilog "$rtl/myxtrv32_ram.v"
read_verilog "$rtl/myxtrv32_rom.v"
if {$top eq "myxtrv32_top_v4"} {
    read_verilog "$rtl/myxtrv32_core_v4p.v"
    read_verilog "$rtl/myxtrv32_top_v4.v"
} else {
    read_verilog "$rtl/myxtrv32_core.v"
    read_verilog "$rtl/myxtrv32_top.v"
}
read_xdc "$root/constr/myxtrv32.xdc"

#---------------------------------------------------------------- synthesis
synth_design -top $top -part $part -flatten_hierarchy rebuilt
write_checkpoint -force "$out/post_synth_$top.dcp"
report_utilization -file "$out/utilization_${top}_synth.rpt"

#---------------------------------------------------------------- implementation
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore

write_checkpoint -force "$out/post_route_$top.dcp"

report_timing_summary -file "$out/timing_summary_$top.rpt" -warn_on_violation
report_utilization    -file "$out/utilization_$top.rpt" -hierarchical
report_drc            -file "$out/drc_$top.rpt"
report_power          -file "$out/power_$top.rpt"

#---------------------------------------------------------------- bitstream
write_bitstream -force "$out/$top.bit"
puts "== bitstream: $out/$top.bit =="

#---------------------------------------------------------------- summary
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "== TIMING: setup WNS = $wns ns, hold WHS = $whs ns =="
puts "== BUILD OK ($top) =="
