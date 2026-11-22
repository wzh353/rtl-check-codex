function Get-RtlVivadoSteps($Project) {
    $steps = [ordered]@{
        setup = @'
if {[llength [get_parts -quiet [list $rtlcheck_device]]] != 1} {
    error "Vivado could not find the configured FPGA part $rtlcheck_device"
}
'@ -split '\r?\n'
        synthesize = @'
foreach rtlcheck_file $rtlcheck_sources {
    if {[string equal -nocase [file extension $rtlcheck_file] ".sv"]} {
        read_verilog -sv $rtlcheck_file
    } else {
        read_verilog $rtlcheck_file
    }
}
foreach rtlcheck_file $rtlcheck_constraints { read_xdc $rtlcheck_file }
set rtlcheck_options [list -top $rtlcheck_top -part $rtlcheck_device]
if {[llength $rtlcheck_include_dirs]} { lappend rtlcheck_options -include_dirs $rtlcheck_include_dirs }
foreach rtlcheck_define $rtlcheck_defines { lappend rtlcheck_options -verilog_define $rtlcheck_define }
synth_design {*}$rtlcheck_options
write_checkpoint -force [file join $rtlcheck_artifacts synthesized.dcp]
report_utilization -file [file join $rtlcheck_artifacts utilization.rpt]
'@ -split '\r?\n'
    }
    if ($Project.Synthesis.implementation) {
        $steps.fit = @'
opt_design
place_design
route_design
write_checkpoint -force [file join $rtlcheck_artifacts routed.dcp]
report_route_status -file [file join $rtlcheck_artifacts route-status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $rtlcheck_artifacts timing-summary.rpt]
'@ -split '\r?\n'
    }
    return $steps
}
