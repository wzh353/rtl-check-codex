#requires -Version 7.2

param([string]$ModelSimBin)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $toolRoot 'rtl-check.ps1'
if (-not $ModelSimBin) {
    $command = Get-Command vsim -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        Write-Host 'SKIP ModelSim integration. Provide -ModelSimBin or put vsim on PATH.'
        exit 0
    }
    $ModelSimBin = [IO.Path]::GetDirectoryName($command.Source)
}
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-modelsim-tests-$([guid]::NewGuid().ToString('N'))"
$project = Join-Path $root 'project with spaces'
$null = [IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath (Join-Path $toolRoot 'examples/counter') -Destination $project -Recurse
$manifest = Join-Path $project 'rtlcheck.json'
$outDir = Join-Path $root 'runs with spaces'
$bench = Join-Path $project 'counter_tb.sv'
$originalBench = [IO.File]::ReadAllText($bench)
$original = [IO.File]::ReadAllText((Join-Path $project 'counter.sv'))
$sourceName = 'RTL source/counter.sv'
$source = Join-Path $project $sourceName
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($source))
$include = Join-Path $project 'header folder/constants.svh'
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($include))
[IO.File]::WriteAllText($include, '`define RTL_STEP `INCREMENT_TERM' + [Environment]::NewLine)
$bad = '`include "constants.svh"' + [Environment]::NewLine + $original.Replace("count + 8'd2", 'count + `RTL_STEP')
$good = $bad.Replace('count + `RTL_STEP', "count + 8'd1")
[IO.File]::WriteAllText($source, $bad)
$config = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
$config.sources = @($sourceName)
$config.repairFiles = @($sourceName)
$config.includeDirs = @('header folder')
$config.supportFiles = @('header folder/constants.svh')
$config.defines = @("INCREMENT_TERM=(8'd1 + 8'd1)")
$config.simulator = @{ engine = 'modelsim'; binDirectory = $ModelSimBin }
$config.waveform = @{ signals = @('counter_tb.clk', 'counter_tb.count'); maxEvents = 6 }
$validation = $config.validation
$script:tests = 0

function Invoke-ModelSimTest([string]$Name, [int]$ExitCode, [scriptblock]$Verify, [int]$Timeout = 20,
                             [string]$OutputDirectory = $outDir) {
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject $config -Depth 8))
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $cli check -Config $manifest -OutDir $OutputDirectory -TimeoutSeconds $Timeout -Json
    $actual = $LASTEXITCODE
    $result = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($actual -ne $ExitCode) {
        throw "$Name returned $actual instead of $ExitCode. $($result.error) $($result.initial.diagnostic) $($result.validation.diagnostic)"
    }
    & $Verify $result
    $script:tests++
    Write-Host "PASS $Name"
}

