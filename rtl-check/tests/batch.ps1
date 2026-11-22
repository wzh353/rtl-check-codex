#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $toolRoot 'rtl-batch.ps1'
$fixture = Join-Path $toolRoot 'examples/counter'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-batch-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$manifest = Join-Path $root 'cases.json'

function Invoke-BatchTest([object[]]$Cases, [string]$Mode, [int]$ExpectedExit, [int]$Parallelism, [string]$Batch = $tool) {
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject @{ cases = $Cases } -Depth 5))
    $arguments = @()
    if ($PSBoundParameters.ContainsKey('Parallelism')) { $arguments += '-Parallelism', $Parallelism }
    $output = & ([Environment]::ProcessPath) -NoProfile -File $Batch -Manifest $manifest -Mode $Mode -Json @arguments
    if ($LASTEXITCODE -ne $ExpectedExit) {
        throw "Expected batch exit $ExpectedExit, got $LASTEXITCODE. $output"
    }
    return ($output -join "`n" | ConvertFrom-Json -AsHashtable)
}

try {
    $passingDir = Join-Path $root '项目 with spaces'
    $brokenDir = Join-Path $root 'broken'
    $asyncDir = Join-Path $root 'async'
    foreach ($destination in @($passingDir, $brokenDir, $asyncDir)) {
        Copy-Item -LiteralPath $fixture -Destination $destination -Recurse
    }
    $passingFile = Join-Path $passingDir 'counter.sv'
    $brokenFile = Join-Path $brokenDir 'counter.sv'
    $asyncFile = Join-Path $asyncDir 'counter.sv'
    $brokenText = [IO.File]::ReadAllText($brokenFile)
    $passingText = $brokenText.Replace("count + 8'd2", "count + 8'd1")
    [IO.File]::WriteAllText($passingFile, $passingText)
    $asyncText = $passingText.Replace('posedge clk)', 'posedge clk or negedge rst_n)')
    [IO.File]::WriteAllText($asyncFile, $asyncText)

    $passing = @{ id = 'passing'; config = '项目 with spaces/rtlcheck.json'; repairFile = 'counter.sv' }
    $broken = @{ id = 'broken'; config = 'broken/rtlcheck.json'; repairFile = 'counter.sv' }
    $missing = @{ id = 'missing'; config = 'missing/rtlcheck.json' }
    $invalidPath = @{ id = 'invalid-path'; config = "invalid$([char]0)path" }
    $stale = @{ id = 'stale'; config = $passing.config; inputSha256 = '0' * 64 }
    $async = @{ id = 'async'; config = 'async/rtlcheck.json'; repairFile = 'counter.sv' }

    $report = Invoke-BatchTest @($missing, $invalidPath, $stale, $passing, $broken) 'check' 2 -Parallelism 3
    if ($report.cases.Count -ne 5 -or ($report.cases.status -join ',') -ne 'error,error,error,passed,failed' -or
        ($report.cases.id -join ',') -cne 'missing,invalid-path,stale,passing,broken' -or
        $report.metrics.finalPassed -ne 1 -or $report.metrics.baselinePassed -ne 1 -or
        $report.metrics.errors -ne 3 -or $report.metrics.baselineEvaluated -ne 2 -or $report.metrics.modelCalls -ne 0 -or
        $report.cases[2].error -notmatch 'Input snapshot digest mismatch' -or $report.cases[2].baselineStage -or
        -not [IO.File]::Exists($report.cases[4].reportPath) -or
        -not [IO.File]::Exists($report.cases[0].stdoutPath) -or
        -not [IO.File]::Exists((Join-Path $report.runDirectory 'summary.json')) -or
        [IO.File]::ReadAllText($passingFile) -cne $passingText -or [IO.File]::ReadAllText($brokenFile) -cne $brokenText) {
        throw 'Parallel checks must preserve manifest order, isolate case errors and leave inputs intact.'
    }
    Write-Host 'PASS Parallel Icarus checks enforce snapshot digests, isolate errors and preserve manifest order'

    $report = Invoke-BatchTest @($passing, $async) 'repair' 1
    if (($report.cases.baselineStatus -join ',') -ne 'passed,failed' -or
        $report.metrics.baselinePassed -ne 1 -or $report.metrics.finalPassed -ne 1 -or
        $report.metrics.modelCalls -ne 0 -or $report.cases[1].stopReason -ne 'validation_failed' -or
        [IO.File]::ReadAllText($asyncFile) -cne $asyncText) {
        throw 'A case with a failed holdout must count as failed and stay untouched.'
    }
    Write-Host 'PASS Counts independent validation in the baseline when primary checks pass'

    $caseConfigPath = Join-Path $asyncDir 'rtlcheck.json'
    $caseConfig = Get-Content -LiteralPath $caseConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $caseConfig.regressions = @(@{
        id = 'edge-reset'
        top = $caseConfig.validation.top
        testbenches = $caseConfig.validation.testbenches
        passMarker = $caseConfig.validation.passMarker
    })
    $null = $caseConfig.Remove('validation')
    [IO.File]::WriteAllText($caseConfigPath, (ConvertTo-Json -InputObject $caseConfig -Depth 8))
    $report = Invoke-BatchTest @($passing, $async) 'check' 1
    if ($report.cases[1].baselineStatus -ne 'failed' -or $report.cases[1].baselineStage -ne 'regression' -or
        $report.cases[1].baselineFailedRegression -ne 'edge-reset' -or $report.metrics.baselinePassed -ne 1) {
        throw 'The batch must identify a failed public case and count it as a baseline failure.'
    }
    Write-Host 'PASS Reports the failing public regression in batch results'

    $report = Invoke-BatchTest @($passing, @{ id = 'PASSING'; config = 'broken/rtlcheck.json' }) 'check' 2
    if ($report.error -notmatch 'Duplicate case id' -or $report.cases.Count -ne 0) {
        throw 'Case identifiers must be unique.'
    }
    Write-Host 'PASS Rejects duplicate case IDs before starting a run'

    $report = Invoke-BatchTest @($passing, $async) 'repair' 2 -Parallelism 2
    if ($report.error -notmatch 'serial' -or $report.cases.Count -ne 0 -or $report.runDirectory) {
        throw 'Parallel repair must be rejected before starting a case.'
    }
    Write-Host 'PASS Rejects parallel repairs before starting a case'

    $stubRoot = Join-Path $root 'barrier-tool'
    $null = [IO.Directory]::CreateDirectory($stubRoot)
    Copy-Item -LiteralPath $tool -Destination $stubRoot
    Copy-Item -LiteralPath (Join-Path $toolRoot 'lib') -Destination $stubRoot -Recurse
    [IO.File]::WriteAllText((Join-Path $stubRoot 'rtl-check.ps1'), @'
param($Mode, $Config, $OutDir, $TimeoutSeconds, [switch]$Json)
$ErrorActionPreference = 'Stop'
$firstStarted = Join-Path $PSScriptRoot 'first.started'
$secondStarted = Join-Path $PSScriptRoot 'second.pid'
$id = [IO.Path]::GetFileNameWithoutExtension($Config)

function Wait-Signal([string]$Path) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($Path)) {
        if ($watch.Elapsed.TotalSeconds -ge 20) { throw "Timed out waiting for the other checker: $Path" }
        Start-Sleep -Milliseconds 25
    }
}

