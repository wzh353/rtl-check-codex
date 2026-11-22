#requires -Version 7.2

<#
.SYNOPSIS
Calibrates local RTL cases against a healthy control and injected defect, then optionally measures repairs.
.PARAMETER Parallelism
Maximum concurrent checker processes during calibration, from 1 to 8. Defaults to 1. Repair measurement runs serially.
#>
[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Mandatory)][string]$Manifest,
    [ValidateSet('check', 'repair')][string]$Mode = 'check',
    [ValidateRange(1, 8)][int]$Parallelism = 1,
    [ValidateRange(1, 10)][int]$MaxAttempts = 3,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 45,
    [ValidateRange(1, 3600)][int]$CodexTimeoutSeconds = 240,
    [string]$Model,
    [string]$OutDir,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'lib/Check.ps1')
. (Join-Path $PSScriptRoot 'lib/Repair.ps1')

function Read-RtlEvaluationCases([string]$Path) {
    $manifest = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    if ($manifest -isnot [System.Collections.IDictionary] -or
        $manifest['cases'] -isnot [array] -or $manifest['cases'].Count -eq 0) {
        throw 'An evaluation manifest needs a nonempty cases array.'
    }
    $root = [IO.Path]::GetDirectoryName($Path)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($case in $manifest['cases']) {
        if ($case -isnot [System.Collections.IDictionary] -or $case['id'] -isnot [string] -or
            $case['id'] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') {
            throw 'Every evaluation case needs a valid case id.'
        }
        if (-not $ids.Add($case['id'])) { throw "Duplicate evaluation case id '$($case['id'])'." }
        if ($case['mutations'] -isnot [array] -or $case['mutations'].Count -eq 0) {
            throw "Case '$($case['id'])' must specify a nonempty mutations array."
        }
        $failure = $case['failure']
        if ($failure -isnot [System.Collections.IDictionary] -or $failure['stage'] -isnot [string] -or
            $failure['stage'] -cnotin @('compile', 'simulate', 'regression', 'synthesize', 'fit', 'timing', 'validation')) {
            throw "Case '$($case['id'])' must name its expected failure stage."
        }
        foreach ($key in $failure.Keys) {
            if ($key -ceq 'stage') { continue }
            if ($key -ceq 'code' -and ($failure[$key] -is [int] -or $failure[$key] -is [long])) { continue }
            if ($key -cin @('regression', 'reason', 'messageContains') -and $failure[$key] -is [string] -and
                -not [string]::IsNullOrWhiteSpace($failure[$key])) { continue }
            throw "Invalid failure expectation '$key' in case '$($case['id'])'."
        }
        $config = Resolve-RtlProjectItem $root $case['config']
        @{
            id = $case['id']
            config = Join-Path $root $config
            mutations = $case['mutations']
            failure = $failure
        }
    }
}

