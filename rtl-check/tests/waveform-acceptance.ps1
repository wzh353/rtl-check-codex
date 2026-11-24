#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $toolRoot 'rtl-check.ps1'
. (Join-Path $toolRoot 'lib/Check.ps1')
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$root = Join-Path $temp "rtl-acceptance-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$fixture = Join-Path $toolRoot 'examples/evaluation/counter'
foreach ($name in @('counter.sv', 'counter_tb.sv', 'counter_validation_tb.sv', 'spec.txt', 'counter_wave_observer.sv', 'waveform-acceptance.json')) {
    Copy-Item -LiteralPath (Join-Path $fixture $name) -Destination $root
}
$config = Join-Path $root 'waveform-acceptance.json'
$settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
$observer = Join-Path $root 'counter_wave_observer.sv'
$holdout = Join-Path $root 'counter_validation_tb.sv'
$observerBytes = [IO.File]::ReadAllBytes($observer)
$holdoutBytes = [IO.File]::ReadAllBytes($holdout)
$officialPaths = @('counter.sv', 'counter_tb.sv', 'counter_validation_tb.sv')
$originalInputs = Get-RtlInputDigest $root $officialPaths

function Invoke-AcceptanceCheck([int]$ExpectedExit) {
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 10))
    $output = & ([Environment]::ProcessPath) -NoProfile -File $cli check -Config $config -TimeoutSeconds 20 -Json
    $actualExit = $LASTEXITCODE
    $report = $output -join [Environment]::NewLine | ConvertFrom-Json -AsHashtable
    if ($actualExit -ne $ExpectedExit) { throw "Expected exit $ExpectedExit, got $actualExit. $($report.error)" }
    return $report
}

