#requires -Version 7.2

<#
.SYNOPSIS
Compiles RTL and runs an optional self-checking testbench with Icarus Verilog or ModelSim.
The repair mode proposes and validates Codex edits to designated RTL files.
The apply mode rechecks a saved preview and writes its exact candidate files.
.EXAMPLE
./rtl-check.ps1 check -Config ./examples/counter/rtlcheck.json
.EXAMPLE
./rtl-check.ps1 repair -Config ./examples/counter/rtlcheck.json -RepairFile counter.sv -Apply
#>
[CmdletBinding(PositionalBinding = $false)]
param (
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('check', 'repair', 'apply')]
    [string]$Mode,
    [Parameter(Mandatory)][string]$Config,
    [string]$RepairFile,
    [switch]$Apply,
    [string]$PreviewReport,
    [ValidateRange(1, 10)][int]$MaxAttempts = 3,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 15,
    [ValidateRange(1, 3600)][int]$CodexTimeoutSeconds = 240,
    [string]$Model,
    [string]$OutDir,
    [ValidatePattern('\A[0-9A-Fa-f]{64}\z')][string]$ExpectedInputSha256,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'lib/Check.ps1')
. (Join-Path $PSScriptRoot 'lib/Repair.ps1')

function Write-RtlProgress([string]$Message, [string]$Phase) {
    if (-not $Json) { Write-Host $Message }
    if ($Phase -and $env:RTL_CHECK_MCP_PROGRESS -eq '1') {
        [Console]::Error.WriteLine("RTL_CHECK_PROGRESS $Phase")
    }
}