function New-RtlEvaluationPair($Case, [string]$Root, [int]$Ordinal, [string]$Mode) {
    $project = Read-RtlProject $Case.config
    $repairTargets = if ($Mode -eq 'repair') { @(Get-RtlRepairTargets $project '') }
    $folder = Join-Path $Root ('{0:D3}-{1}' -f $Ordinal, $Case.id)
    $control = Join-Path $folder 'control'
    $fault = Join-Path $folder 'fault'
    Copy-RtlProjectBaseline $project $control

    # Relocating the snapshot must preserve the meaning of configured tool paths.
    $config = [Text.Encoding]::UTF8.GetString($project.ConfigBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable
    if ($project.Synthesis -and $project.Synthesis.executable) { $config['synthesis']['executable'] = $project.Synthesis.executable }
    foreach ($suite in (@($config) + @($config['regressions']) + @($config['validation']))) {
        if ($suite -and $suite['simulator'] -and $suite['simulator']['binDirectory']) {
            $suite['simulator']['binDirectory'] = [IO.Path]::GetFullPath($suite['simulator']['binDirectory'], $project.Root)
        }
    }
    $controlConfig = Join-Path $control $project.ConfigName
    [IO.File]::WriteAllText($controlConfig, (ConvertTo-Json -InputObject $config -Depth 100))
    Copy-RtlInputs $project $control $fault -WithValidation
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $current = [ordered]@{}
    $edits = @(foreach ($mutation in $Case.mutations) {
        if ($mutation -isnot [System.Collections.IDictionary] -or $mutation['path'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($mutation['path'])) { throw "Case '$($Case.id)' needs a path on every mutation." }
        $target = @(Get-RtlRepairTargets $project $mutation['path'])[0]
        if ($Mode -eq 'repair' -and $Case.failure.stage -ne 'validation' -and $target -cnotin $repairTargets) {
            throw "Injected file '$target' is outside repairFiles for case '$($Case.id)'."
        }
        if (-not $current.Contains($target)) {
            $current[$target] = $encoding.GetString([IO.File]::ReadAllBytes((Join-Path $control $target)))
        }
        @{ path = $target; before = $mutation['before']; after = $mutation['after'] }
    })
    $updated = Update-RtlSources $current $edits
    foreach ($path in $updated.Keys) { [IO.File]::WriteAllBytes((Join-Path $fault $path), $encoding.GetBytes($updated[$path])) }
    $files = @(Get-RtlBaselineFiles $project)
    return [ordered]@{
        id = $Case.id
        sourceConfig = $Case.config
        controlConfig = $controlConfig
        faultConfig = Join-Path $fault $project.ConfigName
        expectedFailure = $Case.failure
        inputFiles = $files
        controlInputSha256 = Get-RtlInputDigest $control $files
        faultInputSha256 = Get-RtlInputDigest $fault $files
        controlSnapshotMatched = $null
        faultSnapshotMatched = $null
        control = $null
        fault = $null
        observedFailure = $null
        repair = $null
        repairSnapshotMatched = $null
        repairBaselineMatched = $null
    }
}

function Invoke-RtlEvaluationBatch([array]$Cases, [string]$Path, [string]$BatchMode) {
    $manifestPath = Join-Path $Path 'cases.json'
    $null = [IO.Directory]::CreateDirectory($Path)
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject @{ cases = $Cases } -Depth 8))
    $batch = Join-Path $PSScriptRoot 'rtl-batch.ps1'
    $arguments = @{
        Manifest = $manifestPath; Mode = $BatchMode; OutDir = $Path
        MaxAttempts = $MaxAttempts; TimeoutSeconds = $TimeoutSeconds
        CodexTimeoutSeconds = $CodexTimeoutSeconds; Model = $Model; Json = $true
    }
    if ($BatchMode -eq 'check') { $arguments['Parallelism'] = $Parallelism }
    $raw = & $batch @arguments
    $result = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($result['error'] -or $result['cases'].Count -ne $Cases.Count) {
        throw "Evaluation batch could not produce one result per case. $($result['error'])"
    }
    return $result
}

function Read-RtlEvaluationReport($Record) {
    if ($Record.reportPath) { [IO.File]::ReadAllText($Record.reportPath) | ConvertFrom-Json -AsHashtable }
}

function Test-RtlEvaluationSnapshot($Report, [string[]]$Files, [string]$Digest) {
    if (-not $Report -or -not $Report['runDirectory'] -or -not $Digest) { return $false }
    return (Get-RtlInputDigest (Join-Path $Report['runDirectory'] 'baseline') $Files) -ceq $Digest
}

function Get-RtlObservedFailure($Report) {
    if (-not $Report) { return }
    $check = $Report['initial']
    $stage = if ($check -and $check['status'] -eq 'failed') { $check['stage'] }
    elseif ($Report['stopReason'] -eq 'validation_failed' -and $Report['attempts'].Count -eq 0) {
        $check = $Report['validation']
        'validation'
    }
    if (-not $stage) { return }
    $step = switch ($stage) {
        'synthesize' { $check['synthesis'] }
        'fit' { $check['fit'] }
        'timing' { $check['timing'] }
    }
    $first = $check['firstError']
    return @{
        stage = $stage
        timedOut = [bool]$check['timedOut']
        regression = $check['failedRegression']
        reason = if ($step) { $step['reason'] }
        code = if ($first) { $first['code'] }
        message = if ($first) { $first['message'] } else { $check['diagnostic'] }
    }
}

