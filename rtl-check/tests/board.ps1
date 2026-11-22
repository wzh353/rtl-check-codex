#requires -Version 7.2

param([string]$QuartusMap)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'lib/Check.ps1')
. (Join-Path $toolRoot 'lib/Repair.ps1')
if (-not $QuartusMap) {
    try { $QuartusMap = Find-RtlQuartusMap '' }
    catch {
        Write-Host 'SKIP Quartus board integration. Provide -QuartusMap or install Quartus.'
        exit 0
    }
}
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-board-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory((Join-Path $root 'board inputs'))
$cli = Join-Path $toolRoot 'rtl-check.ps1'
$config = Join-Path $root 'rtlcheck.json'
$source = Join-Path $root 'counter.sv'
$boardName = 'board inputs/reference.qsf'
$boardFile = Join-Path $root $boardName
$counter = [IO.File]::ReadAllText((Join-Path $toolRoot 'examples/counter/counter.sv')).Replace("8'd2", "8'd1")
[IO.File]::WriteAllText($source, $counter)
[IO.File]::WriteAllText((Join-Path $root 'model.sv'), 'module simulation_only; initial $display("simulation model"); endmodule')
$settings = @{
    top = 'counter'
    sources = @('counter.sv')
    simulationSources = @('model.sv')
    synthesis = @{
        executable = $QuartusMap
        top = 'counter'
        family = 'Cyclone IV E'
        device = 'EP4CE6E22C8'
        board = @{ qsf = $boardName }
    }
}
$board = @'
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6E22C8
set_global_assignment -name VERILOG_FILE intentionally_not_a_build_input.v
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"
set_location_assignment PIN_23 -to clk
set_location_assignment PIN_65 -to count[7]
set_location_assignment PIN_66 -to count[4]
set_location_assignment PIN_67 -to en
set_location_assignment PIN_68 -to count[1]
set_location_assignment PIN_70 -to count[6]
set_location_assignment PIN_71 -to count[0]
set_location_assignment PIN_75 -to rst_n
set_location_assignment PIN_76 -to count[2]
set_location_assignment PIN_77 -to count[5]
set_location_assignment PIN_80 -to count[3]
set_instance_assignment -name IO_STANDARD "3.3-V LVCMOS" -to {count[0]}
'@
[IO.File]::WriteAllText((Join-Path $root 'clocks.sdc'), @'
create_clock -name clk -period 20.000 [get_ports {clk}]
set_input_delay -clock clk -max 2.000 [get_ports {rst_n en}]
set_input_delay -clock clk -min 2.000 [get_ports {rst_n en}]
set_output_delay -clock clk -max 2.000 [get_ports {count[*]}]
set_output_delay -clock clk -min -0.100 [get_ports {count[*]}]
derive_clock_uncertainty
'@)

function Invoke-BoardTest([string]$Name, [string]$Qsf, [int]$Exit, [scriptblock]$Verify) {
    [IO.File]::WriteAllText($boardFile, $Qsf)
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 7))
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $cli check -Config $config -TimeoutSeconds 45 -Json
    $actual = $LASTEXITCODE
    $result = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($actual -ne $Exit) { throw "$Name returned $actual instead of $Exit. $($result.error) $($result.initial.diagnostic)" }
    & $Verify $result
    Write-Host "PASS $Name"
    return $result
}

