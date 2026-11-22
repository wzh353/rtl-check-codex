#requires -Version 7.2

param([string]$QuartusMap)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'lib/Check.ps1')
. (Join-Path $toolRoot 'lib/Repair.ps1')
if (-not $QuartusMap) {
    try { $QuartusMap = Find-RtlQuartusMap '' }
    catch {
        Write-Host 'SKIP Quartus timing integration. Provide -QuartusMap or install quartus_map.'
        exit 0
    }
}
$cli = Join-Path $toolRoot 'rtl-check.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-timing-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$counter = [IO.File]::ReadAllText((Join-Path $toolRoot 'examples/counter/counter.sv')).Replace("8'd2", "8'd1")
[IO.File]::WriteAllText((Join-Path $root 'counter.sv'), $counter)
$config = Join-Path $root 'rtlcheck.json'
$sdcName = 'constraints/board timings.sdc'
$sdc = Join-Path $root $sdcName
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sdc))
$settings = @{
    top = 'counter'
    sources = @('counter.sv')
    synthesis = @{
        executable = $QuartusMap
        top = 'counter'
        family = 'Cyclone IV E'
        device = 'EP4CE6E22C8'
        timing = @{
            sdcFiles = @($sdcName)
            clocks = @{ clk = 20 }
        }
    }
}
$io = @'
set_input_delay -clock clk -max 2.000 [get_ports {rst_n en}]
set_input_delay -clock clk -min 2.000 [get_ports {rst_n en}]
set_output_delay -clock clk -max 2.000 [get_ports {count[*]}]
set_output_delay -clock clk -min -0.100 [get_ports {count[*]}]
derive_clock_uncertainty
'@

function Invoke-TimingTest([string]$Constraints, [int]$ExpectedExit, [string]$OutputDirectory) {
    [IO.File]::WriteAllText($sdc, $Constraints)
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 7))
    $options = @()
    if ($OutputDirectory) { $options += @('-OutDir', $OutputDirectory) }
    $output = & ([Environment]::ProcessPath) -NoProfile -File $cli check -Config $config -TimeoutSeconds 45 -Json @options
    if ($LASTEXITCODE -ne $ExpectedExit) {
        throw "Expected exit $ExpectedExit, got $LASTEXITCODE. $($output -join ' ')"
    }
    return ($output -join "`n" | ConvertFrom-Json -AsHashtable)
}