try {
    $result = Invoke-AcceptanceCheck 0
    $wave = $result.waveformAcceptance
    if ($wave.status -ne 'ready' -or $result.validation.status -ne 'passed' -or
        $wave.case -ne 'primary' -or $wave.sampleCount -ne 261 -or $wave.timescale -ne '1ps' -or $wave.timeUnit -ne 'ns' -or
        $wave.randomSeeds.status -ne 'not_used' -or $wave.rtlSha256 -ne (Get-RtlInputDigest $root @('counter.sv')) -or
        $wave.testInputSha256 -notmatch '^[A-F0-9]{64}$' -or $wave.openCommand -notmatch 'gtkwave') {
        throw 'Expected a successful export bound to the accepted original counter and public test.'
    }
    $table = [IO.File]::ReadAllText($wave.stimulusPath)
    if ($table -notmatch '(?m)^\| Increment \| 30 ns \| 36 ns \| rst_n=1, en=1 \| count=1 \| count=1 \| counter_tb\.sv:22 \|\r?$' -or
        $table -notmatch '(?m)^\| Wrap 255 to 0 \| 2590 ns \| 2596 ns \| rst_n=1, en=1 \| count=0 \| count=0 \| counter_tb\.sv:22 \|\r?$') {
        throw 'The drive and assertion times in the counter table are incorrect.'
    }
    if (-not [IO.File]::Exists($wave.vcdPath) -or
        [IO.File]::ReadAllText($wave.gtkwPath) -notmatch '(?m)^counter_tb\.dut\.count\[7:0\]\r?$' -or
        (Get-RtlInputDigest $root $officialPaths) -ne $originalInputs) {
        throw 'Expected a GTKWave trace list and the unchanged official project inputs.'
    }
    Write-Host 'PASS Exports the native counter stimuli at 36 ns and 2596 ns from the accepted snapshot'

    [IO.File]::WriteAllText($holdout, 'module counter_validation_tb; initial $fatal(1, "holdout failed"); endmodule')
    $result = Invoke-AcceptanceCheck 1
    [IO.File]::WriteAllBytes($holdout, $holdoutBytes)
    if ($result.waveformAcceptance.status -ne 'not_run' -or $result.waveformAcceptance.vcdPath) {
        throw 'The export must wait for independent acceptance.'
    }
    Write-Host 'PASS Does not export after an independent validation failure'

    [IO.File]::WriteAllText($observer, 'module counter_wave_observer; initial #1 $fatal(1, "failed during replay"); endmodule')
    $result = Invoke-AcceptanceCheck 0
    [IO.File]::WriteAllBytes($observer, $observerBytes)
    if ($result.waveformAcceptance.status -ne 'replay_failed' -or $result.waveformAcceptance.vcdPath -or
        $result.waveformAcceptance.stimulusPath -or $result.status -ne 'passed') {
        throw 'A replay failure must keep the original verdict and expose no accepted files.'
    }
    Write-Host 'PASS Keeps a failed optional replay out of accepted evidence'

    $settings.Remove('waveformAcceptance')
    $result = Invoke-AcceptanceCheck 0
    if ($result.waveformAcceptance -or [IO.Directory]::Exists((Join-Path $result.runDirectory 'waveform-acceptance'))) {
        throw 'Unconfigured projects should not run an acceptance replay.'
    }
    Write-Host 'PASS Leaves unconfigured projects on their original execution path'

    [IO.File]::WriteAllText((Join-Path $root 'xz_tb.sv'), @'
`timescale 1ns/1ps
module xz_tb;
    logic [1:0] data_in;
    wire [1:0] result = data_in;
    integer checked = 0;
    integer used_seed = `TRACE_SEED;
    integer seed_state, unused;
    initial begin
        seed_state = used_seed;
        unused = $random(seed_state);
        #4 data_in = 2'bxz;
        #2 checked = 1;
        if (result !== 2'bxz) $fatal(1, "unexpected four-state result");
        $display("XZ_PASS");
        $finish;
    end
endmodule
'@)
    [IO.File]::WriteAllText((Join-Path $root 'xz_observer.sv'), @'
module xz_observer;
    time drive_tick;
    initial $display("RTL_WAVE_SEED|TRACE_SEED|%0d", xz_tb.used_seed);
    always @(xz_tb.data_in) begin
        drive_tick = $simtime();
        $strobe("RTL_WAVE_DRIVE|%0d|data_in=%b", drive_tick, xz_tb.data_in);
    end
    final $display("RTL_WAVE_SAMPLE|%0d|%0d|Four-state check|xz|-|result=%b", drive_tick, $simtime(), xz_tb.result);
endmodule
'@)
    $settings.regressions = @(@{ id = 'xz-case'; top = 'xz_tb'; testbenches = @('xz_tb.sv'); defines = @('TRACE_SEED=42'); passMarker = 'XZ_PASS' })
    $settings.waveformAcceptance = @{
        regression = 'xz-case'; observer = 'xz_observer.sv'; observerTop = 'xz_observer'; expectedSource = 'testbench'
        signals = @('xz_tb.data_in', 'xz_tb.result')
        locations = @{ xz = @{ file = 'xz_tb.sv'; anchor = 'if (result !== 2''bxz) $fatal(1, "unexpected four-state result");' } }
    }
    $result = Invoke-AcceptanceCheck 0
    $wave = $result.waveformAcceptance
    if ($wave.status -ne 'ready' -or $wave.case -ne 'xz-case' -or $wave.sampleCount -ne 1 -or
        $wave.randomSeeds.values.TRACE_SEED -ne 42 -or '-DTRACE_SEED=42' -notin $wave.compile.arguments -or
        [IO.File]::ReadAllText($wave.stimulusPath) -notmatch '(?m)^\| Four-state check \| 4 ns \| 6 ns \| data_in=XZ \| result=未指定 \| result=XZ \| xz_tb\.sv:\d+ \|\r?$') {
        throw 'The selected regression must retain inherited parameters, seed evidence and four-state values.'
    }
    Write-Host 'PASS Replays one public regression with its real seed and preserves X/Z and unspecified values'
}
finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $temp -and [IO.Path]::GetFileName($resolved) -match '^rtl-acceptance-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '5 waveform acceptance tests passed.'
