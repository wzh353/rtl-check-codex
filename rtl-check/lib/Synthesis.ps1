function Read-RtlSynthesisSettings([string]$Root, $Settings) {
    if ($Settings -isnot [System.Collections.IDictionary]) { throw 'synthesis must be an object.' }
    if ($Settings['top'] -isnot [string] -or $Settings['top'] -cnotmatch '\A[A-Za-z_][A-Za-z0-9_$]*\z') {
        throw 'synthesis.top must name the design module.'
    }
    foreach ($key in @('family', 'device')) {
        if ($Settings[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings[$key])) {
            throw "synthesis.$key must be a nonempty string."
        }
    }
    $engine = if ($Settings.Contains('engine')) { $Settings['engine'] } else { 'quartus' }
    if ($engine -isnot [string] -or $engine -cnotin @('quartus', 'pango')) {
        throw 'synthesis.engine must be quartus or pango.'
    }
    $executable = if ($Settings.Contains('executable')) {
        if ($Settings['executable'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings['executable'])) {
            throw 'synthesis.executable must be the path to the synthesis tool.'
        }
        [IO.Path]::GetFullPath($Settings['executable'], $Root)
    }
    $common = @{
        engine = $engine
        top = $Settings['top']
        family = $Settings['family']
        device = $Settings['device']
        executable = $executable
        defines = @(Read-RtlMacroDefinitions $Settings 'synthesis.defines')
    }
    if ($engine -eq 'pango') { return Read-RtlPangoSettings $Root $Settings $common }
    if ($Settings.Contains('failOnWarnings') -and $Settings['failOnWarnings'] -isnot [array]) {
        throw 'synthesis.failOnWarnings must be an array of Quartus warning codes.'
    }
    $failOnWarnings = @(foreach ($code in $Settings['failOnWarnings']) {
        if (($code -isnot [int] -and $code -isnot [long]) -or $code -lt 1 -or $code -gt [int]::MaxValue) {
            throw 'Each synthesis.failOnWarnings entry must be a positive integer.'
        }
        [int]$code
    })
    $common.failOnWarnings = $failOnWarnings
    $common.timing = if ($Settings.Contains('timing')) { Read-RtlTimingSettings $Root $Settings['timing'] }
    $common.board = if ($Settings.Contains('board')) { Read-RtlBoardSettings $Root $Settings['board'] }
    $common.constraintFiles = @(
        if ($common.timing) { $common.timing.sdcFiles }
        if ($common.board) { $common.board.qsf }
    )
    return $common
}

function Find-RtlQuartusMap([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not [IO.File]::Exists($ExplicitPath)) { throw "quartus_map was not found: $ExplicitPath" }
        return $ExplicitPath
    }
    $local = Get-Command quartus_map -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($local) { return $local.Source }
    if ($env:QUARTUS_ROOTDIR) {
        $name = if ($IsWindows) { 'quartus_map.exe' } else { 'quartus_map' }
        foreach ($directory in @('bin64', 'bin')) {
            $candidate = Join-Path (Join-Path $env:QUARTUS_ROOTDIR $directory) $name
            if ([IO.File]::Exists($candidate)) { return $candidate }
        }
    }
    throw 'quartus_map was not found. Set synthesis.executable or install Quartus and add it to PATH.'
}

