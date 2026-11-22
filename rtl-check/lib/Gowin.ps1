function Get-RtlGowinSteps($Project) {
    $steps = [ordered]@{
        setup = @'
set rtlcheck_gowin_project [file join $rtlcheck_artifacts gowin]
file mkdir $rtlcheck_gowin_project
cd $rtlcheck_gowin_project
set_device -name $rtlcheck_device_variant $rtlcheck_device
set_option -top_module $rtlcheck_top
set_option -output_base_name rtlcheck
set_option -verilog_std sysv2017
if {[llength $rtlcheck_include_dirs]} {
    set_option -include_path [join $rtlcheck_include_dirs ";"]
}
foreach rtlcheck_file $rtlcheck_constraints { add_file $rtlcheck_file }
'@ -split '\r?\n'
        synthesize = @'
foreach rtlcheck_file $rtlcheck_sources { add_file $rtlcheck_file }
run syn
set netlist [file join $rtlcheck_gowin_project impl gwsynthesis rtlcheck.vg]
if {![file isfile $netlist] || [file size $netlist] == 0} {
    error "GowinSynthesis did not create its mapped netlist"
}
'@ -split '\r?\n'
    }
    if ($Project.Synthesis.timing) { $steps.setup += 'set_option -gen_text_timing_rpt 1' }
    if ($Project.Synthesis.implementation) {
        $steps.fit = @'
run pnr
set pnr_report [file join $rtlcheck_gowin_project impl pnr rtlcheck.rpt.txt]
if {![file isfile $pnr_report] || [file size $pnr_report] == 0} {
    error "Gowin place and route did not create its implementation report"
}
'@ -split '\r?\n'
    }
    return $steps
}
