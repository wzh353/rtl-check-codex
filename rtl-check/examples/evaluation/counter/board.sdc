create_clock -name clk -period 20.000 [get_ports {clk}]
set_input_delay -clock clk -max 2.000 [get_ports {rst_n en}]
set_input_delay -clock clk -min 2.000 [get_ports {rst_n en}]
set_output_delay -clock clk -max 2.000 [get_ports {count[*]}]
set_output_delay -clock clk -min -0.100 [get_ports {count[*]}]
derive_clock_uncertainty