function Get-RtlLatticeSteps($Project) {
    $setup = @'
set rtlcheck_lattice_project [file join $rtlcheck_artifacts project]
if {[file exists $rtlcheck_lattice_project]} {
    error "The Lattice project directory already exists: $rtlcheck_lattice_project"
}
file mkdir $rtlcheck_lattice_project
cd $rtlcheck_lattice_project

# Only a netlist generated in this new project can satisfy a stage check.
proc rtlcheck_lattice_require_output {stage patterns {excluded_pattern {}}} {
    global rtlcheck_lattice_project
    foreach directory [list [file join $rtlcheck_lattice_project impl1] $rtlcheck_lattice_project] {
        foreach candidate [glob -nocomplain -directory $directory -types f -- {*}$patterns] {
            if {[string match -nocase $excluded_pattern [file tail $candidate]]} {
                continue
            }
            if {[file size $candidate] > 0} {
                puts "$stage output: $candidate"
                return
            }
        }
    }
    error "$stage did not generate a nonempty [join $patterns { or }] artifact."
}

set rtlcheck_lattice_create [list -name rtl_check -impl impl1 -impl_dir impl1 -dev $rtlcheck_device]
'@

    if ($Project.Synthesis.engine -eq 'diamond') {
        # Lattice Diamond 3.14 Help, Tcl Command Reference Guide and Verilog Directives.
        $vendorSetup = @'
foreach rtlcheck_constraint $rtlcheck_constraints {
    if {[string equal -nocase [file extension $rtlcheck_constraint] .lpf]} {
        lappend rtlcheck_lattice_create -lpf $rtlcheck_constraint
    }
}
prj_project new {*}$rtlcheck_lattice_create
prj_syn set synplify
foreach rtlcheck_source $rtlcheck_sources {
    prj_src add -impl impl1 $rtlcheck_source
}
foreach rtlcheck_constraint $rtlcheck_constraints {
    if {![string equal -nocase [file extension $rtlcheck_constraint] .lpf]} {
        prj_src add -impl impl1 $rtlcheck_constraint
    }
}
prj_impl option -impl impl1 top $rtlcheck_top
if {[llength $rtlcheck_include_dirs]} {
    prj_impl option -impl impl1 {include path} [list [join $rtlcheck_include_dirs {;}]]
}
if {[llength $rtlcheck_defines]} {
    prj_impl option -impl impl1 VERILOG_DIRECTIVES $rtlcheck_defines
}
prj_project save
'@
        $synthesize = @(
            'prj_run Synthesis -impl impl1'
            'rtlcheck_lattice_require_output {Diamond synthesis} {*.edi}'
        )
        $fit = @(
            'prj_run PAR -impl impl1'
            'rtlcheck_lattice_require_output {Diamond place and route} {*.ncd} {*_map.ncd}'
        )
        $close = 'prj_project close'
    }
    elseif ($Project.Synthesis.engine -eq 'radiant') {
        # Lattice Radiant Design Flow Using Tcl, FPGA-AN-02113.
        $vendorSetup = @'
if {$rtlcheck_performance ne {}} {
    lappend rtlcheck_lattice_create -performance $rtlcheck_performance
}
prj_create {*}$rtlcheck_lattice_create -synthesis synplify
foreach rtlcheck_source $rtlcheck_sources {
    prj_add_source -impl impl1 $rtlcheck_source
}
foreach rtlcheck_constraint $rtlcheck_constraints {
    prj_add_source -impl impl1 $rtlcheck_constraint
}
prj_set_impl_opt -impl impl1 top $rtlcheck_top
if {[llength $rtlcheck_include_dirs]} {
    prj_set_impl_opt -impl impl1 {include path} [list [join $rtlcheck_include_dirs {;}]]
}
if {[llength $rtlcheck_defines]} {
    prj_set_impl_opt -impl impl1 VERILOG_DIRECTIVES $rtlcheck_defines
}
prj_save
'@
        $synthesize = @(
            'prj_run Synthesis -impl impl1'
            'rtlcheck_lattice_require_output {Radiant synthesis} {*_syn.udb}'
        )
        $fit = @(
            'prj_run PAR -impl impl1'
            'rtlcheck_lattice_require_output {Radiant place and route} {*_par.udb *_rte.udb}'
        )
        $close = 'prj_close'
    }
    else {
        throw "Unsupported Lattice synthesis engine: $($Project.Synthesis.engine)."
    }

    $steps = [ordered]@{
        setup = [string[]](($setup, $vendorSetup -join "`n") -split '\r?\n')
        synthesize = [string[]]$synthesize
    }
    if ($Project.Synthesis.implementation) {
        $steps.fit = [string[]]($fit + $close)
    }
    else {
        $steps.synthesize = [string[]]($synthesize + $close)
    }
    return $steps
}