function ConvertTo-RtlTclWord([string]$Value) {
    if ($Value -match '[\r\n\0]') { throw 'A Tcl argument must fit on one line.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('[', '\[').Replace(']', '\]') + '"'
}

function Copy-RtlHardwareInputs($Project, [string]$ReferenceRoot, [string]$Work,
                                [System.Collections.IDictionary]$Overrides, [string[]]$Constraints) {
    $testbenches = @(foreach ($suite in (Get-RtlProjectSuites $Project)) { $suite.Testbenches })
    $simulationOnly = $testbenches + @($Project['SimulationSources'])
    $support = @($Project.SupportFiles | Where-Object { $_ -notin $simulationOnly })
    $inputs = @($Project.Sources + $support + $Constraints | Where-Object { $_ } | Sort-Object -Unique)
    Copy-RtlInputs $Project $ReferenceRoot $work -Files $inputs
    if ($Overrides) { Write-RtlFiles $work $Overrides }
}

function Invoke-RtlSynthesis($Project, [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides,
                             [string]$LogDirectory, [int]$TimeoutSeconds, [string]$Work) {
    $settings = $Project.Synthesis
    $directory = Join-Path $LogDirectory 'synthesis'
    $inputSdc = if ($settings.timing) { $settings.timing.sdcFiles }
    Copy-RtlHardwareInputs $Project $ReferenceRoot $Work $Overrides $inputSdc

    $projectName = 'rtlcheck_synth_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $sdcFiles = if ($settings.timing) {
        $formatFile = "$projectName.time-format.sdc"
        # Reset only report formatting after all project SDC constraints have been read.
        [IO.File]::WriteAllLines((Join-Path $work $formatFile), [string[]]@('set_time_format -unit ns -decimal_places 3'))
        $settings.timing.sdcFiles + $formatFile
    }
    $assignments = [ordered]@{
        FAMILY = $settings.family
        DEVICE = $settings.device
        TOP_LEVEL_ENTITY = $settings.top
        SEARCH_PATH = $Project.IncludeDirs
        VERILOG_MACRO = $settings.defines
        SDC_FILE = $sdcFiles
    }
    $qsf = @(foreach ($key in $assignments.Keys) {
        foreach ($value in $assignments[$key]) {
            "set_global_assignment -name $key $(ConvertTo-RtlTclWord $value)"
        }
    })
    $qsf += @(foreach ($source in $Project.Sources) {
        $language = if ([IO.Path]::GetExtension($source) -eq '.sv') { 'SYSTEMVERILOG_FILE' } else { 'VERILOG_FILE' }
        "set_global_assignment -name $language $(ConvertTo-RtlTclWord $source)"
    })
    if ($settings.board) { $qsf += $settings.board.profile.assignments }
    $qsfPath = Join-Path $work "$projectName.qsf"
    [IO.File]::WriteAllLines($qsfPath, [string[]]$qsf)
    $arguments = @($projectName, '--read_settings_files=on', '--write_settings_files=off')
    $process = Invoke-RtlProcess $settings.executable $arguments $work (Join-Path $directory 'quartus_map') $TimeoutSeconds
    $result = Get-RtlQuartusResult $process 'synthesis' '\bAnalysis (?:&|and) Synthesis was successful\.' $TimeoutSeconds $settings.failOnWarnings
    $logic = Select-String -LiteralPath @($process.stdout, $process.stderr) -Pattern 'Info \(21061\): Implemented (\d+) logic cells?' -List |
        Select-Object -First 1
    $result.qsfPath = $qsfPath
    $result.engine = 'quartus'
    $result.sdcFiles = @($sdcFiles | Where-Object { $_ })
    $result.logicCells = if ($logic) { [int]$logic.Matches[0].Groups[1].Value }
    return $result
}

function Get-RtlQuartusResult($Process, [string]$StageName, [string]$SuccessPattern, [int]$TimeoutSeconds,
                              [int[]]$FailOnWarnings) {
    $logs = @($process.stdout, $process.stderr)
    $issues = @(foreach ($entry in (Select-String -LiteralPath $logs -Pattern '^\s*(Error|Warning|Critical Warning) \((\d+)\):\s*(.+)$' -CaseSensitive)) {
        $groups = $entry.Matches[0].Groups
        $messageText = $groups[3].Value
        $location = [regex]::Match($messageText, '\bat\s+"?(.+?\.(?:svh|vh|sv|v))"?\((\d+)\)(?=[:\s]|$)')
        $file = if ($location.Success) { $location.Groups[1].Value }
        [ordered]@{
            severity = $groups[1].Value
            code = [int]$groups[2].Value
            file = $file
            inputFile = Get-RtlDiagnosticInputFile $file $process.workingDirectory
            line = if ($location.Success) { [int]$location.Groups[2].Value }
            message = $messageText
            text = $entry.Line.Trim()
            log = $entry.Path
        }
    })
    $warnings = @($issues | Where-Object { $_.severity -ne 'Error' })
    $errors = @($issues | Where-Object { $_.severity -eq 'Error' })
    $badTarget = $errors | Where-Object { $_.code -in @(125095, 281000) -and $_.message -match '^Part name ' } | Select-Object -First 1
    $toolError = $errors | Where-Object { $_.code -in @(20005, 37027, 37028, 292026, 292027) } | Select-Object -First 1
    $longPath = $errors | Where-Object { $_.code -eq 114010 -and $_.message -match 'file name is too long' } | Select-Object -First 1
    $firstError = if ($errors.Count) { $errors[0] } else {
        $warnings | Where-Object { $_.code -in $FailOnWarnings } | Select-Object -First 1
    }
    $finished = Select-String -LiteralPath $logs -Pattern $SuccessPattern -Quiet
    $missingResult = $errors.Count -eq 0 -and ($process.exitCode -ne 0 -or -not $finished)
    $message = if ($process.timedOut) { "Quartus $StageName timed out after $TimeoutSeconds s." }
    elseif ($badTarget) { 'Quartus rejected the configured FPGA part.' }
    elseif ($toolError) { 'Quartus could not use its licence or configured device library.' }
    elseif ($longPath) { 'Quartus could not create its database because the build path is too long.' }
    elseif ($missingResult) { "No conclusive Quartus result was found for $StageName." }
    elseif ($process.exitCode -ne 0 -or $errors.Count) { "Quartus $StageName failed." }
    elseif ($firstError) { "Quartus $StageName reported a configured blocking warning." }

    return [ordered]@{
        status = if ($process.timedOut -or $badTarget -or $toolError -or $longPath -or $missingResult) { 'error' }
        elseif ($message) { 'failed' }
        else { 'passed' }
        process = $process
        warnings = $warnings
        firstError = $firstError
        diagnostic = if ($message) { Get-RtlDiagnostics $process $message $firstError }
    }
}

function Set-RtlHardwareStage($Report, [string]$Stage, $Result) {
    $key = if ($Stage -eq 'synthesize') { 'synthesis' } else { $Stage }
    $Report[$key] = $Result
    $Report.stage = $Stage
    $Report.status = $Result.status
    $Report.exitCode = $Result.process.exitCode
    $Report.timedOut = $Result.process.timedOut
    $Report.firstError = $Result.firstError
    $Report.diagnostic = $Result.diagnostic
}

function Set-RtlHardwareGateFailure($Result, [string]$Status, [string]$Reason, [string]$Message, $FirstError) {
    $Result.status = $Status
    $Result.reason = $Reason
    $Result.diagnostic = Get-RtlDiagnostics $Result.process $Message $FirstError
}

function Add-RtlSynthesisResult($Project, $Report, [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides,
                               [string]$LogDirectory, [int]$TimeoutSeconds) {
    if (-not $Project['Synthesis']) { return }
    $path = New-RtlToolPath (Join-Path $LogDirectory 'synthesis/work')
    $build = $path.execution
    try {
        if ($Project.Synthesis['engine'] -eq 'pango') {
            Add-RtlPangoSynthesisResult $Project $Report $ReferenceRoot $Overrides $LogDirectory $TimeoutSeconds $build
            return
        }
        Write-RtlProgress 'Running Quartus analysis and synthesis...' 'synthesis'
        $result = Invoke-RtlSynthesis $Project $ReferenceRoot $Overrides $LogDirectory $TimeoutSeconds $build
        Set-RtlHardwareStage $Report 'synthesize' $result
        if ($result.status -eq 'passed' -and ($Project.Synthesis.timing -or $Project.Synthesis.board)) {
            Add-RtlFitResult $Project.Synthesis $Report $LogDirectory $TimeoutSeconds
        }
    }
    finally {
        if ($path.junction) {
            try {
                foreach ($stage in @('synthesis', 'fit', 'timing')) {
                    $details = $Report[$stage]
                    if (-not $details) { continue }
                    Restore-RtlReportedToolPath $details.process $path
                    foreach ($key in @('qsfPath', 'projectPath', 'scriptPath', 'summaryPath', 'reportPath', 'pinReportPath')) {
                        if ($details[$key]) {
                            $details[$key] = Join-Path $path.working ([IO.Path]::GetRelativePath($build, $details[$key]))
                        }
                    }
                }
            }
            finally { Remove-RtlToolPath $path }
        }
    }
}
