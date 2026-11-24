#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $toolRoot 'rtl-evaluate.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-evaluation-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath (Join-Path $toolRoot 'examples/counter') -Destination (Join-Path $root 'counter') -Recurse
$source = Join-Path $root 'counter/counter.sv'
$config = Join-Path $root 'counter/rtlcheck.json'
$healthy = [IO.File]::ReadAllText($source).Replace("count + 8'd2", "count + 8'd1")
[IO.File]::WriteAllText($source, $healthy)
$settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
$settings.repairFiles = @('counter.sv')
[IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 7))
$manifest = Join-Path $root 'cases.json'
$outputRoot = Join-Path $root 'results'
$arithmetic = @{
    id = 'wrong-step'
    config = 'counter/rtlcheck.json'
    mutations = @(@{ path = 'counter.sv'; before = "count + 8'd1"; after = "count + 8'd2" })
    failure = @{ stage = 'simulate'; messageContains = 'expected=1 actual=2' }
}
$guard = @{
    id = 'independent-reset'
    config = 'counter/rtlcheck.json'
    mutations = @(@{ path = 'counter.sv'; before = 'posedge clk)'; after = 'posedge clk or negedge rst_n)' })
    failure = @{ stage = 'validation'; messageContains = 'independent reset check' }
}
$configBytes = (Get-FileHash -LiteralPath $config).Hash

function Invoke-EvaluationTest([object[]]$Cases, [string]$Mode, [int]$Exit, [int]$Timeout = 45, [int]$Parallelism = 1) {
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject @{ cases = $Cases } -Depth 8))
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $cli -Manifest $manifest -Mode $Mode -OutDir $outputRoot -TimeoutSeconds $Timeout -Parallelism $Parallelism -Json
    $code = $LASTEXITCODE
    $r = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($code -ne $Exit) { throw "Expected exit $Exit, got $code. $($r.error)" }
    if ([IO.File]::ReadAllText($source) -cne $healthy -or (Get-FileHash -LiteralPath $config).Hash -cne $configBytes) {
        throw 'Evaluation modified its source fixture or configuration.'
    }
    return $r
}

