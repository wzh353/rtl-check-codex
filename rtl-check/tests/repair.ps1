#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'lib/Check.ps1')
. (Join-Path $toolRoot 'lib/Repair.ps1')

function Assert-Throws([string]$Pattern, [scriptblock]$Action) {
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw
    }
    throw "Expected an error matching '$Pattern'."
}

function Test-ConcurrentPublication($Project, [string]$Snapshot, [string]$LibraryDirectory) {
    $reached = [Threading.ManualResetEventSlim]::new()
    $resume = [Threading.ManualResetEventSlim]::new()
    $jobs = @()
    $writer = {
        param($Library, $Design, $Baseline, $Target, $Reached, $Resume)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $Library 'Check.ps1')
        . (Join-Path $Library 'Repair.ps1')
        if ($Reached) {
            function Get-FileHash([string]$LiteralPath) {
                $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath
                if ($LiteralPath -eq (Join-Path $Baseline 'auxiliary.sv')) {
                    $Reached.Set()
                    if (-not $Resume.Wait(8000)) { throw 'First writer did not resume.' }
                }
                return $hash
            }
        }
        try {
            Publish-RtlRepair $Design $Baseline ([ordered]@{ $Target = [Text.Encoding]::UTF8.GetBytes('replacement') })
            'applied'
        }
        catch {
            if ($_.Exception.Message -notmatch 'changed since the baseline') { throw }
            'stale'
        }
    }
    try {
        $jobs += Start-ThreadJob -ScriptBlock $writer -ArgumentList @($LibraryDirectory, $Project, $Snapshot, 'counter.sv', $reached, $resume)
        if (-not $reached.Wait(5000)) { throw 'First writer did not reach the final hash check.' }
        $jobs += Start-ThreadJob -ScriptBlock $writer -ArgumentList @($LibraryDirectory, $Project, $Snapshot, 'auxiliary.sv', $null, $null)
        $null = Wait-Job -Job $jobs[1] -Timeout 1
        $resume.Set()
        $null = Wait-Job -Job $jobs -Timeout 8
        $first = Receive-Job -Job $jobs[0]
        $second = Receive-Job -Job $jobs[1]
        if ($first -ne 'applied' -or $second -ne 'stale') {
            throw "Expected one successful writer and one stale writer. Results: $first, $second"
        }
    }
    finally {
        $resume.Set()
        if ($jobs.Count) { Remove-Job -Job $jobs -Force }
        $reached.Dispose()
        $resume.Dispose()
    }
}

function Test-RepairLoop($Project, [string]$Snapshot, [string]$RunDirectory, [object[]]$Proposals,
                         [string[]]$Targets = @('counter.sv'), [switch]$Preview, $InitialCheck) {
    # Replace only the model process. Compilation and both simulation suites use Icarus.
    $realProcess = (Get-Item -LiteralPath 'Function:Invoke-RtlProcess').ScriptBlock
    $compiler = Find-RtlExecutable 'iverilog'
    $simulator = Find-RtlExecutable 'vvp'
    function Find-RtlExecutable([string]$Name) {
        if ($Name -ne 'codex') { throw "Unexpected executable lookup: $Name" }
        return 'test-codex'
    }
    function Write-RtlProgress([string]$Message) {}
    $responses = [Collections.Generic.Queue[object]]::new()
    foreach ($proposal in $Proposals) { $responses.Enqueue($proposal) }
    function Invoke-RtlProcess([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory,
                               [string]$LogPrefix, [int]$TimeoutSeconds, [string]$InputText = '') {
        if ($Executable -ne 'test-codex') { return & $realProcess @PSBoundParameters }
        if ($InputText.Contains('independent reset check') -or
            [IO.File]::Exists((Join-Path $WorkingDirectory 'counter_validation_tb.sv'))) {
            throw 'Independent validation leaked into a Codex repair attempt.'
        }
        if ($responses.Count -eq 0) { throw 'The repair flow requested an additional Codex call.' }
        $responsePath = $Arguments[[array]::IndexOf($Arguments, '--output-last-message') + 1]
        $result = $responses.Dequeue()
        if ($result -is [scriptblock]) { $result = & $result $WorkingDirectory $InputText }
        [IO.File]::WriteAllText($responsePath, (ConvertTo-Json -InputObject $result -Depth 5))
        return @{ timedOut = $false; exitCode = 0 }
    }

    $summary = @{
        status = 'failed'
        stopReason = $null
        initial = if ($InitialCheck) { $InitialCheck } else {
            @{ stage = 'simulate'; diagnostic = 'Simulation failed: cycle=3 expected=1 actual=2' }
        }
        validation = $null
        runDirectory = $RunDirectory
        attempts = [Collections.Generic.List[object]]::new()
        applied = $false
        candidatePath = $null
        candidateFiles = @()
        error = $null
    }
    $schema = Join-Path $toolRoot 'repair-response.schema.json'
    $requested = if ($Targets.Count -eq 1) { $Targets[0] } else { $Targets }
    try {
        Invoke-RtlRepair $Project $summary $Snapshot $requested $compiler $simulator $schema 15 2 3 '' -Apply:(-not $Preview)
    }
    catch {
        $summary.status = 'error'
        $summary.error = $_.Exception.Message
    }
    return $summary
}

function Invoke-PreviewApply([string]$Config, [string]$PreviewReport, [int]$ExpectedExit) {
    $cli = Join-Path $toolRoot 'rtl-check.ps1'
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $cli apply -Config $Config -PreviewReport $PreviewReport -Json
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne $ExpectedExit) { throw "Expected preview apply exit $ExpectedExit, got $exitCode. $raw" }
    return ($raw -join "`n" | ConvertFrom-Json -AsHashtable)
}

