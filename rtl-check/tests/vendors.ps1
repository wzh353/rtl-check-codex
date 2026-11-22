#requires -Version 7.2

param([string]$GowinShell)

$ErrorActionPreference = 'Stop'
$tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'rtl-check.ps1'
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $temp "rtl-vendor-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory((Join-Path $root 'rtl source'))
$null = [IO.Directory]::CreateDirectory((Join-Path $root 'bin'))
$config = Join-Path $root 'rtlcheck.json'
$fixturePath = Join-Path $root 'fake-vendor.ps1'
$launcher = Join-Path $root $(if ($IsWindows) { 'bin/vendor & %name% !.cmd' } else { 'bin/vendor launcher.sh' })

[IO.File]::WriteAllText((Join-Path $root 'rtl source/pulse.sv'), @'
module pulse(input logic clk, output logic q);
    always_ff @(posedge clk) q <= 1'b1;
endmodule
'@)
[IO.File]::WriteAllText((Join-Path $root 'pulse_tb.sv'), @'
module pulse_tb;
    reg clk = 0;
    wire q;
    pulse dut (clk, q);
    initial begin
        #1 clk = 1;
        #1 if (q !== 1'b1) $fatal(1, "wrong pulse");
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule
'@)
[IO.File]::WriteAllText((Join-Path $root 'design.xdc'), 'create_clock -period 20 [get_ports clk]')
[IO.File]::WriteAllText($fixturePath, @'
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath 'pulse_tb.sv') { throw 'A testbench was copied into the hardware build.' }
if (!(Test-Path -LiteralPath 'rtl source/pulse.sv')) { throw 'The staged RTL input is missing.' }
if ($env:RTL_TEST_VENDOR_ENGINE -eq 'efinity') {
    if ($IsWindows -and $env:RTL_TEST_EFINITY_SETUP -ne 'ready') { throw 'Efinity setup did not run.' }
    if ($args[1] -ne '--flow' -or $args[2] -ne 'map') { throw "Bad Efinity invocation: $args" }
    $projectPath = [IO.Path]::GetFullPath($args[0], (Get-Location).Path)
    [xml]$project = [IO.File]::ReadAllText($projectPath)
    $file = $project.DocumentElement['efx:design_info']['efx:design_file'].GetAttribute('name')
    $staged = [IO.Path]::GetFullPath($file, [IO.Path]::GetDirectoryName($projectPath))
    if ($staged -ne [IO.Path]::GetFullPath('rtl source/pulse.sv', (Get-Location).Path)) {
        throw 'Efinity did not receive the staged RTL path.'
    }
    if ($env:RTL_TEST_VENDOR_FAULT -eq 'silent') { exit 0 }
    $out = $args[([array]::IndexOf($args, '--output_dir') + 1)]
    $null = [IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllText((Join-Path $out 'rtlcheck_efinity.map.rpt'), 'Mapped resources')
    [IO.File]::WriteAllText((Join-Path $out 'rtlcheck_efinity.map.v'), 'module pulse; endmodule')
    if ($env:RTL_TEST_VENDOR_FAULT -eq 'syntax') {
        [IO.File]::WriteAllText((Join-Path $out 'rtlcheck_efinity.map.out'), "ERROR: HDL syntax failure [$($staged):2]")
    }
    exit 0
}
$entry = switch ($env:RTL_TEST_VENDOR_ENGINE) {
    'vivado' {
        if ($args[0] -ne '-mode' -or $args[1] -ne 'batch' -or '-source' -notin $args) { throw "Bad Vivado invocation: $args" }
        $args[([array]::IndexOf($args, '-source') + 1)]
    }
    'libero' {
        if ($args[0] -notlike 'SCRIPT:*') { throw "Bad Libero invocation: $args" }
        $args[0].Substring(7)
    }
    default { $args[-1] }
}
$driver = [IO.File]::ReadAllText((Join-Path (Get-Location).Path $entry))
if ($driver -notmatch 'RTL_CHECK_VENDOR') { throw 'The staged Tcl driver is missing.' }
$stageFile = Join-Path ([IO.Path]::GetDirectoryName($entry)) 'synthesize.tcl'
$command = switch ($env:RTL_TEST_VENDOR_ENGINE) {
    'vivado' { 'synth_design' }
    'gowin' { 'run syn' }
    'libero' { 'rtlcheck_libero_run SYNTHESIZE' }
    default { 'prj_run Synthesis' }
}
if (-not ([IO.File]::ReadAllText((Join-Path (Get-Location).Path $stageFile))).Contains($command)) {
    throw "Expected $command in $stageFile."
}
if ($env:RTL_TEST_VENDOR_FAULT -eq 'silent') { exit 0 }
$statusPath = Join-Path ([IO.Path]::GetDirectoryName($entry)) 'stages.log'
function Write-Stage([string]$Status) { Add-Content -LiteralPath $statusPath -Value $Status -Encoding utf8 }
Write-Stage 'BEGIN setup'
if ($env:RTL_TEST_VENDOR_FAULT -eq 'part') {
    [Console]::Error.WriteLine('ERROR: configured device is unavailable')
    exit 1
}
Write-Stage 'OK setup'
Write-Stage 'BEGIN synthesize'
if ($env:RTL_TEST_VENDOR_FAULT -eq 'license') {
    [Console]::Error.WriteLine('ERROR: license checkout failed during synthesis')
    exit 1
}
if ($env:RTL_TEST_VENDOR_FAULT -eq 'syntax') {
    [Console]::Error.WriteLine("ERROR: [Synth 8-1] syntax failure [$((Get-Location).Path)/rtl source/pulse.sv:2]")
    exit 1
}
if ($env:RTL_TEST_VENDOR_FAULT -eq 'constraint') {
    [Console]::Error.WriteLine("ERROR: [Synth 8-1] invalid clock target [$((Get-Location).Path)/design.xdc:1]")
    exit 1
}
Write-Stage 'OK synthesize'
if ($driver -match '(?m)^rtlcheck_stage fit\b') {
    Write-Stage 'BEGIN fit'
    if ($env:RTL_TEST_VENDOR_FAULT -eq 'fit') {
        [Console]::Error.WriteLine('ERROR: [Place 30-1] design cannot be placed')
        exit 1
    }
    Write-Stage 'OK fit'
}
exit 0
'@)

$env:RTL_TEST_VENDOR_PWSH = [Environment]::ProcessPath
$env:RTL_TEST_VENDOR_PS1 = $fixturePath
if ($IsWindows) {
    [IO.File]::WriteAllText($launcher, "@echo off`r`n" + '"%RTL_TEST_VENDOR_PWSH%" -NoProfile -File "%RTL_TEST_VENDOR_PS1%" %*' + "`r`nexit /b %errorlevel%`r`n")
} else {
    [IO.File]::WriteAllText($launcher, "#!/bin/sh`n" + 'exec "$RTL_TEST_VENDOR_PWSH" -NoProfile -File "$RTL_TEST_VENDOR_PS1" "$@"' + "`n")
    chmod +x $launcher
}

$settings = @{
    top = 'pulse_tb'
    sources = @('rtl source/pulse.sv')
    testbenches = @('pulse_tb.sv')
    repairFiles = @('rtl source/pulse.sv')
    synthesis = @{
        engine = 'vivado'; top = 'pulse'; device = 'xc7a35tcpg236-1'; executable = $launcher
        constraintFiles = @('design.xdc'); implementation = $true
    }
}

function Invoke-VendorCheck([int]$ExpectedExit, [string]$Fault = '', [string]$Mode = 'check') {
    $env:RTL_TEST_VENDOR_ENGINE = $settings.synthesis.engine
    $env:RTL_TEST_VENDOR_FAULT = $Fault
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 8))
    $output = & ([Environment]::ProcessPath) -NoProfile -File $tool $Mode -Config $config -TimeoutSeconds 15 -Json
    if ($LASTEXITCODE -ne $ExpectedExit) { throw "Expected exit $ExpectedExit, got $LASTEXITCODE. $output" }
    return ($output -join "`n" | ConvertFrom-Json -AsHashtable)
}

try {
    $result = Invoke-VendorCheck 0
    if ($result.initial.stage -ne 'fit' -or $result.initial.simulate.exitCode -ne 0 -or
        $result.initial.synthesis.engine -ne 'vivado' -or $result.initial.fit.status -ne 'passed') {
        throw 'Expected simulation, Vivado synthesis and implementation to pass.'
    }
    Write-Host 'PASS Runs Vivado as a batch launcher and keeps testbenches out of the build'

    $result = Invoke-VendorCheck 1 'syntax'
    if ($result.initial.stage -ne 'synthesize' -or $result.initial.firstError.inputFile -ne 'rtl source/pulse.sv' -or
        $result.initial.firstError.line -ne 2 -or $result.initial.fit) {
        throw 'Expected the native syntax error and its input line before placement.'
    }
    Write-Host 'PASS Maps vendor syntax errors back to the staged RTL path'

    $result = Invoke-VendorCheck 2 'constraint'
    if ($result.initial.synthesis.reason -ne 'invalid_constraints' -or
        $result.initial.firstError.inputFile -ne 'design.xdc' -or $result.initial.firstError.line -ne 1) {
        throw 'A source-located XDC error must remain a tool configuration error.'
    }
    Write-Host 'PASS Distinguishes vendor constraint diagnostics from design errors'

    $result = Invoke-VendorCheck 1 'fit'
    if ($result.initial.stage -ne 'fit' -or $result.initial.synthesis.status -ne 'passed') {
        throw 'A design placement failure must retain the passed synthesis result.'
    }
    Write-Host 'PASS Separates implementation failures from synthesis'

    foreach ($fault in @('part', 'license', 'silent')) {
        $result = Invoke-VendorCheck 2 $fault 'repair'
        if ($result.initial.synthesis.status -ne 'error' -or $result.attempts.Count -ne 0) {
            throw "Vendor infrastructure failure '$fault' must stop before the model is invoked."
        }
    }
    Write-Host 'PASS Stops on tool failures and requires a completed synthesis stage'

    $before = (Invoke-VendorCheck 0).inputSha256
    [IO.File]::AppendAllText((Join-Path $root 'design.xdc'), "`n# updated clock file`n")
    $after = (Invoke-VendorCheck 0).inputSha256
    if ($before -eq $after) { throw 'Vendor constraints must be part of the protected input snapshot.' }
    Write-Host 'PASS Includes vendor constraints in the snapshot digest'

    $profiles = @(
        @{ engine = 'gowin'; device = 'GW1NR-LV9QN88PC6/I5'; deviceVariant = 'GW1NR-9C' }
        @{ engine = 'radiant'; device = 'LIFCL-40-8BG400C'; performance = '8_High-Performance_1.0V' }
        @{ engine = 'diamond'; device = 'LCMXO2-1200HC-4TG100C' }
        @{ engine = 'libero'; family = 'PolarFire'; device = 'MPF100T'; package = 'FCVG484'; speed = '-1' }
    )
    foreach ($profile in $profiles) {
        $settings.synthesis = $profile + @{ top = 'pulse'; executable = $launcher; implementation = $true }
        $result = Invoke-VendorCheck 0
        if ($result.initial.synthesis.engine -ne $profile.engine -or $result.initial.fit.status -ne 'passed') {
            throw "Expected both native stages for $($profile.engine)."
        }
    }
    Write-Host 'PASS Routes Gowin, Diamond, Radiant and Libero through the same hardware stages'

    if ($IsWindows) {
        [IO.File]::WriteAllLines((Join-Path $root 'bin/setup.bat'), @(
            '@echo off'
            'set "RTL_TEST_EFINITY_SETUP=ready"'
            'cd /d "%TEMP%"'
            'exit /b 0'
        ))
    }
    $settings['synthesis'] = @{
        engine = 'efinity'; family = 'Titanium'; device = 'Ti60F225'; timingModel = 'C4'; top = 'pulse'; executable = $launcher
    }
    $result = Invoke-VendorCheck 0
    if ($result.initial.stage -ne 'synthesize' -or $result.initial.synthesis.engine -ne 'efinity' -or
        -not [IO.File]::Exists($result.initial.synthesis.reportPath)) {
        throw 'Efinity must provide a mapped netlist and real report path.'
    }
    $result = Invoke-VendorCheck 2 'silent'
    if ($result.initial.synthesis.reason -ne 'inconclusive_result') { throw 'Expected missing map artifacts to be a tool error.' }
    $result = Invoke-VendorCheck 1 'syntax'
    if ($result.initial.firstError.inputFile -ne 'rtl source/pulse.sv' -or
        -not [IO.File]::Exists($result.initial.firstError.log)) {
        throw 'Expected a durable source diagnostic from the Efinity map log.'
    }
    Write-Host 'PASS Requires Efinity mapping artifacts and applies the native launch environment'

    if ($GowinShell) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $root 'first include'))
        $null = [IO.Directory]::CreateDirectory((Join-Path $root 'second include'))
        [IO.File]::WriteAllText((Join-Path $root 'first include/value.svh'), '`define VALUE 1''b1')
        [IO.File]::WriteAllText((Join-Path $root 'second include/mask.svh'), '`define MASK 1''b1')
        $settings.includeDirs = @('first include', 'second include')
        $settings.supportFiles = @('first include/value.svh', 'second include/mask.svh')
        [IO.File]::WriteAllText((Join-Path $root 'pulse.sdc'), 'create_clock -name clk -period 20 [get_ports {clk}]')
        $source = Join-Path $root 'rtl source/pulse.sv'
        $validRtl = @'