try {
    $clock20 = 'create_clock -name clk -period 20.000 [get_ports {clk}]'
    $full = Invoke-TimingTest ($clock20 + "`n" + $io) 0
    if ($full.initial.stage -ne 'timing' -or $full.initial.timing.constraintsComplete -ne $true -or
        $full.initial.timing.worstSetupSlackNs -le 0 -or $full.initial.timing.worstHoldSlackNs -le 0 -or
        $full.initial.fit.resources.logicElements -le 0 -or
        $full.initial.timing.sdcFiles[$sdcName] -ne 'OK' -or
        -not [IO.File]::Exists((Join-Path $full.runDirectory "baseline/$sdcName"))) {
        throw 'The constrained case must pass post-fit timing and preserve its SDC snapshot.'
    }
    Write-Host 'PASS Reports constrained post-fit timing and implemented resources'

    if ($IsWindows) {
        $long = Invoke-TimingTest ($clock20 + "`n" + $io) 0 (Join-Path $root ('long-output-' + ('x' * 80)))
        $mapper = $long.initial.synthesis.process
        $timer = $long.initial.timing.process
        if ($long.initial.stage -ne 'timing' -or $mapper.executionDirectory.Length -ge $mapper.workingDirectory.Length -or
            $timer.executionDirectory -ne $mapper.executionDirectory -or [IO.Directory]::Exists($mapper.executionDirectory) -or
            -not [IO.File]::Exists($long.initial.timing.reportPath)) {
            throw 'Expected one temporary short build path for all hardware stages and durable reports at the requested root.'
        }
        Write-Host 'PASS Runs map, fit, and timing under a short alias for long report paths'
    }

    $project = Read-RtlProject $config
    $baseline = Join-Path $full.runDirectory 'baseline'
    $rtl = Join-Path $root 'counter.sv'
    [IO.File]::AppendAllText($sdc, "`n# changed after the check")
    $candidate = @{ 'counter.sv' = [Text.Encoding]::UTF8.GetBytes($counter + "`n// candidate") }
    $writeError = try { Publish-RtlRepair $project $baseline $candidate } catch { $_.Exception.Message }
    if ($writeError -notmatch 'changed since' -or [IO.File]::ReadAllText($rtl) -cne $counter) {
        throw "A changed SDC must block -Apply and preserve original RTL. $writeError"
    }
    Write-Host 'PASS Refuses to publish a candidate after its SDC changes'

    $collected = $full.initial.timing
    $qsf = Join-Path $root 'partial.qsf'
    $text = [IO.File]::ReadAllText($collected.summaryPath)
    $entry = [regex]::Match($text, "(?m)^Type.* Hold '[^`r`n]+'(?:\r?\n[^\r\n]+){2}")
    if (-not $entry.Success) { throw 'Expected a Hold result in the native fixture.' }
    [IO.File]::WriteAllText([IO.Path]::ChangeExtension($qsf, '.sta.summary'), $text.Remove($entry.Index, $entry.Length))
    [IO.File]::Copy($collected.reportPath, [IO.Path]::ChangeExtension($qsf, '.sta.rpt'))
    $evidence = @{ status = 'passed'; process = $collected.process }
    Add-RtlTimeQuestEvidence $evidence $project.Synthesis.timing $qsf $full.initial.synthesis.sdcFiles
    if ($evidence.status -ne 'error' -or $evidence.reason -ne 'unrecognized_timing') {
        throw 'A missing summary result must be caught by the per-corner report tables.'
    }
    Write-Host 'PASS Stops when the summary silently omits one timing check'

    [IO.File]::Copy($collected.summaryPath, [IO.Path]::ChangeExtension($qsf, '.sta.summary'), $true)
    $sdcFiles = @('unread.sdc') + $full.initial.synthesis.sdcFiles
    $evidence = @{ status = 'passed'; process = $collected.process }
    Add-RtlTimeQuestEvidence $evidence $project.Synthesis.timing $qsf $sdcFiles
    if ($evidence.status -ne 'error' -or $evidence.reason -ne 'sdc_not_read') {
        throw 'A promised SDC file missing from the native read list must block a pass.'
    }
    Write-Host 'PASS Verifies every expected SDC is recorded as read'

    $report = [IO.File]::ReadAllText($collected.reportPath)
    $entry = [regex]::Match($report, '(?m)^; Unconstrained Clocks\s+;[^\r\n]+')
    if (-not $entry.Success) { throw 'Expected the clock coverage row in the native fixture.' }
    $report = $report.Insert($entry.Index, "; Unconstrained Clocks ; 1 ; 1 ;`n")
    [IO.File]::WriteAllText([IO.Path]::ChangeExtension($qsf, '.sta.rpt'), $report)
    $evidence = @{ status = 'passed'; process = $collected.process }
    Add-RtlTimeQuestEvidence $evidence $project.Synthesis.timing $qsf $full.initial.synthesis.sdcFiles
    if ($evidence.status -ne 'error' -or $evidence.reason -ne 'unrecognized_timing') {
        throw 'Conflicting coverage rows must be rejected even when the zero counts are listed last.'
    }
    Write-Host 'PASS Rejects contradictory clock coverage data'

    $picoseconds = ($clock20 + "`n" + $io).Replace('20.000', '20000').Replace('2.000', '2000').Replace('-0.100', '-100')
    $formatted = Invoke-TimingTest ("set_time_format -unit ps -decimal_places 0`n" + $picoseconds) 0
    if ($formatted.initial.timing.clocks.clk -ne 20 -or
        $formatted.initial.timing.worstSetupSlackNs -ne $full.initial.timing.worstSetupSlackNs -or
        $formatted.initial.timing.worstHoldSlackNs -ne $full.initial.timing.worstHoldSlackNs) {
        throw 'Changing SDC display units must preserve the measured nanosecond timing results.'
    }
    Write-Host 'PASS Reports stable nanosecond slack even when the project SDC uses picoseconds'

    $settings.synthesis.timing.clocks.clk = 2
    $tight = Invoke-TimingTest ('create_clock -name clk -period 2.000 [get_ports {clk}]' + "`n" + $io) 1
    if ($tight.initial.timing.process.exitCode -ne 0 -or $tight.initial.timing.reason -ne 'slack_violation' -or
        $tight.initial.timing.worstSetupSlackNs -ge 0 -or $tight.initial.timing.worstPaths.Count -eq 0 -or
        $tight.initial.timing.worstPaths[0].toNode -eq '') {
        throw 'A real negative setup slack must fail with an endpoint despite TimeQuest exit 0.'
    }
    Write-Host 'PASS Blocks negative slack even when TimeQuest exits successfully'

    $settings.synthesis.timing.clocks.clk = 20
    $partial = Invoke-TimingTest $clock20 1
    if ($partial.initial.timing.reason -ne 'unconstrained_paths' -or
        $partial.initial.timing.constraintsComplete -ne $false -or $partial.initial.timing.worstSetupSlackNs -le 0) {
        throw 'Positive slack cannot pass strict coverage when I/O paths are unconstrained.'
    }
    Write-Host 'PASS Detects unconstrained I/O with otherwise positive slack'

    $settings.synthesis.timing.requireFullyConstrained = $false
    $settings.synthesis.timing.clocks.clk = 1
    $autoClock = Invoke-TimingTest '# intentionally no SDC clock' 1
    if ($autoClock.initial.timing.reason -ne 'clock_mismatch') {
        throw 'An automatically inferred clock cannot satisfy the declared contract.'
    }
    Write-Host 'PASS Rejects an implicitly inferred or mismatched clock'

    $settings.synthesis.timing.requireFullyConstrained = $true
    $settings.synthesis.timing.clocks.clk = 20
    $settings.synthesis.timing.maxLogicElements = 1
    $area = Invoke-TimingTest ($clock20 + "`n" + $io) 1
    if ($area.initial.stage -ne 'fit' -or $area.initial.fit.reason -ne 'logic_elements_limit' -or $area.initial.timing) {
        throw 'A measured fitter utilization over the configured limit must stop the check.'
    }
    Write-Host 'PASS Applies the implemented logic element budget before timing'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-timing-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if ($IsWindows) { Write-Host '11 timing tests passed.' }
else { Write-Host '10 timing tests passed.' }
