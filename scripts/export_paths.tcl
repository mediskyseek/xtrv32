#============================================================================
#  Export the worst setup paths and high-fanout nets from the routed v0.4p
#  checkpoint for static timing analysis.
#    vivado -mode batch -source scripts/export_paths.tcl
#============================================================================
set root [file normalize [file dirname [file dirname [info script]]]]
set out  [file normalize "$root/out"]

open_checkpoint "$out/post_route_myxtrv32_top_v4.dcp"

report_timing -delay_type max -max_paths 20 -nworst 20 \
    -path_type summary -file "$out/v4p_worst20_summary.rpt"

report_timing -delay_type max -max_paths 5 -nworst 5 \
    -path_type full_clock_expanded -file "$out/v4p_worst5_detail.rpt"

report_high_fanout_nets -max_nets 15 -file "$out/v4p_highfanout.rpt"

puts "== path export done =="
exit
