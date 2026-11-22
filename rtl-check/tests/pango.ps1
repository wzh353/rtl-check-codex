#requires -Version 7.2

param([string]$PdsShell)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'lib/Check.ps1')
if (-not $PdsShell) {
    $tool = Get-Command pds_shell -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $tool) {
        Write-Host 'SKIP Pango integration. Provide -PdsShell or add pds_shell to PATH.'
        exit 0
    }
    $PdsShell = $tool.Source
}

$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-pango-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$fixture = Join-Path $root 'project'
Copy-Item -LiteralPath (Join-Path $toolRoot 'examples/evaluation/mes50hp') -Destination $fixture -Recurse
$config = Join-Path $fixture 'rtlcheck.json'
$settings = [IO.File]::ReadAllText($config) | ConvertFrom-Json -AsHashtable
$settings.synthesis.executable = [IO.Path]::GetFullPath($PdsShell)
[IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 7))
$cli = Join-Path $toolRoot 'rtl-check.ps1'

function Invoke-PangoTest([int]$ExpectedExit, [string]$Mode = 'check') {
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $cli $Mode -Config $config -Json -TimeoutSeconds 20
    $exitCode = $LASTEXITCODE
    $report = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($exitCode -ne $ExpectedExit) {
        throw "Expected Pango check exit $ExpectedExit, got $exitCode. $($report.error) $($report.initial.diagnostic)"
    }
    return $report
}

