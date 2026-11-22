function Get-RtlLiberoSteps($Project) {
    $setup = @'
set rtlcheck_libero_project [file join $rtlcheck_artifacts libero-project]
set rtlcheck_libero_project_options [list -name rtlcheck_libero -location $rtlcheck_libero_project \
    -family $rtlcheck_family -die $rtlcheck_device -package $rtlcheck_package \
    -hdl VERILOG -use_enhanced_constraint_flow 1]
if {$rtlcheck_speed ne ""} {
    lappend rtlcheck_libero_project_options -speed $rtlcheck_speed
}
new_project {*}$rtlcheck_libero_project_options

set rtlcheck_libero_verilog_mode VERILOG_2K
set rtlcheck_libero_source_links {}
set rtlcheck_libero_source_files {}
foreach rtlcheck_libero_source $rtlcheck_sources {
    lappend rtlcheck_libero_source_links -hdl_source $rtlcheck_libero_source
    lappend rtlcheck_libero_source_files -file $rtlcheck_libero_source
    if {[string equal -nocase [file extension $rtlcheck_libero_source] .sv]} {
        set rtlcheck_libero_verilog_mode SYSTEM_VERILOG
    }
}
project_settings -verilog_mode $rtlcheck_libero_verilog_mode -abort_flow_on_sdc_errors TRUE
if {[llength $rtlcheck_include_dirs]} {
    set_global_include_path_order -paths $rtlcheck_include_dirs
}

if {[llength $rtlcheck_defines]} {
    # A global include makes the definitions visible to the design hierarchy and synthesis.
    set rtlcheck_libero_header [file join $rtlcheck_artifacts rtlcheck-defines.h]
    set rtlcheck_libero_header_stream [open $rtlcheck_libero_header {WRONLY CREAT EXCL}]
    fconfigure $rtlcheck_libero_header_stream -encoding utf-8 -translation lf
    foreach rtlcheck_libero_define $rtlcheck_defines {
        set rtlcheck_libero_equals [string first = $rtlcheck_libero_define]
        if {$rtlcheck_libero_equals < 0} {
            puts $rtlcheck_libero_header_stream "`define $rtlcheck_libero_define 1"
        } else {
            set rtlcheck_libero_macro_name [string range $rtlcheck_libero_define 0 [expr {$rtlcheck_libero_equals - 1}]]
            set rtlcheck_libero_macro_value [string range $rtlcheck_libero_define [expr {$rtlcheck_libero_equals + 1}] end]
            puts $rtlcheck_libero_header_stream "`define $rtlcheck_libero_macro_name $rtlcheck_libero_macro_value"
        }
    }
    close $rtlcheck_libero_header_stream
    create_links -hdl_source $rtlcheck_libero_header
    set_global_include_file -file $rtlcheck_libero_header
}

create_links {*}$rtlcheck_libero_source_links
build_design_hierarchy
set rtlcheck_libero_root ${rtlcheck_top}::work
set_root -module $rtlcheck_libero_root
organize_tool_files -tool SYNTHESIZE -module $rtlcheck_libero_root -input_type source {*}$rtlcheck_libero_source_files

set rtlcheck_libero_sdc_files {}
foreach rtlcheck_libero_constraint $rtlcheck_constraints {
    if {![string equal -nocase [file extension $rtlcheck_libero_constraint] .sdc]} {
        error "Libero expects an SDC timing constraint file: $rtlcheck_libero_constraint"
    }
    create_links -sdc $rtlcheck_libero_constraint
    lappend rtlcheck_libero_sdc_files -file $rtlcheck_libero_constraint
}
if {[llength $rtlcheck_libero_sdc_files]} {
    organize_tool_files -tool SYNTHESIZE -module $rtlcheck_libero_root -input_type constraint {*}$rtlcheck_libero_sdc_files
}
save_project

proc rtlcheck_libero_run {tool stage} {
    global rtlcheck_artifacts
    set report [file join $rtlcheck_artifacts "libero-$stage.log"]
    set run_code [catch {run_tool -name $tool} run_result run_options]
    set state_code [catch {get_tool_state -name $tool} state state_options]
    set log_code [catch {save_log -file $report} log_result log_options]
    if {$run_code != 0} {
        return -options $run_options $run_result
    }
    if {$state_code != 0} {
        return -options $state_options $state
    }
    set state [string trim $state]
    puts "$tool: $state"
    if {$state ne "Tool executed" && ![string match {Tool successfully run*} $state]} {
        error "Libero $tool did not complete successfully: $state"
    }
    if {$log_code != 0} {
        return -options $log_options $log_result
    }
    if {![file isfile $report] || [file size $report] == 0} {
        error "Libero did not produce a log for $tool: $report"
    }
}
'@
    $steps = [ordered]@{
        setup = [string[]]($setup -split '\r?\n')
        synthesize = [string[]]@('rtlcheck_libero_run SYNTHESIZE synthesize')
    }
    if ($Project.Synthesis.implementation) {
        $fit = @'
if {[llength $rtlcheck_libero_sdc_files]} {
    organize_tool_files -tool PLACEROUTE -module $rtlcheck_libero_root -input_type constraint {*}$rtlcheck_libero_sdc_files
}
rtlcheck_libero_run PLACEROUTE fit
'@
        $steps.fit = [string[]]($fit -split '\r?\n')
    }
    return $steps
}
