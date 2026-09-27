create_project -force -part xc7s15ftgb196-1 sea_proj ./build_proj
add_files -fileset sources_1 [list top_10k.v iir_df2t.v]
add_files -fileset constrs_1 constraints.xdc
launch_runs synth_1 -jobs 4;  wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4;  wait_on_run impl_1
# 关键: slave-serial 只认 .bin
write_bitstream -force -bin_file [get_property DIRECTORY [get_runs impl_1]]/top_10k.bit
file copy -force ./build_proj/sea_proj.runs/impl_1/top_10k.bin ./fpga.bin
puts "DONE: fpga.bin generated"