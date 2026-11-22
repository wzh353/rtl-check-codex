. (Join-Path $PSScriptRoot 'Check.ps1')

function Invoke-RtlBatchCase($Case, [string]$Directory, [string]$WorkingDirectory,
                             [string]$Mode, [System.Collections.IDictionary]$Options) {
    $record = [ordered]@{
        id = $Case.id
        configPath = $Case.config
        status = 'error'
        baselineStatus = $null
        baselineStage = $null
        baselineFailedRegression = $null
        validationStatus = $null
        stopReason = $null
        repairRounds = 0
        modelCalls = 0
        elapsedMs = 0
        exitCode = $null
        reportPath = $null
        stdoutPath = Join-Path $Directory 'checker.stdout.log'
        stderrPath = Join-Path $Directory 'checker.stderr.log'
        error = $null
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = [IO.Directory]::CreateDirectory($Directory)
        $record.configPath = [IO.Path]::GetFullPath($Case.config, $WorkingDirectory)
        $checker = Join-Path (Split-Path -Parent $PSScriptRoot) 'rtl-check.ps1'
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $checker, $Mode,
            '-Config', $record.configPath, '-OutDir', (Join-Path $Directory 'runs'),
            '-TimeoutSeconds', $Options.timeoutSeconds.ToString(), '-Json')
        if ($Case.inputSha256) { $arguments += @('-ExpectedInputSha256', $Case.inputSha256) }
        $rounds = if ($Mode -eq 'repair') { $Options.maxAttempts } else { 0 }
        if ($rounds) {
            $arguments += @('-MaxAttempts', $rounds.ToString(), '-CodexTimeoutSeconds', $Options.codexTimeoutSeconds.ToString())
            if ($Case.repairFile) { $arguments += @('-RepairFile', $Case.repairFile) }
            if ($Options.model) { $arguments += @('-Model', $Options.model) }
        }

        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $toolSteps = 6
        try {
            $config = [IO.File]::ReadAllText($record.configPath) | ConvertFrom-Json -AsHashtable
            if ($config -is [System.Collections.IDictionary]) {
                if ($config['regressions'] -is [array]) { $toolSteps += 3 * $config['regressions'].Count }
                if ($config['synthesis'] -is [System.Collections.IDictionary] -and $config['synthesis']['engine'] -eq 'pango') {
                    # Pango's single process has a budget for five tool stages.
                    $toolSteps += 2
                }
            }
        }
        catch {
            # The checker records the configuration error in its own report.
        }
        $seconds = 60 + (6 + $toolSteps * ($rounds + 1)) * ($Options.timeoutSeconds + 10) +
            $rounds * ($Options.codexTimeoutSeconds + 10)
        $caseTimeout = [int][Math]::Min([Math]::Floor([int]::MaxValue / 1000), $seconds)
        $process = Invoke-RtlProcess $pwsh $arguments $WorkingDirectory (Join-Path $Directory 'checker') $caseTimeout
        $record.exitCode = $process.exitCode
        if ($process.timedOut) { throw "Case runner exceeded its $caseTimeout second timeout." }

        $report = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($record.stdoutPath)) -AsHashtable
        if ($report -isnot [System.Collections.IDictionary] -or
            $report['status'] -notin @('passed', 'repaired', 'failed', 'unresolved', 'error')) {
            throw 'The checker did not return an RTL check report.'
        }
        $expectedExit = if ($report['status'] -in @('passed', 'repaired')) { 0 }
        elseif ($report['status'] -eq 'error') { 2 }
        else { 1 }
        if ($process.exitCode -ne $expectedExit) {
            throw "Checker status '$($report['status'])' did not match exit code $($process.exitCode)."
        }
        $record.status = $report['status']
        $record.stopReason = $report['stopReason']
        if ($report['initial']) {
            $record.baselineStage = $report['initial']['stage']
            $record.baselineFailedRegression = $report['initial']['failedRegression']
        }
        if ($report['validation']) { $record.validationStatus = $report['validation']['status'] }
        $record.repairRounds = @($report['attempts']).Count
        $record.modelCalls = @($report['attempts'] | Where-Object { $_['codexInvoked'] -or $_['codex'] }).Count
        if ($report['runDirectory']) {
            $path = Join-Path $report['runDirectory'] 'summary.json'
            if ([IO.File]::Exists($path)) { $record.reportPath = $path }
        }
        $record.error = $report['error']

        if ($report['initial'] -and $report['initial']['status'] -eq 'failed') {
            $record.baselineStatus = 'failed'
        } elseif ($record.status -eq 'passed') {
            $record.baselineStatus = 'passed'
        } elseif ($record.stopReason -eq 'validation_failed' -and $record.repairRounds -eq 0) {
            $record.baselineStatus = 'failed'
        }
    }
    catch {
        $record.status = 'error'
        $record.error = $_.Exception.Message
    }
    $record.elapsedMs = $watch.ElapsedMilliseconds
    return $record
}
