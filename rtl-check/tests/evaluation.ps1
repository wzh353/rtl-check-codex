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
Write-Host '8 evaluation tests passed.'