try {
    $hold = @{ id = 'missed-hold'; config = 'counter/rtlcheck.json'; mutations = @(@{
        path = 'counter.sv'; before = 'else if (en)'; after = "else if (en || count == 8'd127)"
    }) }
    $syntax = @{ id = 'syntax'; config = $hold.config; mutations = @(@{ path = 'counter.sv'; before = "count + 8'd1"; after = 'count +' }) }
    $audit = Invoke-EvaluationTest @($arithmetic, $guard, $hold, $syntax) 'testbench' 0 -Parallelism 3
    if ($audit.status -ne 'completed' -or $audit.metrics.modelCalls -ne 0 -or $audit.metrics.controlsPassed -ne 4 -or
        ($audit.cases.detection.outcome -join ',') -cne 'public_detected,validation_only,survived,compile_rejected' -or
        $audit.detectionCounts.survived -ne 1 -or $audit.detectionCounts.public_detected -ne 1 -or
        $audit.cases[0].detection.file -ne 'counter_tb.sv' -or $audit.cases[0].detection.line -lt 1 -or
        $audit.cases[1].detection.file -ne 'counter_validation_tb.sv') {
        throw 'Testbench measurements must separate public and holdout detections, surviving edits and compile rejections.'
    }
    $missingExpectation = Invoke-EvaluationTest @($hold) 'check' 2
    if ($missingExpectation.error -notmatch 'expected failure stage') { throw 'Calibration still requires its expected failure.' }
    Write-Host 'PASS Measures which test caught each mutation using both measured snapshots'

    $noMarker = @{ id = 'early-finish'; config = $hold.config; mutations = @(@{ path = 'counter.sv'; before = 'endmodule'; after = 'initial #1 $finish; endmodule' }) }
    $rtlFatal = @{ id = 'dut-fatal'; config = $hold.config; mutations = @(@{ path = 'counter.sv'; before = 'endmodule'; after = 'initial #1 $fatal(1, "DUT error"); endmodule' }) }
    $compileOnly = @{ id = 'compile-only'; config = 'counter/compile-only.json'; mutations = $hold.mutations }
    [IO.File]::WriteAllText((Join-Path $root $compileOnly.config), '{"top":"counter","sources":["counter.sv"]}')
    $unmeasured = Invoke-EvaluationTest @($noMarker, $rtlFatal, $compileOnly) 'testbench' 1 -Parallelism 3
    if ($unmeasured.status -ne 'inconclusive' -or $unmeasured.detectionCounts.inconclusive -ne 3 -or
        $unmeasured.detectionCounts.public_detected -ne 0 -or $unmeasured.detectionCounts.survived -ne 0) {
        throw 'Early exit, a DUT-originated fatal and compile-only checks cannot qualify as measured testbench outcomes.'
    }
    Write-Host 'PASS Excludes missing test evidence and DUT-originated errors from testbench detections'

    $withRegression = @{
        top = 'counter'; sources = @('counter.sv'); regressions = @(@{
            id = 'exercise'; top = 'counter_tb'; testbenches = @('counter_tb.sv'); defines = @('REGRESSION_ONLY')
        })
    }
    $path = 'counter/regression-only.json'
    [IO.File]::WriteAllText((Join-Path $root $path), (ConvertTo-Json $withRegression -Depth 7))
    $lateCompile = @{ id = 'regression-compile'; config = $path; mutations = @(@{
        path = 'counter.sv'; before = 'endmodule'; after = "``ifdef REGRESSION_ONLY`nmissing_cell child();`n``endif`nendmodule"
    }) }
    $lateFailure = @{ id = 'regression-detected'; config = $path; mutations = $arithmetic.mutations }
    $latePass = @{ id = 'regression-survived'; config = $path; mutations = $hold.mutations }
    $late = Invoke-EvaluationTest @($lateCompile, $lateFailure, $latePass) 'testbench' 0 -Parallelism 3
    if (($late.cases.detection.outcome -join ',') -cne 'compile_rejected,public_detected,survived' -or
        $late.cases[0].detection.stage -ne 'compile' -or $late.cases[1].detection.stage -ne 'simulate' -or
        $late.cases[1].detection.regression -ne 'exercise') {
        throw 'A compile-only primary must preserve the actual regression name, nested stage, and simulation evidence.'
    }
    Write-Host 'PASS Attributes nested compile and simulation results to the actual public regression'

    [IO.File]::WriteAllText((Join-Path $root 'counter/broken-control.sv'), $healthy.Replace("count + 8'd1", "count + 8'd2"))
    $brokenControl = @{ id = 'bad-control'; config = 'counter/bad-control.json'; mutations = @(@{
        path = 'broken-control.sv'; before = "count + 8'd2"; after = "count + 8'd1"
    }) }
    [IO.File]::WriteAllText((Join-Path $root $brokenControl.config), '{"top":"counter_tb","sources":["broken-control.sv"],"testbenches":["counter_tb.sv"]}')
    $badControlResult = Invoke-EvaluationTest @($brokenControl) 'testbench' 1
    if ($badControlResult.metrics.controlsPassed -ne 0 -or $badControlResult.cases[0].detection.reason -ne 'control_failed' -or
        $badControlResult.detectionCounts.inconclusive -ne 1) { throw 'A failing healthy control invalidates the measurement.' }
    Write-Host 'PASS Excludes a mutation whose control fails its original tests'

    $calibration = Invoke-EvaluationTest @($arithmetic, $guard) 'check' 0 -Parallelism 3
    $batchCalibration = [IO.File]::ReadAllText($calibration.calibrationReport) | ConvertFrom-Json -AsHashtable
    if ($calibration.metrics.controlsPassed -ne 2 -or $calibration.metrics.faultsAtExpectedStage -ne 2 -or
        $calibration.metrics.modelCalls -ne 0 -or $calibration.cases[1].observedFailure.stage -ne 'validation' -or
        $batchCalibration.settings.parallelism -ne 3 -or
        ($batchCalibration.cases.id -join ',') -cne 'control-0,fault-0,control-1,fault-1' -or
        $calibration.cases[0].controlInputSha256 -eq $calibration.cases[0].faultInputSha256 -or
        $false -in $calibration.cases.controlSnapshotMatched -or $false -in $calibration.cases.faultSnapshotMatched -or
        -not [IO.File]::Exists((Join-Path $calibration.runDirectory 'summary.json'))) {
        throw 'Parallel calibration must check the actual snapshot pairs without invoking Codex.'
    }
    Write-Host 'PASS Calibrates controls and injected failures in parallel without modifying fixtures'

    $staleManifest = Join-Path $root 'stale.json'
    [IO.File]::WriteAllText($staleManifest, (ConvertTo-Json -InputObject @{ cases = @(@{
        id = 'stale-input'
        config = $calibration.cases[0].controlConfig
        inputSha256 = $calibration.cases[0].faultInputSha256
    }) } -Depth 6))
    $batch = Join-Path $toolRoot 'rtl-batch.ps1'
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $batch -Manifest $staleManifest -Mode repair -OutDir $outputRoot -Json
    $staleExit = $LASTEXITCODE
    $stale = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($staleExit -ne 2 -or $stale.cases[0].error -notmatch 'Input snapshot digest mismatch' -or
        $stale.metrics.modelCalls -ne 0 -or $stale.cases[0].baselineStage) {
        throw 'A batch case with a stale input digest must stop before any check or model call.'
    }
    Write-Host 'PASS Rejects a changed batch input before launching the repair workflow'

    $guardOnly = Invoke-EvaluationTest @($guard) 'repair' 0 -Parallelism 2
    $guardCalibration = [IO.File]::ReadAllText($guardOnly.calibrationReport) | ConvertFrom-Json -AsHashtable
    $guardRepair = [IO.File]::ReadAllText($guardOnly.repairReport) | ConvertFrom-Json -AsHashtable
    if ($guardOnly.metrics.guardChecksPassed -ne 1 -or $guardOnly.metrics.modelCalls -ne 0 -or
        $guardOnly.cases[0].repair.status -ne 'failed' -or $guardOnly.cases[0].repair.stopReason -ne 'validation_failed' -or
        $guardCalibration.settings.parallelism -ne 2 -or $guardRepair.settings.parallelism -ne 1 -or
        -not $guardOnly.cases[0].repairSnapshotMatched) {
        throw 'A holdout-only defect must stay rejected during serial repair after parallel calibration.'
    }
    Write-Host 'PASS Uses serial repair after parallel calibration and honors the independent validation guard'

    $arithmetic.failure.stage = 'compile'
    $unexpected = Invoke-EvaluationTest @($arithmetic) 'repair' 1
    if ($unexpected.stopReason -ne 'calibration_failed' -or $unexpected.metrics.faultsAtExpectedStage -ne 0 -or
        $unexpected.metrics.modelCalls -ne 0 -or $unexpected.cases[0].repair -or
        $unexpected.cases[0].observedFailure.stage -ne 'simulate') {
        throw 'A calibration mismatch must stop before Codex and report the measured failure.'
    }
    Write-Host 'PASS Stops before repair when the injected failure reaches the wrong gate'

    $arithmetic.mutations[0].before = 'text absent from design'
    $invalid = Invoke-EvaluationTest @($arithmetic) 'check' 2
    if ($invalid.error -notmatch "was not found|exactly once") { throw 'Expected an actionable mutation error.' }
    Write-Host 'PASS Rejects an invalid mutation with the healthy fixture intact'

    $hang = @{
        id = 'timeout'
        config = 'counter/rtlcheck.json'
        mutations = @(@{
            path = 'counter.sv'
            before = 'endmodule'
            after = "    initial begin #1; forever #0; end`nendmodule"
        })
        failure = @{ stage = 'simulate' }
    }
    $timed = Invoke-EvaluationTest @($hang) 'check' 1 3 -Parallelism 2
    if ($timed.metrics.faultsAtExpectedStage -ne 0 -or -not $timed.cases[0].observedFailure.timedOut) {
        throw 'A simulation timeout must be visible without counting as a calibrated design failure.'
    }
    Write-Host 'PASS Distinguishes an EDA timeout from a deliberately injected defect'
    $timedAudit = Invoke-EvaluationTest @($hang) 'testbench' 1 3 -Parallelism 2
    if ($timedAudit.cases[0].detection.reason -ne 'timeout' -or $timedAudit.detectionCounts.inconclusive -ne 1) {
        throw 'A timed-out simulator must not receive credit for detecting a mutation.'
    }
    Write-Host 'PASS Excludes timed-out mutation simulations even with the correct expected stage'

    $scopeConfig = Join-Path $root 'counter/scope.json'
    [IO.File]::WriteAllText((Join-Path $root 'counter/other.v'), 'module other; endmodule')
    $scope = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    $scope.sources += 'other.v'
    $scope.repairFiles = @('other.v')
    [IO.File]::WriteAllText($scopeConfig, (ConvertTo-Json -InputObject $scope -Depth 7))
    $outside = @{
        id = 'out-of-scope'
        config = 'counter/scope.json'
        mutations = @(@{ path = 'counter.sv'; before = "count + 8'd1"; after = "count + 8'd2" })
        failure = @{ stage = 'compile' }
    }
    $blocked = Invoke-EvaluationTest @($outside) 'repair' 2
    if ($blocked.metrics.modelCalls -ne 0 -or $blocked.error -notmatch 'repairFiles') {
        throw 'The evaluator must not spend on faults outside the configured repair scope.'
    }
    Write-Host 'PASS Requires authorized repair targets for the injected files'

    $private = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    $null = [IO.Directory]::CreateDirectory((Join-Path $root 'counter/private-include'))
    $private.validation.includeDirs = @('private-include')
    [IO.File]::WriteAllText((Join-Path $root 'counter/includes.json'), (ConvertTo-Json -InputObject $private -Depth 7))
    $guard.config = 'counter/includes.json'
    $relocated = Invoke-EvaluationTest @($guard) 'check' 0
    if ($relocated.metrics.controlsPassed -ne 1 -or $relocated.metrics.faultsAtExpectedStage -ne 1) {
        throw 'Empty include directories defined only by a suite must survive relocation.'
    }
    Write-Host 'PASS Preserves suite-local include directories in the evaluation replicas'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-evaluation-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '13 evaluation tests passed.'
