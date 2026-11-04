#============================================================================
#  Create a regular Vivado project (GUI flow) for MyXTRV32
#    vivado -mode gui -source scripts/create_project.tcl
#  or  vivado -mode batch -source scripts/create_project.tcl
#  The project is written to vivado/myxtrv32/myxtrv32.xpr
#============================================================================
set root [file normalize [file dirname [file dirname [info script]]]]
set proj "$root/vivado/myxtrv32"
set rtl  "$root/rtl"

create_project myxtrv32 $proj -part xc7z020clg400-2 -force

add_files -norecurse "$rtl/myxtrv32_core.v"
add_files -norecurse "$rtl/myxtrv32_uart_tx.v"
add_files -norecurse "$rtl/myxtrv32_ram.v"
add_files -norecurse "$rtl/myxtrv32_rom.v"
add_files -norecurse "$rtl/myxtrv32_top.v"
add_files -fileset constrs_1 -norecurse "$root/constr/myxtrv32.xdc"

set_property top myxtrv32_top [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "== project created: $proj/myxtrv32.xpr =="
