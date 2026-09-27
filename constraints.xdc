# !! 唯一待填项: 原理图 FPGA_Crystal 块中 SYSCLK 网络对应的 FPGA 球号 !!
# 查法: PDF 第2页找晶振 X2(O3225100MEDA4SC) OUT 脚网络 SYSCLK, 看它在 FPGA 框上挂的球号
# (必为 MRCC/SRCC 时钟脚)。查到后替换下行 <BALL>:
set_property PACKAGE_PIN H4 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# 数据通道 = 配置总线回收 (slave-serial 配置完成后转用户IO)
set_property PACKAGE_PIN B12 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property PACKAGE_PIN A8  [get_ports cts]
set_property IOSTANDARD LVCMOS33 [get_ports cts]
set_property PULLDOWN true   [get_ports cts]

# 10-pin 排针信号
set_property PACKAGE_PIN N14 [get_ports ext_pulse10k];   set_property IOSTANDARD LVCMOS33 [get_ports ext_pulse10k]
set_property PACKAGE_PIN M14 [get_ports sin_in];         set_property IOSTANDARD LVCMOS33 [get_ports sin_in]
set_property PACKAGE_PIN C4  [get_ports cos_in];         set_property IOSTANDARD LVCMOS33 [get_ports cos_in]
set_property PACKAGE_PIN B13 [get_ports sin_cos_select];  set_property IOSTANDARD LVCMOS33 [get_ports sin_cos_select]; set_property PULLDOWN true [get_ports sin_cos_select]

# 其余排针脚拉低防浮空
foreach p {N10 M10 B14 D3 P5 E11} {
    set_property IOSTANDARD LVCMOS33 [get_ports dummy_$p]
}
# (若不想加 dummy 端口, 删除上段即可; 未约束脚默认高阻, 可接受)