$summary = [ordered]@{
    schemaVersion = 1
    mode = $Mode
    configPath = $null
    runDirectory = $null
    status = 'error'
    stopReason = $null
    initial = $null
    validation = $null
    waveformAcceptance = $null
    attempts = [Collections.Generic.List[object]]::new()
    applied = $false
    repairFiles = @()
    candidatePath = $null
    candidateFiles = @()
    inputSha256 = $null
    previewReport = $null
    error = $null
}
$exitCode = 2
try {
    $summary.configPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Config)
    if ([IO.File]::Exists($summary.configPath)) {
        $outputRoot = if ($OutDir) {
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
        } else {
            Join-Path ([IO.Path]::GetDirectoryName($summary.configPath)) '.rtlcheck'
        }
        $runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $summary.runDirectory = Join-Path $outputRoot $runId
        $null = [IO.Directory]::CreateDirectory($summary.runDirectory)
    }
    Write-RtlProgress 'Preparing the RTL project...' 'prepare'
    Assert-RtlCheckActive
    $project = Read-RtlProject $summary.configPath
    if ($project.WaveformAcceptance) { $summary.waveformAcceptance = New-RtlWaveformAcceptanceReport $project.WaveformAcceptance }
    if ($Mode -eq 'apply') {
        if ([string]::IsNullOrWhiteSpace($PreviewReport)) { throw 'Apply mode requires -PreviewReport.' }
        $summary.previewReport = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PreviewReport)
    }
    elseif ($PSBoundParameters.ContainsKey('PreviewReport')) {
        throw 'PreviewReport is an option for apply mode.'
    }
    if ($Apply -and $Mode -ne 'repair') { throw 'The -Apply switch is an option for repair mode.' }
    if ($Mode -in @('repair', 'apply')) {
        if ($project.Testbenches.Count -eq 0 -and $project.Regressions.Count -eq 0) {
            throw 'Repair requires a self-checking primary testbench or public regression.'
        }
        if ($PSBoundParameters.ContainsKey('RepairFile') -and [string]::IsNullOrWhiteSpace($RepairFile)) {
            throw '-RepairFile must name one RTL source.'
        }
        $summary.repairFiles = @(Get-RtlRepairTargets $project $RepairFile)
    }
    elseif ($RepairFile) {
        throw 'RepairFile is an option for repair and apply modes.'
    }

    $baseline = Join-Path $summary.runDirectory 'baseline'
    Copy-RtlProjectBaseline $project $baseline
    $summary.inputSha256 = Get-RtlInputDigest $baseline @(Get-RtlBaselineFiles $project)
    if (-not $summary.inputSha256) { throw 'Could not hash the RTL input snapshot.' }
    if ($ExpectedInputSha256 -and $summary.inputSha256 -ne $ExpectedInputSha256) {
        throw "Input snapshot digest mismatch. Expected $ExpectedInputSha256, observed $($summary.inputSha256)."
    }
    if ($project.Synthesis -and $project.Synthesis.board) {
        $project.Synthesis.board.profile = if ($project.Synthesis.engine -eq 'pango') {
            Read-RtlPangoPinConstraints (Join-Path $baseline $project.Synthesis.fdc)
        } else {
            Read-RtlBoardProfile (Join-Path $baseline $project.Synthesis.board.qsf) $project.Synthesis
        }
    }

    $previewFiles = if ($Mode -eq 'apply') {
        Read-RtlPreviewCandidates $project $summary.configPath $summary.previewReport $baseline $summary.inputSha256 $summary.repairFiles
    }
    $suites = @(Get-RtlProjectSuites $project)
    $icarus = @($suites | Where-Object { $_.Simulator.engine -eq 'icarus' })
    $compiler = if ($icarus.Count) { Find-RtlExecutable 'iverilog' }
    $simulator = if ($icarus | Where-Object { $_.Testbenches.Count -gt 0 }) { Find-RtlExecutable 'vvp' }
    foreach ($suite in $suites) {
        if ($suite.Simulator.engine -eq 'modelsim' -and -not $suite.Simulator['vsim']) {
            Initialize-RtlModelSimTools $suite.Simulator
        }
    }
    if ($project.Synthesis -and $project.Synthesis.engine -eq 'quartus') {
        $project.Synthesis.executable = Find-RtlQuartusMap $project.Synthesis.executable
        if ($project.Synthesis.timing -or $project.Synthesis.board) {
            $project.Synthesis.fitter = Find-RtlQuartusStage $project.Synthesis.executable 'quartus_fit'
        }
        if ($project.Synthesis.timing) {
            $project.Synthesis.timing.analyzer = Find-RtlQuartusStage $project.Synthesis.executable 'quartus_sta'
        }
    }
    elseif ($project.Synthesis -and $project.Synthesis.engine -eq 'pango') {
        $project.Synthesis.executable = Find-RtlPangoShell $project.Synthesis.executable
    }
    elseif ($project.Synthesis) {
        $project.Synthesis.executable = Find-RtlVendorExecutable $project.Synthesis
    }

    if ($previewFiles) { Write-RtlProgress 'Rechecking the saved RTL preview...' 'replay' }
    else { Write-RtlProgress 'Running baseline RTL check...' 'baseline' }
    $logDirectory = Join-Path $summary.runDirectory '00-initial'
    $work = Join-Path $logDirectory 'work'
    Copy-RtlInputs $project $baseline $work
    if ($previewFiles) { Write-RtlFiles $work $previewFiles }
    Assert-RtlCheckActive
    $summary.initial = Invoke-RtlCheck $project $work $logDirectory $compiler $simulator $TimeoutSeconds $baseline $previewFiles
    Assert-RtlCheckActive
    if ($summary.initial.status -eq 'error') { throw $summary.initial.diagnostic }
    if ($summary.initial.status -eq 'passed') {
        if (Invoke-RtlValidation $project $summary $baseline $compiler $simulator $TimeoutSeconds $previewFiles) {
            $summary.status = 'passed'
            if ($previewFiles) {
                $summary.candidateFiles = @(Save-RtlCandidateFiles (Join-Path $summary.runDirectory 'candidate') $previewFiles)
                if ($summary.candidateFiles.Count -eq 1) { $summary.candidatePath = $summary.candidateFiles[0].candidatePath }
                Write-RtlProgress 'Publishing verified RTL files...' 'publish'
                Publish-RtlRepair $project $baseline $previewFiles
                $summary.applied = $true
                $summary.status = 'repaired'
            }
            $exitCode = 0
            if ($project.WaveformAcceptance) {
                Export-RtlWaveformAcceptance $project $summary $baseline $previewFiles $compiler $simulator $TimeoutSeconds
            }
        } else {
            $summary.status = 'failed'
            $exitCode = 1
        }
    } else {
        $summary.status = 'failed'
        $exitCode = 1
        Write-RtlProgress $summary.initial.diagnostic
        if ($previewFiles) { $summary.stopReason = 'preview_check_failed' }
        if ($Mode -eq 'repair') {
            $schema = Join-Path $PSScriptRoot 'repair-response.schema.json'
            Invoke-RtlRepair $project $summary $baseline $summary.repairFiles $compiler $simulator $schema `
                $TimeoutSeconds $CodexTimeoutSeconds $MaxAttempts $Model -Apply:$Apply
            if ($summary.status -eq 'repaired') { $exitCode = 0 }
        }
    }
}
catch [OperationCanceledException] {
    $summary.status = 'error'
    $summary.stopReason = 'cancelled'
    $summary.error = $_.Exception.Message
    if ($summary.attempts.Count -gt 0 -and $summary.attempts[-1].status -in @('proposing', 'checking', 'passed')) {
        $summary.attempts[-1].status = 'cancelled'
        $summary.attempts[-1].error = $summary.error
    }
    $exitCode = 2
}
catch {
    $summary.status = 'error'
    $summary.error = $_.Exception.Message
    $exitCode = 2
}

$report = ConvertTo-Json -InputObject $summary -Depth 12
try {
    if ([IO.Directory]::Exists($summary.runDirectory)) {
        [IO.File]::WriteAllText((Join-Path $summary.runDirectory 'summary.json'), $report + "`n")
    }
}
catch {
    [Console]::Error.WriteLine("Could not save the report: $($_.Exception.Message)")
}
if ($Json) {
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        Write-Output $report
    }
    finally { [Console]::OutputEncoding = $previousEncoding }
} else {
    Write-Host "Result: $($summary.status)"
    foreach ($candidate in $summary.candidateFiles) {
        Write-Host "Verified candidate: $($candidate.candidatePath)"
        if ($summary.applied) { Write-Host "Applied to: $(Join-Path $project.Root $candidate.path)" }
    }
    if ($summary.waveformAcceptance) {
        Write-Host "Waveform acceptance: $($summary.waveformAcceptance.status)"
        if ($summary.waveformAcceptance.openCommand) { Write-Host $summary.waveformAcceptance.openCommand }
    }
    if ($summary.error) { [Console]::Error.WriteLine($summary.error) }
    if ($summary.runDirectory) { Write-Host "Logs: $($summary.runDirectory)" }
}
exit $exitCode