function Test-RtlExpectedFailure($Expected, $Observed) {
    if (-not $Observed -or $Observed.timedOut) { return $false }
    foreach ($key in $Expected.Keys) {
        if ($key -ceq 'messageContains') {
            if (-not ([string]$Observed.message).Contains($Expected[$key], [StringComparison]::Ordinal)) { return $false }
        } elseif ($Expected[$key] -cne $Observed[$key]) { return $false }
    }
    return $true
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$metrics = [ordered]@{
    totalCases = 0; controlsPassed = 0; faultsAtExpectedStage = 0; repairableCases = 0
    repaired = 0; guardChecksPassed = 0; modelCalls = 0; repairRounds = 0; errors = 0; elapsedMs = 0
}
$summary = [ordered]@{
    schemaVersion = 1; mode = $Mode; manifestPath = $null; runDirectory = $null; status = 'error'
    stopReason = $null; error = $null; calibrationReport = $null; repairReport = $null
    settings = @{
        model = $Model
        maxAttempts = $MaxAttempts
        timeoutSeconds = $TimeoutSeconds
        codexTimeoutSeconds = $CodexTimeoutSeconds
        calibrationParallelism = $Parallelism
    }
    metrics = $metrics; cases = @()
}
$exitCode = 2
try {
    $summary.manifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Manifest)
    $recipes = @(Read-RtlEvaluationCases $summary.manifestPath)
    $metrics.totalCases = $recipes.Count
    $metrics.repairableCases = @($recipes | Where-Object { $_.failure.stage -ne 'validation' }).Count
    $output = if ($OutDir) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir) }
    else { Join-Path ([IO.Path]::GetDirectoryName($summary.manifestPath)) '.rtlcheck-evaluation' }
    $runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $summary.runDirectory = Join-Path $output $runId
    $inputs = Join-Path $summary.runDirectory 'inputs'
    $summary.cases = @(for ($index = 0; $index -lt $recipes.Count; $index++) {
        New-RtlEvaluationPair $recipes[$index] $inputs ($index + 1) $Mode
    })

    if (-not $Json) { Write-Host "Checking $($metrics.totalCases) healthy designs and their injected faults..." }
    $checks = @(for ($index = 0; $index -lt $summary.cases.Count; $index++) {
        $case = $summary.cases[$index]
        @{ id = "control-$index"; config = $case.controlConfig; inputSha256 = $case.controlInputSha256 }
        @{ id = "fault-$index"; config = $case.faultConfig; inputSha256 = $case.faultInputSha256 }
    })
    $calibration = Invoke-RtlEvaluationBatch $checks (Join-Path $summary.runDirectory 'calibration') 'check'
    $summary.calibrationReport = Join-Path $calibration.runDirectory 'summary.json'
    $metrics.errors = $calibration.metrics.errors
    for ($index = 0; $index -lt $summary.cases.Count; $index++) {
        $case = $summary.cases[$index]
        $case.control = $calibration.cases[2 * $index]
        $case.fault = $calibration.cases[2 * $index + 1]
        $controlReport = Read-RtlEvaluationReport $case.control
        $faultReport = Read-RtlEvaluationReport $case.fault
        $case.controlSnapshotMatched = Test-RtlEvaluationSnapshot $controlReport $case.inputFiles $case.controlInputSha256
        $case.faultSnapshotMatched = Test-RtlEvaluationSnapshot $faultReport $case.inputFiles $case.faultInputSha256
        if ($case.control.status -eq 'passed' -and $case.controlSnapshotMatched) { $metrics.controlsPassed++ }
        $case.observedFailure = Get-RtlObservedFailure $faultReport
        if ($case.fault.status -eq 'failed' -and $case.faultSnapshotMatched -and
            (Test-RtlExpectedFailure $case.expectedFailure $case.observedFailure)) {
            $metrics.faultsAtExpectedStage++
        }
    }
    if ($metrics.errors -or $metrics.controlsPassed -ne $metrics.totalCases -or $metrics.faultsAtExpectedStage -ne $metrics.totalCases) {
        $summary.stopReason = 'calibration_failed'
        if (-not $metrics.errors) { $summary.status = 'failed'; $exitCode = 1 }
    } elseif ($Mode -eq 'check') {
        $summary.status = 'passed'
        $exitCode = 0
    } else {
        foreach ($case in $summary.cases) {
            $faultRoot = [IO.Path]::GetDirectoryName($case.faultConfig)
            if ((Get-RtlInputDigest $faultRoot $case.inputFiles) -cne $case.faultInputSha256) {
                $summary.stopReason = 'fault_input_changed'
                throw "Calibrated fault input changed before repair for case '$($case.id)'."
            }
        }
        if (-not $Json) { Write-Host "Measuring repairs on $($metrics.repairableCases) calibrated faults..." }
        $repairs = @($summary.cases | ForEach-Object { @{ id = $_.id; config = $_.faultConfig; inputSha256 = $_.faultInputSha256 } })
        $measured = Invoke-RtlEvaluationBatch $repairs (Join-Path $summary.runDirectory 'repair') 'repair'
        $summary.repairReport = Join-Path $measured.runDirectory 'summary.json'
        $metrics.errors += $measured.metrics.errors
        $metrics.modelCalls = $measured.metrics.modelCalls
        $metrics.repairRounds = $measured.metrics.repairRounds
        for ($index = 0; $index -lt $summary.cases.Count; $index++) {
            $case = $summary.cases[$index]
            $case.repair = $measured.cases[$index]
            $repairReport = Read-RtlEvaluationReport $case.repair
            $case.repairSnapshotMatched = Test-RtlEvaluationSnapshot $repairReport $case.inputFiles $case.faultInputSha256
            $case.repairBaselineMatched = Test-RtlExpectedFailure $case.expectedFailure (Get-RtlObservedFailure $repairReport)
            if (-not $case.repairSnapshotMatched -or -not $case.repairBaselineMatched -or $repairReport['applied']) { continue }
            if ($case.expectedFailure.stage -eq 'validation') {
                if ($case.repair.status -eq 'failed' -and $case.repair.stopReason -eq 'validation_failed' -and $case.repair.modelCalls -eq 0) {
                    $metrics.guardChecksPassed++
                }
            } elseif ($case.repair.status -eq 'repaired' -and $repairReport['candidateFiles'].Count -gt 0) {
                $missing = @($repairReport['candidateFiles'] | Where-Object { -not [IO.File]::Exists($_.candidatePath) })
                if (-not $missing.Count) { $metrics.repaired++ }
            }
        }
        if (-not $metrics.errors) {
            $passed = $metrics.repaired + $metrics.guardChecksPassed -eq $metrics.totalCases
            $summary.status = if ($passed) { 'passed' } else { 'failed' }
            $exitCode = if ($passed) { 0 } else { 1 }
        }
    }
}
catch {
    $summary.error = $_.Exception.Message
}
$metrics.elapsedMs = $watch.ElapsedMilliseconds
$jsonReport = ConvertTo-Json -InputObject $summary -Depth 13
if ($summary.runDirectory -and [IO.Directory]::Exists($summary.runDirectory)) {
    try { [IO.File]::WriteAllText((Join-Path $summary.runDirectory 'summary.json'), $jsonReport + "`n") }
    catch {
        $summary.status = 'error'
        $summary.error = "Could not save the evaluation report. $($_.Exception.Message)"
        $exitCode = 2
        $jsonReport = ConvertTo-Json -InputObject $summary -Depth 13
    }
}
if ($Json) { Write-Output $jsonReport }
else {
    Write-Host "Evaluation $($summary.status)"
    Write-Host "Passing controls $($metrics.controlsPassed)/$($metrics.totalCases)"
    Write-Host "Calibrated faults $($metrics.faultsAtExpectedStage)/$($metrics.totalCases)"
    if ($summary.repairReport) {
        Write-Host "Verified repairs $($metrics.repaired)/$($metrics.repairableCases)"
        Write-Host "Independent guards passed $($metrics.guardChecksPassed)"
    } elseif ($Mode -eq 'repair') {
        Write-Host 'Repair measurement was skipped.'
    }
    if ($summary.error) { [Console]::Error.WriteLine($summary.error) }
    if ($summary.runDirectory) { Write-Host "Reports: $($summary.runDirectory)" }
}
exit $exitCode
