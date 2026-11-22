#requires -Version 7.2

param([string]$GowinShell)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $toolRoot 'rtl-check.ps1'
if (-not $GowinShell) {
    $command = Get-Command gw_sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $GowinShell = $command.Source }
}
if (-not $GowinShell -or -not [IO.File]::Exists($GowinShell)) {
    Write-Host 'SKIP Gowin timing tests. Set -GowinShell or add gw_sh to PATH.'
    exit 0
}
. (Join-Path $toolRoot 'lib/Check.ps1')

$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$root = Join-Path $temp "rtl-gowin-timing-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$fixture = Join-Path $toolRoot 'examples/evaluation/counter'
$config = Join-Path $root 'rtlcheck.json'
$sdc = Join-Path $root 'board clock.sdc'
$settings = Get-Content -LiteralPath (Join-Path $fixture 'gowin.json') -Raw | ConvertFrom-Json -AsHashtable
$settings.synthesis.Remove('implementation')
$settings.synthesis.executable = $GowinShell
$settings.synthesis.constraintFiles = @('board clock.sdc')
$settings.synthesis.timing = @{ clocks = @{ sys_clk = 20 }; minSetupSlackNs = 0; minHoldSlackNs = 0 }

function Set-Clock([string]$Period, [string]$Port = 'clk') {
    [IO.File]::WriteAllText($sdc, ('create_clock -name sys_clk -period {0} [get_ports {{{1}}}]' -f $Period, $Port))
}

function Invoke-GowinTimingCheck([int]$ExpectedExit, [string]$Mode = 'check') {
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 8))
    $workOutput = Join-Path $root ('results with spaces ' + ('x' * 42))
    $output = & ([Environment]::ProcessPath) -NoProfile -File $cli $Mode -Config $config -OutDir $workOutput -TimeoutSeconds 35 -Json
    if ($LASTEXITCODE -ne $ExpectedExit) {
        $report = $output -join [Environment]::NewLine | ConvertFrom-Json -AsHashtable
        throw "Expected exit $ExpectedExit, got $LASTEXITCODE. $($report.error)"
    }
    return ($output -join [Environment]::NewLine | ConvertFrom-Json -AsHashtable)
}

try {
    foreach ($file in @('counter.sv', 'counter_tb.sv', 'counter_validation_tb.sv', 'spec.txt')) {
        Copy-Item -LiteralPath (Join-Path $fixture $file) -Destination $root
    }
    Set-Clock '20'
    $passing = Invoke-GowinTimingCheck 0
    $timing = $passing.initial.timing
    if ($passing.initial.stage -ne 'timing' -or $passing.initial.fit.status -ne 'passed' -or
        $passing.validation.status -ne 'passed' -or $timing.clocks.sys_clk -ne 20 -or
        $timing.worstSetupSlackNs -le 0 -or $timing.worstHoldSlackNs -le 0 -or
        $timing.sdcFile -ne 'board clock.sdc' -or -not [IO.File]::Exists($timing.reportPath)) {
        throw 'Expected real Gowin clock constraints and post-route setup and hold evidence.'
    }
    Write-Host 'PASS Checks constrained native Gowin timing before independent acceptance'

    $textReport = [IO.File]::ReadAllText($timing.reportPath)
    $core = $textReport.IndexOf('Note:Core Timing Report', [StringComparison]::Ordinal)
    $end = $textReport.IndexOf('3.1.2 Hold Paths Table', $core, [StringComparison]::Ordinal)
    $incomplete = Join-Path $root 'incomplete.tr'
    [IO.File]::WriteAllText($incomplete, $textReport.Substring(0, $end))
    if (Read-RtlGowinTimingReport $incomplete) { throw 'A truncated timing report must not be accepted.' }
    Write-Host 'PASS Rejects a native timing report truncated before hold evidence'

    Set-Clock '0.5'
    $settings.synthesis.timing.clocks.sys_clk = 0.5
    $failing = Invoke-GowinTimingCheck 1
    $timing = $failing.initial.timing
    if ($failing.initial.stage -ne 'timing' -or $failing.initial.fit.status -ne 'passed' -or
        $failing.validation -or $timing.reason -ne 'slack_violation' -or $timing.worstSetupSlackNs -ge 0 -or
        $timing.coverage.setupViolatingEndpoints -le 0 -or 'setup' -notin $timing.violations.type -or
        $timing.worstPaths.Count -lt 2) {
        throw 'A native setup violation must fail at timing despite completed routing.'
    }
    Write-Host 'PASS Blocks a nominally successful route with negative setup slack'

    Set-Clock '20'
    $settings.synthesis.timing.clocks.sys_clk = 20
    $settings.synthesis.timing.minHoldSlackNs = 100
    $strictHold = Invoke-GowinTimingCheck 1
    if ($strictHold.initial.timing.reason -ne 'slack_violation' -or
        $strictHold.initial.timing.worstHoldSlackNs -le 0 -or 'hold' -notin $strictHold.initial.timing.violations.type) {
        throw 'Positive measured hold slack below the configured minimum must fail.'
    }
    Write-Host 'PASS Enforces the configured hold margin above zero'

    $settings.synthesis.timing.minHoldSlackNs = 0
    $settings.synthesis.timing.clocks.sys_clk = 21
    $mismatch = Invoke-GowinTimingCheck 2 'repair'
    if ($mismatch.initial.timing.reason -ne 'clock_mismatch' -or $mismatch.attempts.Count -ne 0) {
        throw 'A mismatch between the configured and measured clock period must stop before Codex.'
    }
    Write-Host 'PASS Keeps clock configuration mismatches out of automatic repair'

    $settings.synthesis.timing.clocks.sys_clk = 20
    Set-Clock '20' 'does_not_exist'
    $invalid = Invoke-GowinTimingCheck 2 'repair'
    if ($invalid.initial.fit.reason -ne 'invalid_constraints' -or $invalid.attempts.Count -ne 0 -or
        $invalid.initial.firstError.inputFile -ne 'board clock.sdc' -or $invalid.initial.firstError.line -ne 1) {
        throw 'An invalid native timing constraint must remain a configuration error.'
    }
    Write-Host 'PASS Classifies the native invalid clock target as a constraint error'

    Set-Clock '20'
    [IO.File]::WriteAllText((Join-Path $root 'pulse.sv'), 'module pulse(input logic clk, output logic q); always_ff @(posedge clk) q <= 1''b1; endmodule')
    $settings.top = $settings.synthesis.top = 'pulse'
    $settings.sources = @('pulse.sv')
    $settings.testbenches = @()
    $settings.Remove('validation')
    $unmeasured = Invoke-GowinTimingCheck 2
    if ($unmeasured.initial.fit.status -ne 'passed' -or $unmeasured.initial.timing.reason -ne 'missing_checks') {
        throw 'A clock declaration without measured setup and hold paths must not pass.'
    }
    Write-Host 'PASS Detects declared clocks without actual setup or hold paths'
}
finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $temp -and [IO.Path]::GetFileName($resolved) -match '^rtl-gowin-timing-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '7 Gowin timing tests passed.'