`include "value.svh"
`include "mask.svh"
module pulse(input logic clk, output logic q);
    always_ff @(posedge clk) q <= `VALUE & `MASK;
endmodule
'@
        [IO.File]::WriteAllText($source, $validRtl)
        $settings['synthesis'] = @{
            engine = 'gowin'; device = 'GW1NR-LV9QN88PC6/I5'; deviceVariant = 'GW1NR-9C'
            top = 'pulse'; executable = $GowinShell; implementation = $true; constraintFiles = @('pulse.sdc')
        }
        $result = Invoke-VendorCheck 0
        if ($result.initial.fit.status -ne 'passed' -or -not [IO.File]::Exists($result.initial.fit.reportPath)) {
            throw 'Native Gowin failed to produce its place and route report.'
        }
        Write-Host 'PASS Runs native Gowin synthesis and place and route'

        $settings.defines = @('SIMULATION=1')
        [IO.File]::WriteAllText($source, $validRtl.Replace('    always_ff @(posedge clk) q <= `VALUE & `MASK;', @'
`ifdef SIMULATION
    always_ff @(posedge clk) q <= `VALUE & `MASK;
`else
    always_ff @(posedge clk) q <= ;
`endif
'@))
        $result = Invoke-VendorCheck 1
        if ($result.initial.stage -ne 'synthesize' -or $result.initial.simulate.exitCode -ne 0 -or
            $result.initial.firstError.inputFile -ne 'rtl source/pulse.sv' -or $result.initial.firstError.line -ne 7) {
            $evidence = $result.initial.firstError | ConvertTo-Json -Depth 4 -Compress
            throw "Expected native Gowin to identify the hardware-only RTL error. $evidence"
        }
        Write-Host 'PASS Separates Icarus and Gowin macros and maps native synthesis errors'
        [IO.File]::WriteAllText($source, $validRtl)

        $settings.synthesis.device = 'PART_DOES_NOT_EXIST'
        $result = Invoke-VendorCheck 2 '' 'repair'
        if ($result.initial.synthesis.reason -ne 'setup_failed' -or $result.attempts.Count -ne 0) {
            throw 'Native Gowin target errors must stop before repair.'
        }
        Write-Host 'PASS Keeps a native Gowin device setup error out of the repair loop'
    }
}
finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $temp.TrimEnd([IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^rtl-vendor-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
$tests = if ($GowinShell) { 11 } else { 8 }
Write-Host "$tests vendor integration tests passed."
