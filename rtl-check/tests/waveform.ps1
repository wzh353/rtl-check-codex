#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $toolRoot 'rtl-check.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-waveform-tests-$([guid]::NewGuid().ToString('N'))"
$project = Join-Path $root '计数器 waveform'
$null = [IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath (Join-Path $toolRoot 'examples/counter') -Destination $project -Recurse
$config = Join-Path $project 'rtlcheck.json'
$source = Join-Path $project 'counter.sv'
$testbench = Join-Path $project 'counter_tb.sv'
$broken = [IO.File]::ReadAllText($source)
$bench = [IO.File]::ReadAllText($testbench)
$settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable

function Invoke-WaveCheck([int]$ExpectedExit) {
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 6))
    $output = & ([Environment]::ProcessPath) -NoProfile -File $tool check -Config $config -Json
    if ($LASTEXITCODE -ne $ExpectedExit) { throw "Unexpected check exit $LASTEXITCODE. $output" }
    return ($output -join "`n" | ConvertFrom-Json -AsHashtable)
}

try {
    $signals = @('counter_tb.clk', 'counter_tb.rst_n', 'counter_tb.en', 'counter_tb.dut.count')
    $settings.waveform = @{ signals = $signals; maxEvents = 4 }
    $failed = Invoke-WaveCheck 1
    $wave = $failed.initial.waveform
    if ($failed.initial.firstError.simulationTime -ne 36000 -or $wave.status -ne 'captured' -or
        $wave.trace.timescale -ne '1ps' -or $wave.trace.values['counter_tb.dut.count'] -ne '00000010' -or
        $wave.trace.failureTick -ne 36000 -or $wave.trace.events.Count -ne 4 -or
        $wave.trace.events[-1].tick -ne 35000 -or -not [IO.File]::Exists($wave.path) -or
        [IO.File]::ReadAllText($source) -cne $broken -or [IO.File]::ReadAllText($testbench) -cne $bench) {
        throw 'Expected the reproduced failing counter and its last four signal changes.'
    }
    Write-Host 'PASS Captures a bounded Icarus waveform and its assertion time'

    $settings.waveform.signals = @('counter_tb.dut.nonexistent')
    $failed = Invoke-WaveCheck 1
    if ($failed.initial.waveform.status -ne 'compile_failed' -or $failed.initial.firstError.message -notmatch 'expected=1 actual=2') {
        throw 'A waveform setup failure must preserve the primary result.'
    }
    Write-Host 'PASS Keeps capture errors separate from the RTL verdict'

    . (Join-Path $toolRoot 'lib/Check.ps1')
    $marker = Join-Path $root 'cancel-waveform'
    $previousMarker = $env:RTL_CHECK_CANCEL_FILE
    $cancelled = $false
    try {
        $env:RTL_CHECK_CANCEL_FILE = $marker
        [IO.File]::WriteAllText($marker, '')
        $fixture = Read-RtlProject $config
        $null = Invoke-RtlFailureWaveform $fixture $failed.initial (Join-Path $failed.runDirectory 'baseline') $null $root '' '' 5
    }
    catch [OperationCanceledException] { $cancelled = $true }
    finally {
        $env:RTL_CHECK_CANCEL_FILE = $previousMarker
        [IO.File]::Delete($marker)
    }
    if (-not $cancelled) { throw 'A cancelled waveform replay must propagate cancellation.' }
    Write-Host 'PASS Propagates cancellation through waveform replay'

    [IO.File]::WriteAllText($source, $broken.Replace("count + 8'd2", "count + 8'd1"))
    $passing = Invoke-WaveCheck 0
    if ($passing.initial.waveform -or $passing.validation.status -ne 'passed') {
        throw 'A passing check should avoid a waveform replay.'
    }
    Write-Host 'PASS Skips waveform compilation and replay for passing simulations'

    [IO.File]::WriteAllText($source, $broken)
    $settings.waveform.signals = $signals
    $different = $bench.Replace('    initial begin', @'
    integer probe_file;
    initial begin
        probe_file = $fopen("../probe.sv", "r");
        if (probe_file != 0)
            #1 $fatal(1, "a different failure during replay");
'@)
    [IO.File]::WriteAllText($testbench, $different)
    $mismatch = Invoke-WaveCheck 1
    if ($mismatch.initial.waveform.status -ne 'different_failure' -or $mismatch.initial.waveform.trace -or
        $mismatch.initial.firstError.message -notmatch 'expected=1 actual=2') {
        throw 'A replay with a different assertion must be excluded from repair evidence.'
    }
    Write-Host 'PASS Discards waveform evidence when the replay failure differs'

    $settings.waveform.signals = @('counter_tb.clk')
    [IO.File]::WriteAllText($testbench, @'
`timescale 1ns/1ps
module repeated_assertion #(parameter REPLAY_ONLY = 0);
    integer probe_file;
    initial begin
        probe_file = $fopen("../probe.sv", "r");
        #1;
        if ((probe_file != 0) == REPLAY_ONLY)
            $fatal(1, "identical message at identical tick");
    end
endmodule
module counter_tb;
    reg clk = 0;
    repeated_assertion #(0) primary_instance();
    repeated_assertion #(1) replay_instance();
endmodule
'@)
    $newScope = Invoke-WaveCheck 1
    if ($newScope.initial.waveform.status -ne 'different_failure' -or
        $newScope.initial.firstError.scope -ne 'counter_tb.primary_instance' -or
        $newScope.initial.waveform.replayError.scope -ne 'counter_tb.replay_instance') {
        throw 'A matching message and tick from another module instance are a different failure.'
    }
    Write-Host 'PASS Distinguishes identical failures from different instances'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-waveform-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '6 waveform tests passed.'
