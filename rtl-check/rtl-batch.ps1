#requires -Version 7.2

<#
.SYNOPSIS
Checks or previews repairs for a manifest of local RTL projects.
.PARAMETER Parallelism
Maximum concurrent checker processes in check mode, from 1 to 8. Defaults to 1. Repair runs serially.
.EXAMPLE
./rtl-batch.ps1 -Manifest ./cases.json -Mode repair
#>
[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Mandatory)][string]$Manifest,
    [ValidateSet('check', 'repair')][string]$Mode = 'check',
    [ValidateRange(1, 8)][int]$Parallelism = 1,
    [ValidateRange(1, 10)][int]$MaxAttempts = 3,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 15,
    [ValidateRange(1, 3600)][int]$CodexTimeoutSeconds = 240,
    [string]$Model,
    [string]$OutDir,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$caseRunner = Join-Path $PSScriptRoot 'lib/Batch.ps1'
. $caseRunner

function Read-RtlBatchCases([string]$Path) {
    $definition = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -AsHashtable
    if ($definition -isnot [System.Collections.IDictionary] -or
        $definition['cases'] -isnot [array] -or $definition['cases'].Count -eq 0) {
        throw 'The manifest must contain a nonempty cases array.'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $definition['cases']) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['id'] -isnot [string] -or
            $item['id'] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z' -or
            $item['config'] -isnot [string] -or [string]::IsNullOrWhiteSpace($item['config'])) {
            throw 'Each case needs an id and a configuration path. Use letters, digits, dots, underscores or dashes in id.'
        }
        $id = $item['id']
        if (-not $ids.Add($id)) { throw "Duplicate case id: $id" }
        if ($item.Contains('repairFile') -and
            ($item['repairFile'] -isnot [string] -or [string]::IsNullOrWhiteSpace($item['repairFile']))) {
            throw "Case $id must provide a nonempty repairFile when set."
        }
        if ($item.Contains('inputSha256') -and
            ($item['inputSha256'] -isnot [string] -or $item['inputSha256'] -cnotmatch '\A[0-9A-Fa-f]{64}\z')) {
            throw "Case $id must provide a 64-digit hexadecimal inputSha256 when set."
        }
        @{
            id = $id
            config = $item['config']
            repairFile = $item['repairFile']
            inputSha256 = $item['inputSha256']
        }
    }
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$summary = [ordered]@{
    schemaVersion = 1
    mode = $Mode
    manifestPath = $null
    runDirectory = $null
    status = 'error'
    settings = @{
        model = $Model
        maxAttempts = $MaxAttempts
        timeoutSeconds = $TimeoutSeconds
        codexTimeoutSeconds = $CodexTimeoutSeconds
        parallelism = $Parallelism
    }
    metrics = $null
    cases = [Collections.Generic.List[object]]::new()
    error = $null
}
$exitCode = 2
try {
    if ($Mode -eq 'repair' -and $Parallelism -gt 1) {
        throw 'Batch repair runs serially. Use -Parallelism 1 in repair mode.'
    }
    $summary.manifestPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Manifest)
    $cases = @(Read-RtlBatchCases $summary.manifestPath)
    $root = [IO.Path]::GetDirectoryName($summary.manifestPath)
    $output = if ($OutDir) {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
    } else {
        Join-Path $root '.rtlcheck-batch'
    }
    $runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $summary.runDirectory = Join-Path $output $runId
    $metrics = [ordered]@{
        totalCases = $cases.Count
        baselineEvaluated = 0
        baselinePassed = 0
        finalPassed = 0
        repaired = 0
        failed = 0
        errors = 0
        repairRounds = 0
        modelCalls = 0
        elapsedMs = 0
    }
    $summary.metrics = $metrics

    $requests = @(for ($index = 0; $index -lt $cases.Count; $index++) {
        @{
            index = $index
            case = $cases[$index]
            directory = Join-Path $summary.runDirectory ('{0:D3}-{1}' -f ($index + 1), $cases[$index].id)
        }
    })
    $settings = $summary.settings
    & {
        if ($Parallelism -eq 1) {
            foreach ($request in $requests) {
                if (-not $Json) { Write-Host "Running $($request.case.id) [$($request.index + 1)/$($cases.Count)]..." }
                Invoke-RtlBatchCase $request.case $request.directory $root $Mode $settings
            }
        } else {
            if (-not $Json) { Write-Host "Checking $($cases.Count) cases with up to $Parallelism checker processes..." }
            $completed = @($requests | ForEach-Object -ThrottleLimit $Parallelism -Parallel {
                $ErrorActionPreference = 'Stop'
                Set-StrictMode -Version 3.0
                . $using:caseRunner
                @{
                    index = $_.index
                    result = Invoke-RtlBatchCase $_.case $_.directory $using:root 'check' $using:settings
                }
            })
            if ($completed.Count -ne $requests.Count) { throw 'The batch did not produce one result per case.' }
            foreach ($entry in ($completed | Sort-Object { $_.index })) { $entry.result }
        }
    } | ForEach-Object {
        $result = $_
        $summary.cases.Add($result)
        if ($result.baselineStatus) { $metrics.baselineEvaluated++ }
        if ($result.baselineStatus -eq 'passed') { $metrics.baselinePassed++ }
        if ($result.status -in @('passed', 'repaired')) { $metrics.finalPassed++ }
        if ($result.status -eq 'repaired') { $metrics.repaired++ }
        if ($result.status -in @('failed', 'unresolved')) { $metrics.failed++ }
        if ($result.status -eq 'error') { $metrics.errors++ }
        $metrics.repairRounds += $result.repairRounds
        $metrics.modelCalls += $result.modelCalls
        if (-not $Json) { Write-Host "$($result.id) $($result.status) ($($result.elapsedMs) ms)" }
    }
    $metrics.elapsedMs = $watch.ElapsedMilliseconds
    if ($metrics.errors) {
        $summary.status = 'error'
    } elseif ($metrics.failed) {
        $summary.status = 'failed'
        $exitCode = 1
    } else {
        $summary.status = 'passed'
        $exitCode = 0
    }
}
catch {
    $summary.error = $_.Exception.Message
}

$report = ConvertTo-Json -InputObject $summary -Depth 8
if ($summary.runDirectory -and [IO.Directory]::Exists($summary.runDirectory)) {
    try { [IO.File]::WriteAllText((Join-Path $summary.runDirectory 'summary.json'), $report + "`n") }
    catch {
        $summary.status = 'error'
        $summary.error = "Could not save the batch report. $($_.Exception.Message)"
        $exitCode = 2
        $report = ConvertTo-Json -InputObject $summary -Depth 8
    }
}
if ($Json) {
    Write-Output $report
} else {
    if ($summary.metrics) {
        $metrics = $summary.metrics
        Write-Host "Baseline $($metrics.baselinePassed)/$($metrics.baselineEvaluated), final $($metrics.finalPassed)/$($metrics.totalCases), repaired $($metrics.repaired), errors $($metrics.errors)"
    }
    if ($summary.error) { [Console]::Error.WriteLine($summary.error) }
    if ($summary.runDirectory) { Write-Host "Report: $(Join-Path $summary.runDirectory 'summary.json')" }
}
exit $exitCode