try {
    $full = Invoke-BoardTest 'Matches every physical port and per-pin I/O override after fitting' $board 0 {
        param($result)
        $fit = $result.initial.fit
        $qsf = [IO.File]::ReadAllText($result.initial.synthesis.qsfPath)
        if ($result.initial.stage -ne 'fit' -or $fit.board.portCount -ne 11 -or $fit.board.matchedPinCount -ne 11 -or
            $fit.board.pins.clk.pin -ne 'PIN_23' -or $fit.board.pins.clk.assignedBy -ne 'User' -or
            $fit.board.pins['count[0]'].ioStandard -ne '3.3-V LVCMOS' -or $fit.board.pins['count[1]'].ioStandard -ne '3.3-V LVTTL' -or
            $result.initial.timing -or -not [IO.File]::Exists($fit.pinReportPath) -or
            $qsf -match 'intentionally_not_a_build_input|model.sv' -or $result.initial.compile.arguments -cnotcontains './model.sv' -or
            'VERILOG_FILE' -notin $fit.board.unusedQsfSettings) {
            throw 'Expected a native pin report with explicit locations and I/O standards, using the configured RTL only for synthesis.'
        }
        if (-not [IO.File]::Exists((Join-Path $result.runDirectory "baseline/$boardName"))) { throw 'Expected a fixed QSF snapshot.' }
    }

    $project = Read-RtlProject $config
    $boardSettings = $project.Synthesis.board
    $boardSettings.profile = Read-RtlBoardProfile $boardFile $project.Synthesis
    $boardSettings.profile.standards['count[0]'] = '2.5 V'
    $fitterCheck = @{
        status = 'passed'
        process = $full.initial.fit.process
        resources = $full.initial.fit.resources
        reportPath = $full.initial.fit.reportPath
    }
    Add-RtlBoardEvidence $fitterCheck $boardSettings
    $io = $fitterCheck.board.mismatches | Where-Object { $_.kind -eq 'io_standard_mismatch' }
    if ($fitterCheck.status -ne 'failed' -or $io.port -ne 'count[0]' -or $io.actual -ne '3.3-V LVCMOS') {
        throw 'A matched physical location with the wrong I/O standard must still fail.'
    }
    Write-Host 'PASS Detects an I/O standard mismatch despite the correct package pin'

    $settings.synthesis.timing = @{ sdcFiles = @('clocks.sdc'); clocks = @{ clk = 20 } }
    $null = Invoke-BoardTest 'Runs TimeQuest only after the board check passes' $board 0 {
        param($result)
        if ($result.initial.stage -ne 'timing' -or $result.initial.fit.board.status -ne 'passed' -or
            $result.initial.timing.constraintsComplete -ne $true -or $result.initial.timing.worstSetupSlackNs -le 0) {
            throw 'Expected the constrained timing gate to use the same fitted board design.'
        }
    }

    $badPort = $board.Replace('PIN_67 -to en', 'PIN_67 -to missing_enable')
    $null = Invoke-BoardTest 'Rejects an ignored location assignment despite successful Fitter exit' $badPort 1 {
        param($result)
        if ($result.initial.stage -ne 'fit' -or $result.initial.timing -or $result.initial.fit.process.exitCode -ne 0 -or
            $result.initial.fit.reason -ne 'board_mismatch' -or 'missing_enable' -cnotin $result.initial.fit.board.mismatches.port) {
            throw 'A missing physical port must block timing and preserve its actionable identity.'
        }
    }

    $partial = $board.Replace('set_location_assignment PIN_65 -to count[7]', '')
    $null = Invoke-BoardTest 'Rejects a port left for automatic pin placement by default' $partial 1 {
        param($result)
        $missing = $result.initial.fit.board.mismatches | Where-Object { $_.kind -eq 'unpinned_port' }
        if ($result.initial.fit.process.exitCode -ne 0 -or $missing.port -cnotcontains 'count[7]') {
            throw 'An automatically chosen pin cannot satisfy the full board contract.'
        }
    }

    $settings.synthesis.board.requireAllPins = $false
    $null = Invoke-BoardTest 'Reports partial coverage when omitted pins are explicitly allowed' $partial 0 {
        param($result)
        $checked = $result.initial.fit.board
        if ($checked.complete -ne $false -or $checked.matchedPinCount -ne 10 -or $checked.portCount -ne 11) {
            throw 'Expected the report to retain the actual bound and unbound port counts.'
        }
    }
    $settings.synthesis.board.requireAllPins = $true

    $modelPath = Join-Path $root 'model.sv'
    [IO.File]::WriteAllText($modelPath, @'
`ifndef SIMULATION_ONLY_MODEL
`define SIMULATION_ONLY_MODEL
module simulation_only;
endmodule
`endif
'@)
    [IO.File]::WriteAllText($source, '`include "model.sv"' + "`n" + $counter)
    $settings.supportFiles = @('model.sv')
    $null = Invoke-BoardTest 'Keeps simulation models out of the Quartus working directory' $board 1 {
        param($result)
        if ($result.initial.stage -ne 'synthesize' -or $result.initial.compile.exitCode -ne 0 -or
            $result.initial.diagnostic -notmatch 'model.sv' -or
            [IO.File]::Exists((Join-Path $result.initial.synthesis.process.workingDirectory 'model.sv'))) {
            throw 'A model supplied only for simulation must never satisfy a hardware include.'
        }
    }
    $null = $settings.Remove('supportFiles')
    [IO.File]::WriteAllText($source, $counter)

    [IO.File]::WriteAllText((Join-Path $root 'extra_tb.sv'), @'
`ifndef EXTRA_CASE_BENCH
`define EXTRA_CASE_BENCH
module extra_tb;
    initial begin
        $display("EXTRA_CASE_PASS");
        $finish;
    end
endmodule
`endif
'@)
    [IO.File]::WriteAllText($source, '`include "extra_tb.sv"' + "`n" + $counter)
    $settings.supportFiles = @('extra_tb.sv')
    $settings.regressions = @(@{
        id = 'extra'; top = 'extra_tb'; testbenches = @('extra_tb.sv'); passMarker = 'EXTRA_CASE_PASS'
    })
    $null = Invoke-BoardTest 'Keeps additional regression testbenches out of Quartus' $board 1 {
        param($result)
        if ($result.initial.stage -ne 'synthesize' -or $result.initial.regressionsPassed -ne 1 -or
            $result.initial.diagnostic -notmatch 'extra_tb.sv' -or
            [IO.File]::Exists((Join-Path $result.initial.synthesis.process.workingDirectory 'extra_tb.sv'))) {
            throw 'A testbench must stay out of Quartus even when it also appears in shared support files.'
        }
    }
    $null = $settings.Remove('regressions')
    $null = $settings.Remove('supportFiles')
    [IO.File]::WriteAllText($source, $counter)

    $null = Invoke-BoardTest 'Rejects a board QSF for another device before invoking Quartus' ($board.Replace('EP4CE6E22C8', 'EP4CE15F23C8')) 2 {
        param($result)
        if ($result.initial -or $result.error -notmatch 'DEVICE') { throw 'Expected a board part mismatch in configuration.' }
    }
    $conditional = $board.Replace('set_location_assignment PIN_23 -to clk', "if {0} {`nset_location_assignment PIN_23 -to clk`n}")
    $null = Invoke-BoardTest 'Rejects conditional Tcl around otherwise valid assignments' $conditional 2 {
        param($result)
        if ($result.initial -or $result.error -notmatch 'standalone QSF assignment') {
            throw 'A conditional assignment must never be reinterpreted as unconditional.'
        }
    }
    $baseline = Join-Path $full.runDirectory 'baseline'
    [IO.File]::Copy((Join-Path $baseline 'rtlcheck.json'), $config, $true)
    [IO.File]::WriteAllText($boardFile, $board + "`n# changed after baseline")
    $project = Read-RtlProject $config
    $candidate = @{ 'counter.sv' = [Text.Encoding]::UTF8.GetBytes($counter + "`n// candidate") }
    $errorText = try { Publish-RtlRepair $project $baseline $candidate } catch { $_.Exception.Message }
    if ($errorText -notmatch 'changed since' -or $errorText -notmatch [regex]::Escape($boardName) -or
        [IO.File]::ReadAllText($source) -cne $counter) {
        throw "A changed board file must stop publication and preserve original RTL. $errorText"
    }
    Write-Host 'PASS Refuses to publish after the board QSF changed'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-board-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '11 board tests passed.'