if ($id -eq 'first') {
    # Both checkers signal startup, then first waits for second to exit.
    [IO.File]::WriteAllText($firstStarted, '')
    Wait-Signal $secondStarted
    $secondPid = [int][IO.File]::ReadAllText($secondStarted)
    $secondProcess = Get-Process -Id $secondPid -ErrorAction SilentlyContinue
    if ($secondProcess -and -not $secondProcess.WaitForExit(20000)) { throw 'Second checker did not exit.' }
    $status = 'passed'
    $exitCode = 0
} else {
    Wait-Signal $firstStarted
    $pendingSignal = "$secondStarted.tmp"
    [IO.File]::WriteAllText($pendingSignal, $PID.ToString())
    [IO.File]::Move($pendingSignal, $secondStarted)
    $status = 'failed'
    $exitCode = 1
}
@{
    status = $status; stopReason = $null; initial = @{ status = $status; stage = 'compile' }
    validation = $null; attempts = @(); runDirectory = $null; error = $null
} | ConvertTo-Json -Compress
exit $exitCode
'@)
    $barrierCases = @(@{ id = 'first'; config = 'first.json' }, @{ id = 'second'; config = 'second.json' })
    $report = Invoke-BatchTest $barrierCases 'check' 1 -Parallelism 2 -Batch (Join-Path $stubRoot 'rtl-batch.ps1')
    if (($report.cases.id -join ',') -cne 'first,second' -or ($report.cases.status -join ',') -cne 'passed,failed') {
        throw 'The first checker must observe the second finish and both results must follow manifest order.'
    }
    Write-Host 'PASS Check processes overlap and report in manifest order despite reverse completion'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-batch-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '6 batch tests passed.'