function Test-SnapshotDuringPublication([string]$Directory) {
    $null = [IO.Directory]::CreateDirectory($Directory)
    $config = Join-Path $Directory 'rtlcheck.json'
    $design = Join-Path $Directory 'design.sv'
    $term = Join-Path $Directory 'term.sv'
    $checks = Join-Path $Directory 'checks'
    [IO.File]::WriteAllText($config, '{"top":"sum_tb","sources":["design.sv","term.sv"],"testbenches":["sum_tb.sv"]}')
    [IO.File]::WriteAllText($design, "module sum_design(output wire [7:0] total); wire [7:0] term; term_value u_term(term); assign total = term + 8'd1; endmodule")
    [IO.File]::WriteAllText($term, "module term_value(output wire [7:0] term); assign term = 8'd2; endmodule")
    [IO.File]::WriteAllText((Join-Path $Directory 'sum_tb.sv'), @'
module sum_tb;
    wire [7:0] total;
    sum_design uut(total);
    initial begin
        #1;
        if (total !== 8'd3) $fatal(1, "mixed revisions: expected 3, observed %0d", total);
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule
'@)
    $mutex = [Threading.Mutex]::new($false, 'local-rtl-check-publication')
    $owned = $false
    $readerJob = $null
    try {
        try { $owned = $mutex.WaitOne(10000) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Could not acquire the publication lock for the test.' }

        $updated = [IO.File]::ReadAllText($design).Replace("term + 8'd1", "term + 8'd2")
        [IO.File]::WriteAllText($design, $updated)
        $readerJob = Start-ThreadJob -ArgumentList @((Join-Path $toolRoot 'rtl-check.ps1'), $config, $checks) -ScriptBlock {
            param($Tool, $Config, $OutDir)
            $raw = & ([Environment]::ProcessPath) -NoProfile -File $Tool check -Config $Config -OutDir $OutDir -Json
            $code = $LASTEXITCODE
            @{ code = $code; report = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable }
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.Directory]::Exists($checks) -and $watch.ElapsedMilliseconds -lt 8000) {
            if ($readerJob.State -in @('Completed', 'Failed', 'Stopped')) { break }
            Start-Sleep -Milliseconds 25
        }
        if (-not [IO.Directory]::Exists($checks)) { throw 'The checker did not start the snapshot.' }
        $null = Wait-Job -Job $readerJob -Timeout 2
        [IO.File]::WriteAllText($term, "module term_value(output wire [7:0] term); assign term = 8'd1; endmodule")
        $mutex.ReleaseMutex()
        $owned = $false

        if (-not (Wait-Job -Job $readerJob -Timeout 10)) { throw 'The checker did not finish after publication.' }
        $observed = Receive-Job -Job $readerJob
        if ($observed.code -ne 0 -or $observed.report.status -ne 'passed') {
            throw "The checker read mixed RTL revisions. $($observed.report.initial.diagnostic)"
        }
        $snapshot = Join-Path $observed.report.runDirectory 'baseline'
        if ([IO.File]::ReadAllText((Join-Path $snapshot 'design.sv')) -cne [IO.File]::ReadAllText($design) -or
            [IO.File]::ReadAllText((Join-Path $snapshot 'term.sv')) -cne [IO.File]::ReadAllText($term)) {
            throw 'The snapshot must contain both published source files.'
        }
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        if ($readerJob) { Remove-Job -Job $readerJob -Force }
    }
}

$before = "always_ff @(posedge clk) begin`r`n    count <= count + 8'd2;`r`nend`r`n"
$edits = @(@{ before = "begin`n    count <= count + 8'd2;"; after = "begin`n    count <= count + 8'd1;" })
$after = Update-RtlText $before $edits
if ($after -cne "always_ff @(posedge clk) begin`r`n    count <= count + 8'd1;`r`nend`r`n") {
    throw 'The edit must preserve CRLF and surrounding text.'
}
Write-Host 'PASS Applies the exact edit while preserving CRLF'

$mixed = "keep CRLF`r`nstart`n    old`nfinish`n"
$mixedResult = Update-RtlText $mixed @(@{ before = "start`n    old"; after = "start`n    new" })
if ($mixedResult -cne "keep CRLF`r`nstart`n    new`nfinish`n") {
    throw 'The edit must keep the matched region and surrounding line endings.'
}
Write-Host 'PASS Preserves an LF edit in a mixed-line-ending file'

Assert-Throws 'matches more than once' { Update-RtlText ($before + $before) $edits }
Write-Host 'PASS Rejects an ambiguous match'

Assert-Throws 'was not found' { Update-RtlText "module counter;`nendmodule`n" $edits }
Write-Host 'PASS Rejects stale match text'

Assert-Throws 'success marker' { Assert-RtlCandidate 'module counter;' 'module counter; "RTL_CHECK_PASS"' 'RTL_CHECK_PASS' }
Assert-Throws 'simulation termination' { Assert-RtlCandidate 'module counter;' 'module counter; $stop;' 'RTL_CHECK_PASS' }
Write-Host 'PASS Rejects added simulation termination or success marker text'

$fixture = Join-Path $toolRoot 'examples/counter'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-repair-tests-$([guid]::NewGuid().ToString('N'))"
$original = Join-Path $root 'original'
$baseline = Join-Path $root 'baseline'
$null = [IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath $fixture -Destination $original -Recurse
try {
    $project = Read-RtlProject (Join-Path $original 'rtlcheck.json')
    Copy-RtlInputs $project $original $baseline -WithValidation
    $source = Join-Path $original 'counter.sv'
    $bench = Join-Path $original 'counter_tb.sv'
    $sourceText = [IO.File]::ReadAllText($source)
    $benchText = [IO.File]::ReadAllText($bench)
    $fixedText = $sourceText.Replace("count + 8'd2", "count + 8'd1")
    $candidateBytes = [Text.Encoding]::UTF8.GetBytes($fixedText)
    $singleCandidate = [ordered]@{ 'counter.sv' = $candidateBytes }

    $noFix = Test-RepairLoop $project $baseline (Join-Path $root 'no-fix') @(
        @{ explanation = 'The selected file needs no change.'; edits = @() }
    )
    if ($noFix.status -ne 'unresolved' -or $noFix.stopReason -ne 'no_edits' -or
        $noFix.attempts.Count -ne 1 -or $noFix.applied) {
        throw 'An explicit no-edit result must stop repair without using another model call.'
    }
    Write-Host 'PASS Stops when Codex reports no applicable edit'

    $transport = Test-RepairLoop $project $baseline (Join-Path $root 'codex-process-error') @(
        { throw 'Could not collect output from Codex.' }
    ) -Preview
    if ($transport.status -ne 'error' -or $transport.attempts[0].status -ne 'codex_error' -or
        -not $transport.attempts[0].codexInvoked -or $transport.applied) {
        throw 'The report must count a Codex invocation when process collection fails.'
    }
    Write-Host 'PASS Records an attempted Codex call when process collection fails'

    $repeated = Test-RepairLoop $project $baseline (Join-Path $root 'repeat') @(
        @{ explanation = 'Try 3'; edits = @(@{ before = "count + 8'd2"; after = "count + 8'd3" }) },
        @{ explanation = 'Try the first design again'; edits = @(@{ before = "count + 8'd3"; after = "count + 8'd2" }) },
        @{ explanation = 'Correct increment'; edits = @(@{ before = "count + 8'd3"; after = "count + 8'd1" }) }
    )
    if ($repeated.status -ne 'repaired' -or -not $repeated.applied -or
        $repeated.attempts[1].status -ne 'repeated_candidate' -or $repeated.attempts[1].check -or
        ([IO.File]::ReadAllText($source)) -cne $fixedText) {
        throw 'A repeated candidate must be skipped without losing the last tested RTL.'
    }
    [IO.File]::WriteAllText($source, $sourceText)
    Write-Host 'PASS Skips previously tested candidates'

    $recovered = Test-RepairLoop $project $baseline (Join-Path $root 'compile-regression') @(
        @{ explanation = 'Still fails the simulation'; edits = @(@{ before = "count + 8'd2"; after = "count + 8'd3" }) },
        @{ explanation = 'Introduces a compile failure'; edits = @(@{ before = "count + 8'd3"; after = 'count +' }) },
        {
            param($Work, $Prompt)
            $current = [IO.File]::ReadAllText((Join-Path $Work 'counter.sv'))
            if ($current -cne $sourceText.Replace("count + 8'd2", "count + 8'd3") -or
                $Prompt -notmatch '"rejectedCandidate"\s*:\s*\{' -or
                $Prompt -notmatch 'syntax error') {
                throw 'The retry must use the last compilable sources and identify the rejected compile error.'
            }
            @{ explanation = 'Fix the increment'; edits = @(@{ before = "count + 8'd3"; after = "count + 8'd1" }) }
        }
    ) -Preview
    if ($recovered.status -ne 'repaired' -or $recovered.attempts[1].status -ne 'regressed' -or
        $recovered.attempts[1].check.stage -ne 'compile' -or $recovered.attempts[2].baseRound -ne 1 -or
        [IO.File]::ReadAllText($source) -cne $sourceText) {
        throw 'A compile regression must be recorded without advancing the repair base.'
    }
    Write-Host 'PASS Retries a compile regression from the last compilable sources'

    $suiteProject = Join-Path $root 'case-project'
    Copy-Item -LiteralPath $fixture -Destination $suiteProject -Recurse
    $suiteConfigPath = Join-Path $suiteProject 'rtlcheck.json'
    $caseConfig = Get-Content -LiteralPath $suiteConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $caseConfig.top = 'counter'
    $null = $caseConfig.Remove('testbenches')
    $caseConfig.regressions = @(
        @{ id = 'counting'; top = 'counter_tb'; testbenches = @('counter_tb.sv') },
        @{ id = 'edge-reset'; top = 'reset_case_tb'; testbenches = @('reset_case_tb.sv')
            passMarker = $caseConfig.validation.passMarker }
    )
    $caseConfig.validation.defines = @('PRIVATE_RESET_SEED=794021')
    [IO.File]::WriteAllText($suiteConfigPath, (ConvertTo-Json -InputObject $caseConfig -Depth 8))
    $publicResetText = [IO.File]::ReadAllText((Join-Path $suiteProject 'counter_validation_tb.sv')).
        Replace('counter_validation_tb', 'reset_case_tb').Replace('independent reset check', 'public edge reset')
    [IO.File]::WriteAllText((Join-Path $suiteProject 'reset_case_tb.sv'), $publicResetText)
    $baseWithAsyncReset = $fixedText.Replace('posedge clk)', 'posedge clk or negedge rst_n)')
    [IO.File]::WriteAllText((Join-Path $suiteProject 'counter.sv'), $baseWithAsyncReset)
    $withCases = Read-RtlProject $suiteConfigPath
    $caseSnapshot = Join-Path $root 'case-inputs'
    $caseLogs = Join-Path $root 'case-initial'
    $caseWork = Join-Path $caseLogs 'work'
    Copy-RtlInputs $withCases $suiteProject $caseSnapshot -WithValidation
    Copy-RtlInputs $withCases $caseSnapshot $caseWork
    function Write-RtlProgress([string]$Message) {}
    $caseInitial = Invoke-RtlCheck $withCases $caseWork $caseLogs (Find-RtlExecutable 'iverilog') (Find-RtlExecutable 'vvp') 15 $caseSnapshot
    if ($caseInitial.failedRegression -ne 'edge-reset' -or $caseInitial.regressionsPassed -ne 1) {
        throw 'The base case must pass counting and fail the public reset test.'
    }
    $caseRepair = Test-RepairLoop $withCases $caseSnapshot (Join-Path $root 'ordered-regression') @(
        {
            param($Work, $Prompt)
            $contextConfig = [IO.File]::ReadAllText((Join-Path $Work 'rtlcheck.json'))
            if (-not [IO.File]::Exists((Join-Path $Work 'reset_case_tb.sv')) -or $Prompt -notmatch 'public edge reset' -or
                $Prompt -notmatch '"failedRegression"\s*:\s*"edge-reset"' -or $contextConfig -match 'PRIVATE_RESET_SEED|counter_validation_tb') {
                throw 'The prompt must describe the active public failure, with its input staged.'
            }
            @{ explanation = 'Fix reset but break the increment'; edits = @(
                @{ before = 'posedge clk or negedge rst_n)'; after = 'posedge clk)' },
                @{ before = "count + 8'd1"; after = "count + 8'd2" }
            ) }
        },
        {
            param($Work, $Prompt)
            if ([IO.File]::ReadAllText((Join-Path $Work 'counter.sv')) -cne $baseWithAsyncReset -or
                $Prompt -notmatch '"regression"\s*:\s*"counting"' -or $Prompt -notmatch 'public edge reset') {
                throw 'The retry must retain the counting-pass revision and identify the rejected earlier failure.'
            }
            @{ explanation = 'Fix reset only'; edits = @(@{ before = 'posedge clk or negedge rst_n)'; after = 'posedge clk)' }) }
        }
    ) -Preview -InitialCheck $caseInitial
    if ($caseRepair.status -ne 'repaired' -or $caseRepair.attempts[0].status -ne 'regressed' -or
        $caseRepair.attempts[0].check.failedRegression -ne 'counting' -or $caseRepair.attempts[1].baseRound -ne 0 -or
        $caseRepair.attempts[1].check.regressionsPassed -ne 2 -or $caseRepair.validation.status -ne 'passed' -or
        $caseRepair.validation.compile.arguments -notcontains '-DPRIVATE_RESET_SEED=794021' -or
        [IO.File]::ReadAllText((Join-Path $suiteProject 'counter.sv')) -cne $baseWithAsyncReset) {
        throw 'An earlier-case regression must preserve the base and a working candidate must pass private validation.'
    }
    Write-Host 'PASS Keeps the last revision that passed earlier public regression cases'

    $unverified = Test-RepairLoop $project $baseline (Join-Path $root 'holdout') @(
        @{
            explanation = 'Change increment and reset'
            edits = @(
                @{ before = "count + 8'd2"; after = "count + 8'd1" },
                @{ before = 'posedge clk)'; after = 'posedge clk or negedge rst_n)' }
            )
        }
    )
    if ($unverified.status -ne 'unresolved' -or $unverified.stopReason -ne 'validation_failed' -or
        $unverified.attempts.Count -ne 1 -or $unverified.attempts[0].check.status -ne 'passed' -or
        $unverified.validation.status -ne 'failed' -or $unverified.applied -or $unverified.candidatePath -or
        ([IO.File]::ReadAllText($source)) -cne $sourceText) {
        throw 'A failure on the independent suite must block publication without another model call.'
    }
    Write-Host 'PASS Keeps independent tests out of repair and rejects an unverified candidate'

    $prompt = New-RtlRepairPrompt $project 'counter.sv' $baseline 'expected=1 actual=2'
    if ($prompt -notmatch 'regardless of en' -or $prompt -notmatch 'expected_count') {
        throw 'The repair context must include the staged specification and testbench.'
    }
    Write-Host 'PASS Includes the spec and testbench in Codex context'

    $longWork = Join-Path $root 'long-context'
    Copy-RtlInputs $project $baseline $longWork
    $detail = 'assign faraway_counter_error = ;'
    $padding = ("// padding before the counter source used to exercise context selection`n" * 1000)
    [IO.File]::WriteAllText((Join-Path $longWork 'counter.sv'),
        $padding + $sourceText.Replace('endmodule', "$detail`nendmodule"))
    $longCheck = Invoke-RtlCheck $project $longWork $longWork (Find-RtlExecutable 'iverilog') '' 15
    if ($longCheck.stage -ne 'compile' -or $longCheck.firstError.line -le 1000) {
        throw "Expected a real compiler failure below the prompt's long-file cut-off."
    }
    $longPrompt = New-RtlRepairPrompt $project 'counter.sv' $longWork $longCheck.diagnostic $longCheck.firstError
    if (-not $longCheck.firstError.compilerHint -or -not $longPrompt.Contains($longCheck.firstError.compilerHint.inspection)) {
        throw 'The repair prompt must carry the inspection corresponding to the actual Icarus error.'
    }
    if ($longPrompt -cnotmatch [regex]::Escape($detail) -or $longPrompt -notmatch '"startLine"') {
        throw 'The prompt must include the code around the reported source line.'
    }
    Write-Host 'PASS Includes a distant compiler-error excerpt in the model context'

    $includeProject = $project.Clone()
    $includeProject.SupportFiles = @($project.SupportFiles) + 'width.inc'
    [IO.File]::WriteAllText((Join-Path $longWork 'width.inc'), 'assign broken_include = ;')
    [IO.File]::WriteAllText((Join-Path $longWork 'counter.sv'),
        $sourceText.Replace('endmodule', ('`include "width.inc"' + "`nendmodule")))
    $includeCheck = Invoke-RtlCheck $includeProject $longWork $longWork (Find-RtlExecutable 'iverilog') '' 15
    $includePrompt = New-RtlRepairPrompt $includeProject 'counter.sv' $longWork $includeCheck.diagnostic $includeCheck.firstError
    if ($includeCheck.firstError.inputFile -ne 'width.inc' -or $includePrompt -notmatch 'assign broken_include = ;') {
        throw 'A declared include reported by Icarus must appear in the error excerpt.'
    }
    Write-Host 'PASS Includes diagnostics from a declared .inc file'

    $pairedRoot = Join-Path $root 'paired'
    $pairedBaseline = Join-Path $root 'paired-baseline'
    Copy-Item -LiteralPath $fixture -Destination $pairedRoot -Recurse
    $pairedConfig = Join-Path $pairedRoot 'rtlcheck.json'
    $pairedManifest = Get-Content -LiteralPath $pairedConfig -Raw | ConvertFrom-Json -AsHashtable
    $pairedManifest.sources = @('counter.sv', 'step_value.sv')
    $pairedManifest.repairFiles = $pairedManifest.sources
    [IO.File]::WriteAllText($pairedConfig, (ConvertTo-Json -InputObject $pairedManifest -Depth 5))
    $pairedCounter = Join-Path $pairedRoot 'counter.sv'
    $pairedStep = Join-Path $pairedRoot 'step_value.sv'
    $badCounter = $sourceText.Replace('    always_ff', "    wire [7:0] step;`n    step_value increment(.value(step));`n    always_ff").
        Replace('else if (en)', 'else if (!en)').Replace("count + 8'd2", 'count + step')
    $badStep = "module step_value(output wire [7:0] value); assign value = 8'd2; endmodule`n"
    [IO.File]::WriteAllText($pairedCounter, $badCounter)
    [IO.File]::WriteAllText($pairedStep, $badStep)
    $pairedProject = Read-RtlProject $pairedConfig
    $pairedTargets = @(Get-RtlRepairTargets $pairedProject '')
    if (($pairedTargets -join ',') -ne 'counter.sv,step_value.sv') { throw 'Expected two configured repair targets.' }
    Copy-RtlInputs $pairedProject $pairedRoot $pairedBaseline -WithValidation
    $bothEdits = @(
        @{ path = 'counter.sv'; before = 'else if (!en)'; after = 'else if (en)' },
        @{ path = 'step_value.sv'; before = "value = 8'd2"; after = "value = 8'd1" }
    )
    $preview = Test-RepairLoop $pairedProject $pairedBaseline (Join-Path $root 'paired-preview') @(
        @{ explanation = 'Fix both files'; edits = $bothEdits }
    ) -Targets $pairedTargets -Preview
    if ($preview.status -ne 'repaired' -or $preview.applied -or $preview.candidateFiles.Count -ne 2 -or
        @($preview.candidateFiles | Where-Object { -not (Test-Path -LiteralPath $_.candidatePath) }).Count -gt 0 -or
        [IO.File]::ReadAllText($pairedCounter) -cne $badCounter -or [IO.File]::ReadAllText($pairedStep) -cne $badStep) {
        throw 'Preview must save both verified candidates and leave the project files intact.'
    }
    Write-Host 'PASS Previews the verified set without writing project files'

    $preview.mode = 'repair'
    $preview.configPath = $pairedConfig
    $preview.repairFiles = $pairedTargets
    $preview.inputSha256 = Get-RtlInputDigest $pairedBaseline @(Get-RtlBaselineFiles $pairedProject)
    $previewReport = Join-Path $preview.runDirectory 'summary.json'
    [IO.File]::WriteAllText($previewReport, (ConvertTo-Json -InputObject $preview -Depth 12))

    $pairedBench = Join-Path $pairedRoot 'counter_tb.sv'
    $originalBenchBytes = [IO.File]::ReadAllBytes($pairedBench)
    try {
        [IO.File]::AppendAllText($pairedBench, [Environment]::NewLine + '// Saved after preview')
        $stale = Invoke-PreviewApply $pairedConfig $previewReport 2
        if ($stale.error -notmatch 'inputs have changed' -or $stale.initial -or $stale.applied -or
            [IO.File]::ReadAllText($pairedCounter) -cne $badCounter -or [IO.File]::ReadAllText($pairedStep) -cne $badStep) {
            throw 'A change to a fixed testbench must stop preview application before running checks or writing files.'
        }
    }
    finally { [IO.File]::WriteAllBytes($pairedBench, $originalBenchBytes) }
    Write-Host 'PASS Stops preview application after a protected project input changes'

    $savedPath = $preview.candidateFiles[0].candidatePath
    $savedBytes = [IO.File]::ReadAllBytes($savedPath)
    try {
        [IO.File]::AppendAllText($savedPath, [Environment]::NewLine + '// Changed preview artifact')
        $modified = Invoke-PreviewApply $pairedConfig $previewReport 2
        if ($modified.error -notmatch 'Candidate digest mismatch' -or $modified.initial -or $modified.applied -or
            [IO.File]::ReadAllText($pairedCounter) -cne $badCounter -or [IO.File]::ReadAllText($pairedStep) -cne $badStep) {
            throw 'Changed candidate bytes must be rejected even if the modified HDL would pass.'
        }
    }
    finally { [IO.File]::WriteAllBytes($savedPath, $savedBytes) }
    Write-Host 'PASS Rejects a modified preview artifact before checking it'

    $appliedPreview = Invoke-PreviewApply $pairedConfig $previewReport 0
    if ($appliedPreview.mode -ne 'apply' -or $appliedPreview.previewReport -ne $previewReport -or
        $appliedPreview.status -ne 'repaired' -or -not $appliedPreview.applied -or $appliedPreview.attempts.Count -ne 0 -or
        $appliedPreview.initial.simulate.exitCode -ne 0 -or $appliedPreview.validation.status -ne 'passed' -or
        $appliedPreview.candidateFiles.Count -ne 2 -or
        [IO.File]::ReadAllText($pairedCounter) -notmatch 'else if \(en\)' -or
        [IO.File]::ReadAllText($pairedStep) -notmatch "value = 8'd1") {
        throw 'Preview application must recheck the exact pair before guarded publication without invoking the model.'
    }
    Write-Host 'PASS Rechecks and applies a verified two-file preview without a model call'
    [IO.File]::WriteAllText($pairedCounter, $badCounter)
    [IO.File]::WriteAllText($pairedStep, $badStep)

    $cancellation = Join-Path $root 'cancel-request'
    $previousCancellation = $env:RTL_CHECK_CANCEL_FILE
    try {
        $env:RTL_CHECK_CANCEL_FILE = $cancellation
        [IO.File]::WriteAllText($cancellation, '')
        $filesToPublish = [ordered]@{}
        foreach ($candidate in $preview.candidateFiles) {
            $filesToPublish[$candidate.path] = [IO.File]::ReadAllBytes($candidate.candidatePath)
        }
        Assert-Throws 'cancelled before publication' { Publish-RtlRepair $pairedProject $pairedBaseline $filesToPublish }
        if ([IO.File]::ReadAllText($pairedCounter) -cne $badCounter -or [IO.File]::ReadAllText($pairedStep) -cne $badStep) {
            throw 'A request cancelled before publication must leave both files intact.'
        }
    }
    finally {
        $env:RTL_CHECK_CANCEL_FILE = $previousCancellation
        [IO.File]::Delete($cancellation)
    }
    Write-Host 'PASS Keeps both RTL files after cancellation before publication'

    $pairedRun = Test-RepairLoop $pairedProject $pairedBaseline (Join-Path $root 'paired-apply') @(
        @{ explanation = 'Fix the enable condition and the increment value'; edits = $bothEdits }
    ) -Targets $pairedTargets
    if ($pairedRun.status -ne 'repaired' -or -not $pairedRun.applied -or $pairedRun.candidateFiles.Count -ne 2 -or
        $pairedRun.validation.status -ne 'passed' -or
        [IO.File]::ReadAllText($pairedCounter) -notmatch 'else if \(en\)' -or
        [IO.File]::ReadAllText($pairedStep) -notmatch "value = 8'd1") {
        throw 'Both repaired RTL files must pass together before publication.'
    }
    Write-Host 'PASS Tests and applies two RTL source changes together'

    [IO.File]::WriteAllText($pairedCounter, $badCounter)
    [IO.File]::WriteAllText($pairedStep, $badStep)
    $outside = Test-RepairLoop $pairedProject $pairedBaseline (Join-Path $root 'paired-outside') @(
        @{ explanation = 'The second edit is outside scope'; edits = @(
            $bothEdits[0],
            @{ path = 'counter_tb.sv'; before = 'counter_tb'; after = 'other' }
        ) },
        @{ explanation = 'No applicable change'; edits = @() }
    ) -Targets $pairedTargets
    if ($outside.applied -or $outside.attempts[0].status -ne 'invalid_proposal' -or $outside.attempts[0].check -or
        [IO.File]::ReadAllText($pairedCounter) -cne $badCounter) {
        throw 'One out-of-scope edit must reject the complete proposal.'
    }
    Write-Host 'PASS Rejects a mixed proposal when one file is outside the repair scope'

    if ($IsWindows) {
        $pairedCandidate = [ordered]@{
            'counter.sv' = [Text.Encoding]::UTF8.GetBytes($badCounter.Replace('else if (!en)', 'else if (en)'))
            'step_value.sv' = [Text.Encoding]::UTF8.GetBytes($badStep.Replace("8'd2", "8'd1"))
        }
        $locked = [IO.File]::Open($pairedStep, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Assert-Throws 'replaced|process|lock|denied|使用|拒绝' {
                Publish-RtlRepair $pairedProject $pairedBaseline $pairedCandidate
            }
        }
        finally { $locked.Dispose() }
        if ([IO.File]::ReadAllText($pairedCounter) -cne $badCounter -or [IO.File]::ReadAllText($pairedStep) -cne $badStep) {
            throw 'A failed second replacement must restore the first file.'
        }
        Write-Host 'PASS Rolls back an earlier file when the second write is blocked'

        $rollbackSave = "$badCounter`n// saved by the editor while rolling back"
        $locked = [IO.File]::Open($pairedStep, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            & {
                function Get-FileHash([string]$LiteralPath) {
                    $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath
                    if ($LiteralPath -eq $pairedCounter -and [IO.File]::ReadAllText($pairedCounter) -match 'else if \(en\)') {
                        [IO.File]::WriteAllText($pairedCounter, $rollbackSave)
                    }
                    return $hash
                }
                Assert-Throws 'Editor save during rollback' { Publish-RtlRepair $pairedProject $pairedBaseline $pairedCandidate }
            }
        }
        finally { $locked.Dispose() }
        $preservedSave = @(Get-ChildItem -LiteralPath $pairedRoot -File -Force |
            Where-Object { $_.Name -like '.rtl-check-*.newer.bak' -and [IO.File]::ReadAllText($_.FullName) -ceq $rollbackSave })
        if ($preservedSave.Count -ne 1) { throw 'The rollback must preserve the editor save.' }
        Write-Host 'PASS Preserves a newer editor save during rollback'
    }

    $continuingProcess = Invoke-RtlProcess ([Environment]::ProcessPath) `
        @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 4') `
        $root (Join-Path $root 'slow-process') 1 ('x' * 262144)
    if (-not $continuingProcess.timedOut) { throw 'The timeout must also bound a blocked stdin write.' }
    Write-Host 'PASS Bounds a child process that does not read stdin'

    [IO.File]::AppendAllText($bench, "`n// Concurrent edit`n")
    Assert-Throws 'changed since the baseline' { Publish-RtlRepair $project $baseline $singleCandidate }
    if ([IO.File]::ReadAllText($source) -cne $sourceText) { throw 'A stale run overwrote the source.' }
    Write-Host 'PASS Refuses to apply after an input changes'

    [IO.File]::WriteAllText($bench, $benchText)
    $validationBench = Join-Path $original 'counter_validation_tb.sv'
    $validationText = [IO.File]::ReadAllText($validationBench)
    [IO.File]::AppendAllText($validationBench, "`n// Concurrent validation edit`n")
    Assert-Throws 'changed since the baseline: counter_validation_tb.sv' {
        Publish-RtlRepair $project $baseline $singleCandidate
    }
    [IO.File]::WriteAllText($validationBench, $validationText)
    Write-Host 'PASS Refuses to publish after an independent test changes'

    $editorText = "$sourceText`n// saved while checking another input"
    & {
        function Get-FileHash([string]$LiteralPath) {
            $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath
            if ($LiteralPath -eq (Join-Path $baseline 'spec.txt')) {
                [IO.File]::WriteAllText($source, $editorText)
            }
            return $hash
        }
        Assert-Throws 'changed since the baseline: counter.sv' {
            Publish-RtlRepair $project $baseline $singleCandidate
        }
    }
    if ([IO.File]::ReadAllText($source) -cne $editorText) { throw 'Publication overwrote a concurrent source save.' }
    [IO.File]::WriteAllText($source, $sourceText)
    Write-Host 'PASS Checks the target after the other input hashes'

    $savedAfterHash = @{ done = $false }
    & {
        function Get-FileHash([string]$LiteralPath) {
            $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath
            if ($LiteralPath -eq $source -and -not $savedAfterHash.done) {
                [IO.File]::WriteAllText($source, $editorText)
                $savedAfterHash.done = $true
            }
            return $hash
        }
        Assert-Throws 'changed since the baseline: counter.sv' { Publish-RtlRepair $project $baseline $singleCandidate }
    }
    if ([IO.File]::ReadAllText($source) -cne $editorText) { throw 'Writeback must restore the version saved after the input hash.' }
    [IO.File]::WriteAllText($source, $sourceText)
    Write-Host 'PASS Restores an editor save made between the target hash and replacement'

    Publish-RtlRepair $project $baseline $singleCandidate
    if ([IO.File]::ReadAllText($source) -cne $fixedText) { throw 'The verified candidate was not applied.' }
    if ([IO.File]::ReadAllText($bench) -cne $benchText) { throw 'Publishing a candidate changed the testbench.' }
    Write-Host 'PASS Publishes only the requested source file'

    $auxiliary = Join-Path $original 'auxiliary.sv'
    [IO.File]::WriteAllText($auxiliary, 'module auxiliary; endmodule')
    $project.InputFiles += 'auxiliary.sv'
    $concurrentBaseline = Join-Path $root 'concurrent-baseline'
    Copy-RtlInputs $project $original $concurrentBaseline -WithValidation
    Test-ConcurrentPublication $project $concurrentBaseline (Join-Path $toolRoot 'lib')
    if ([IO.File]::ReadAllText($auxiliary) -ne 'module auxiliary; endmodule') { throw 'The stale writer changed its target.' }
    Write-Host 'PASS Serializes publication across different repair targets'

    Test-SnapshotDuringPublication (Join-Path $root 'snapshot-during-publication')
    Write-Host 'PASS Takes a coherent RTL snapshot during a multi-file publication'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^rtl-repair-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
$passedCount = if ($IsWindows) { 31 } else { 29 }
Write-Host "$passedCount repair tests passed."