try {
    Invoke-ModelSimTest 'Reports the failing counter with ModelSim time, source, and VCD values' 1 {
        param($result)
        $errorInfo = $result.initial.firstError
        $wave = $result.initial.waveform
        if ($result.initial.engine -ne 'modelsim' -or $result.initial.stage -ne 'simulate' -or
            $errorInfo.message -notmatch 'expected=1 actual=2' -or $errorInfo.inputFile -ne 'counter_tb.sv' -or
            $errorInfo.simulationTime -ne 36 -or $errorInfo.simulationTimeUnit -ne 'ns' -or
            $wave.status -ne 'captured' -or $wave.trace.values['counter_tb.count'] -ne '00000010' -or
            $wave.trace.events.Count -gt 6 -or -not [IO.File]::Exists($wave.path)) {
            throw 'Expected the actual ModelSim assertion and bounded waveform at the reported time.'
        }
    }

    if ($IsWindows) {
        $longOutput = Join-Path $outDir ('long-' + ('x' * 90))
        Invoke-ModelSimTest 'Uses a short native path and preserves durable VCD and compiler logs' 1 {
            param($result)
            $compile = $result.initial.compile
            $wave = $result.initial.waveform
            if ($result.initial.stage -ne 'simulate' -or $result.initial.firstError.inputFile -ne 'counter_tb.sv' -or
                -not $compile.executionDirectory -or $compile.executionDirectory.Length -ge $compile.workingDirectory.Length -or
                [IO.Directory]::Exists($compile.executionDirectory) -or -not [IO.Directory]::Exists($compile.workingDirectory) -or
                -not [IO.File]::Exists($compile.stdout) -or $wave.status -ne 'captured' -or
                -not [IO.File]::Exists($wave.path) -or [IO.Directory]::Exists($wave.compile.executionDirectory)) {
                throw 'The temporary path must apply to compilation and waveform replay, with durable artifacts at the configured location.'
            }
        } -OutputDirectory $longOutput
    }

    $config.waveform.signals = @('counter_tb.clk')
    [IO.File]::WriteAllText($bench, @'
`timescale 1ns/1ps
module counter_tb;
    reg clk = 0;
    integer primary_library_log;
    initial begin
        primary_library_log = $fopen("../../vlib.stdout.log", "r");
        #1;
        if (primary_library_log == 0)
            $fatal(1, "same message at the same time");
        else
            $fatal(1, "same message at the same time");
    end
endmodule
'@)
    Invoke-ModelSimTest 'Discards a replay with the same assertion text at another line' 1 {
        param($result)
        $originalError = $result.initial.firstError
        $wave = $result.initial.waveform
        if ($wave.status -ne 'different_failure' -or $wave.trace -or
            $wave.replayError.scope -cne $originalError.scope -or $wave.replayError.textHash -cne $originalError.textHash -or
            $wave.replayError.simulationTime -ne $originalError.simulationTime -or $wave.replayError.line -eq $originalError.line) {
            throw 'A different assertion line must invalidate an otherwise matching replay.'
        }
    }

    [IO.File]::WriteAllText($source, $good)
    $sva = @'
    assert property (@(posedge clk) rst_n |-> !$isunknown(count));
endmodule
'@
    [IO.File]::WriteAllText($bench, $originalBench.Replace('endmodule', $sva))
    Invoke-ModelSimTest 'Runs a concurrent SystemVerilog assertion and inherits the simulator in validation' 0 {
        param($result)
        if ($result.initial.engine -ne 'modelsim' -or $result.initial.waveform -or
            $result.validation.engine -ne 'modelsim' -or $result.validation.status -ne 'passed') {
            throw 'Expected ModelSim to handle both configured test suites.'
        }
    }

    $validation.simulator = @{ engine = 'icarus' }
    Invoke-ModelSimTest 'Uses an explicitly selected independent simulator' 0 {
        param($result)
        if ($result.initial.engine -ne 'modelsim' -or $result.validation.engine -ne 'icarus' -or
            $result.validation.status -ne 'passed') {
            throw 'The validation simulator override did not reach the independent suite.'
        }
    }
    $null = $config.Remove('validation')
    $null = $config.Remove('waveform')

    [IO.File]::WriteAllText($source, "module counter( ;`n")
    Invoke-ModelSimTest 'Maps a vlog syntax error to the staged RTL filename and line' 1 {
        param($result)
        if ($result.initial.stage -ne 'compile' -or $result.initial.firstError.inputFile -cne $sourceName -or
            $result.initial.firstError.line -ne 1 -or $result.initial.simulate) {
            throw 'Expected a useful location for the first real compiler error.'
        }
    }
    [IO.File]::WriteAllText($source, $good)

    [IO.File]::WriteAllText($bench, 'module counter_tb; initial $finish; endmodule')
    Invoke-ModelSimTest 'Rejects early finish with a successful native exit code' 1 {
        param($result)
        if ($result.initial.simulate.exitCode -ne 0 -or $result.initial.diagnostic -notmatch 'without the success line') {
            throw 'A stopped simulator without the complete success marker cannot pass.'
        }
    }

    [IO.File]::WriteAllText($bench, 'module counter_tb; initial begin $display("RTL_CHECK_PASS"); $error("late assertion"); $finish; end endmodule')
    Invoke-ModelSimTest 'Rejects a late assertion even when the testbench already printed its success marker' 1 {
        param($result)
        if ($result.initial.stage -ne 'simulate' -or $result.initial.firstError.message -ne 'late assertion') {
            throw 'The assertion diagnostic must take precedence over the success marker.'
        }
    }

    [IO.File]::WriteAllText($bench, 'module counter_tb; initial begin $display("RTL_CHECK_PASS"); $stop; end endmodule')
    Invoke-ModelSimTest 'Rejects an explicit simulation stop after the success marker' 1 {
        param($result)
        if ($result.initial.stage -ne 'simulate' -or $result.initial.diagnostic -notmatch '\$stop') {
            throw 'An explicit simulation stop must prevent a pass.'
        }
    }

    [IO.File]::WriteAllText($bench, @'
module counter_tb;
    integer cycles = 0;
    always #1 begin
        cycles = cycles + 1;
        if (cycles % 65536 == 0) $display("still running, cycles=%0d", cycles);
    end
    initial $display("RTL_CHECK_PASS");
endmodule
'@)
    Invoke-ModelSimTest 'Bounds a nonterminating ModelSim testbench with a success marker' 1 {
        param($result)
        if ($result.initial.stage -ne 'simulate' -or $result.initial.simulate.timedOut -ne $true) {
            throw 'An infinite event queue must terminate at the configured wall clock timeout.'
        }
    } 6

    $config.top = 'counter'
    $null = $config.Remove('testbenches')
    Invoke-ModelSimTest 'Elaborates the declared top for a compile-only check' 0 {
        param($result)
        if ($result.initial.stage -ne 'compile' -or $result.initial.elaborate.exitCode -ne 0 -or $result.initial.simulate) {
            throw 'Compile-only ModelSim checks should elaborate without advancing simulation.'
        }
    }
    $config.top = 'missing_top'
    Invoke-ModelSimTest 'Rejects a missing elaboration top even if vlog succeeded' 1 {
        param($result)
        if ($result.initial.stage -ne 'compile' -or $result.initial.compile.exitCode -ne 0 -or
            $result.initial.firstError.message -notmatch 'missing_top') {
            throw 'A successful compilation cannot mask a missing design hierarchy.'
        }
    }
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-modelsim-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host "$script:tests ModelSim tests passed."