try {
    $control = Invoke-PangoTest 0
    $initial = $control.initial
    $pins = $initial.fit.board
    $timing = $initial.timing
    $fdc = Join-Path $control.runDirectory 'baseline/mes50hp.fdc'
    if ($initial.stage -ne 'timing' -or $initial.synthesis.engine -ne 'pango' -or
        $pins.matchedPinCount -ne 3 -or $pins.portCount -ne 3 -or $pins.ports.clk.pin -ne 'P20' -or
        $pins.ports.rst_n.pin -ne 'K18' -or $pins.ports.led.pin -ne 'B2' -or
        $timing.clocks.board_clk -ne 20 -or $timing.worstSetupSlackNs -le 0 -or
        $timing.worstHoldSlackNs -le 0 -or $control.validation.status -ne 'passed' -or
        -not [IO.File]::Exists($initial.fit.reportPath) -or -not [IO.File]::Exists($timing.reportPath) -or
        (Get-FileHash -LiteralPath $fdc).Hash -ne (Get-FileHash -LiteralPath (Join-Path $fixture 'mes50hp.fdc')).Hash) {
        throw 'The control must have native synthesis, matching MES50HP pins, measured timing and successful independent simulation.'
    }
    Write-Host 'PASS Checks native MES50HP pins and post-route timing before independent acceptance'

    $partialReport = Join-Path $root 'partial.prr'
    $pinText = [IO.File]::ReadAllText($initial.fit.reportPath)
    $partial = [regex]::Match($pinText, '(?ms)\A.*?^\|\s+rst_n\s+\|[^\r\n]*')
    if (-not $partial.Success) { throw 'Expected a reset pin in the native port table.' }
    [IO.File]::WriteAllText($partialReport, $partial.Value)
    if (Read-RtlPangoImplementedPins $partialReport) { throw 'A pin table without its closing border must be rejected.' }
    [IO.File]::Delete($partialReport)
    Write-Host 'PASS Rejects a truncated native pin table'

    $timingText = [IO.File]::ReadAllText($timing.reportPath)
    $timingProbe = Join-Path $root 'timing.rtr'
    $limits = Read-RtlTimingLimits $settings.synthesis.timing
    $setupRow = [regex]::Match($timingText, '(?m)^ +board_clk +board_clk +[-\d.]+ +[-\d.]+ +\d+ +\d+ *\r?$')
    if (-not $setupRow.Success) { throw 'Expected a measured setup row in the native report.' }
    $malformed = $timingText.Insert($setupRow.Index, ' board_clk board_clk -1.500 -1.500 1 malformed' + [Environment]::NewLine)
    [IO.File]::WriteAllText($timingProbe, $malformed)
    $observed = @{ status = 'passed'; reportPath = $timingProbe; process = $timing.process }
    Add-RtlPangoTimingEvidence $observed $limits
    if ($observed.reason -ne 'unrecognized_timing_report' -or $observed.status -ne 'error') {
        throw 'A malformed row must invalidate the entire native timing table.'
    }
    $inactive = [regex]::Replace($timingText, '(?m)^ +board_clk +20\.0000 +\{[^}]+\} +Declared +\d+ +\d+ +\{[^}]+\} *\r?$',
        ' board_clk 20.0000 {0.0000 10.0000} Declared 0 0 {}')
    [IO.File]::WriteAllText($timingProbe, $inactive)
    Add-RtlPangoTimingEvidence $observed $limits
    if ($observed.reason -ne 'clock_mismatch' -or $observed.status -ne 'failed') {
        throw 'A declared clock with no measured loads or source must fail acceptance.'
    }
    Write-Host 'PASS Rejects malformed timing rows and inactive clock evidence'

    $limits.minSetupSlackNs = 20
    $observation = @{ status = 'passed'; reportPath = $timing.reportPath; process = $timing.process }
    Add-RtlPangoTimingEvidence $observation $limits
    if ($observation.reason -ne 'slack_violation' -or $observation.status -ne 'failed' -or
        ($observation.violations | Where-Object type -eq 'setup').Count -ne 2) {
        throw 'A setup margin beyond the measured value must fail at both corners.'
    }
    Write-Host 'PASS Enforces the setup slack threshold using real corner results'

    $native = @{
        stdout = Join-Path $root 'diagnostic.stdout.log'
        stderr = Join-Path $root 'diagnostic.stderr.log'
        timedOut = $false
        exitCode = 1
        workingDirectory = $fixture
    }
    [IO.File]::WriteAllText($native.stderr, '')
    $rtl = Join-Path $fixture 'mes50hp_blink.v'
    [IO.File]::WriteAllLines($native.stdout, [string[]]@(
        'Process "Compile" started.',
        "E: Verilog-4005: [$rtl(line number: 7)] Syntax error near ;",
        'E: Parsing ERROR.'
    ))
    $actions = [ordered]@{ Compile = 'synthesize' }
    $normal = Get-RtlPangoStageResult $native (Read-RtlPangoTranscript $native $actions) 'synthesize' @('Compile') @() $true 20
    if ($normal.status -ne 'failed' -or $normal.firstError.inputFile -ne 'mes50hp_blink.v' -or $normal.firstError.line -ne 7) {
        throw 'A native HDL diagnostic must be marked repairable and map to the input file.'
    }
    [IO.File]::AppendAllLines($native.stdout, [string[]]@('F: Public-1234: Internal compiler fatal error.'))
    $brokenTool = Get-RtlPangoStageResult $native (Read-RtlPangoTranscript $native $actions) 'synthesize' @('Compile') @() $true 20
    if ($brokenTool.status -ne 'error' -or $brokenTool.firstError.code -ne 'Public-1234') {
        throw 'An infrastructure error must take precedence over earlier HDL diagnostics.'
    }
    Write-Host 'PASS Separates HDL diagnostics from PDS infrastructure errors'

    $rtlPath = Join-Path $fixture 'mes50hp_blink.v'
    $original = [IO.File]::ReadAllText($rtlPath)
    $fault = $original.Replace('output wire led', "output wire led,`n    output wire spare").
        Replace('assign led = ticks[COUNTER_BITS-1];', "assign led = ticks[COUNTER_BITS-1];`n    assign spare = ticks[0];")
    [IO.File]::WriteAllText($rtlPath, $fault)
    $failed = Invoke-PangoTest 1
    if ($failed.initial.stage -ne 'fit' -or $failed.initial.simulate.exitCode -ne 0 -or
        $failed.initial.fit.process.exitCode -ne 0 -or $failed.initial.fit.reason -ne 'board_mismatch' -or
        $failed.initial.fit.board.ports.spare.constrained -ne $false -or
        $failed.initial.diagnostic -notmatch 'spare' -or $failed.validation) {
        throw 'An automatically placed extra port must fail the board check even after successful simulation and routing.'
    }
    Write-Host 'PASS Rejects a successfully routed but unassigned top-level port'
}
finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-pango-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '6 Pango tests passed.'
