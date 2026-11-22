create_clock -name clk -period 14.000 [get_ports {clk}]
set_input_delay -clock clk -max 2.000 [get_ports {rst_n a[*] b[*] c[*]}]
set_input_delay -clock clk -min 2.000 [get_ports {rst_n a[*] b[*] c[*]}]
set_output_delay -clock clk -max 2.000 [get_ports {y[*]}]
set_output_delay -clock clk -min -0.100 [get_ports {y[*]}]
derive_clock_uncertainty