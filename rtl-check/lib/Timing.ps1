function Read-RtlTimingSettings([string]$Root, $Settings) {
    if ($Settings -isnot [System.Collections.IDictionary]) { throw 'synthesis.timing must be an object.' }
    $keys = @('sdcFiles', 'clocks', 'requireFullyConstrained', 'minSetupSlackNs', 'minHoldSlackNs', 'maxLogicElements')
    foreach ($key in $Settings.Keys) {
        if ($key -cnotin $keys) { throw "Unknown synthesis.timing field: $key" }
    }
    if ($Settings['sdcFiles'] -isnot [array] -or $Settings['sdcFiles'].Count -eq 0) {
        throw 'synthesis.timing.sdcFiles must be a nonempty array of project SDC files.'
    }
    $files = @(foreach ($name in $Settings['sdcFiles']) {
        $path = Resolve-RtlProjectItem $Root $name
        if ([IO.Path]::GetExtension($path) -ne '.sdc') { throw "Expected an SDC file: $name" }
        $path
    })
    if (@($files | Sort-Object -Unique).Count -ne $files.Count) { throw 'List each SDC filename once.' }
    $result = Read-RtlTimingLimits $Settings
    $result.sdcFiles = $files
    $result.requireFullyConstrained = $true
    $result.maxLogicElements = $null
    if ($Settings.Contains('requireFullyConstrained')) {
        if ($Settings['requireFullyConstrained'] -isnot [bool]) { throw 'synthesis.timing.requireFullyConstrained must be a boolean.' }
        $result.requireFullyConstrained = $Settings['requireFullyConstrained']
    }
    if ($Settings.Contains('maxLogicElements')) {
        $value = $Settings['maxLogicElements']
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0) {
            throw 'synthesis.timing.maxLogicElements must be a nonnegative integer.'
        }
        $result.maxLogicElements = $value
    }
    return $result
}

function Read-RtlTimingLimits($Settings) {
    if ($Settings['clocks'] -isnot [System.Collections.IDictionary] -or $Settings['clocks'].Count -eq 0) {
        throw 'synthesis.timing.clocks must map each required clock name to its period in nanoseconds.'
    }
    $clocks = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($clock in $Settings['clocks'].Keys) {
        $value = $Settings['clocks'][$clock]
        if ([string]::IsNullOrWhiteSpace($clock) -or $clock -match '[\r\n;]' -or
            ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double]) -or
            -not [double]::IsFinite($value) -or $value -lt 0.001) {
            throw "Expected a clock name and a period of at least 0.001 ns: $clock"
        }
        $clocks[$clock] = [double]$value
    }
    $result = @{
        clocks = $clocks
        minSetupSlackNs = 0
        minHoldSlackNs = 0
    }
    foreach ($key in @('minSetupSlackNs', 'minHoldSlackNs')) {
        if (-not $Settings.Contains($key)) { continue }
        $value = $Settings[$key]
        if (($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double]) -or
            -not [double]::IsFinite($value) -or $value -lt 0) {
            throw "synthesis.timing.$key must be a nonnegative number."
        }
        $result[$key] = $value
    }
    return $result
}

function Find-RtlQuartusStage([string]$Mapper, [string]$Name) {
    $file = if ($IsWindows) { "$Name.exe" } else { $Name }
    $path = Join-Path ([IO.Path]::GetDirectoryName($Mapper)) $file
    if (-not [IO.File]::Exists($path)) { throw "$Name was not found beside quartus_map: $path" }
    return $path
}

function Read-RtlFitterResources([string]$Path) {
    $labels = @{
        'Total logic elements' = 'logicElements'
        'Total registers' = 'registers'
        'Total pins' = 'pins'
        'Total memory bits' = 'memoryBits'
    }
    $resources = [ordered]@{}
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match '^(?<label>[^:]+?)\s*:\s*(?<count>[\d,]+)(?:\s|$)' -and $labels.ContainsKey($Matches['label'])) {
            $resources[$labels[$Matches['label']]] = [long]$Matches['count'].Replace(',', '')
        }
    }
    return $resources
}

function Read-RtlTimeQuestChecks([string]$Path) {
    $number = '-?\d+(?:\.\d+)?'
    $pattern = "(?m)^Type[ \t]*:[ \t]*(?<corner>[^\r\n]+?) (?<check>Setup|Hold|Recovery|Removal|Minimum Pulse Width) '(?<clock>[^\r\n]+)'\r?\n" +
        "Slack[ \t]*:[ \t]*(?<slack>$number)[ \t]*\r?\nTNS[ \t]*:[ \t]*(?<tns>$number)[ \t]*\r?$"
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $text = [IO.File]::ReadAllText($Path)
    $entries = [regex]::Matches($text, $pattern)
    $checks = @(foreach ($item in $entries) {
        [ordered]@{
            corner = $item.Groups['corner'].Value
            check = $item.Groups['check'].Value
            clock = $item.Groups['clock'].Value
            slackNs = [double]::Parse($item.Groups['slack'].Value, $culture)
            tnsNs = [double]::Parse($item.Groups['tns'].Value, $culture)
        }
    })
    return @{
        complete = $entries.Count -gt 0 -and $entries.Count -eq [regex]::Matches($text, '(?m)^Type[ \t]*:').Count
        checks = $checks
    }
}

function Read-RtlTimeQuestTables([string]$Path) {
    $section = ''
    $pathSection = $null
    $checkSection = $null
    $number = '^-?\d+(?:\.\d+)?$'
    $coverageNames = @(
        'Illegal Clocks', 'Unconstrained Clocks',
        'Unconstrained Input Ports', 'Unconstrained Input Port Paths',
        'Unconstrained Output Ports', 'Unconstrained Output Port Paths'
    )
    $clocks = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $fileComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $sdcFiles = [System.Collections.Specialized.OrderedDictionary]::new($fileComparer)
    $work = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $corners = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $checks = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $duplicateEntry = $false
    $coverage = [ordered]@{}
    $paths = [System.Collections.Generic.List[object]]::new()
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $assumedClocks = $false
    $reportedIncomplete = $false
    $reportedViolation = $false
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match '^\s*Info \(332142\):') { $assumedClocks = $true }
        if ($line -match '^\s*Info \(332102\):') { $reportedIncomplete = $true }
        if ($line -match '^\s*Critical Warning \(332148\):') { $reportedViolation = $true }
        if ($line -match '^\s*Info: Analyzing (.+? Model)\s*$') { $null = $corners.Add($Matches[1]) }
        if (-not $line.StartsWith(';') -or -not $line.TrimEnd().EndsWith(';')) { continue }
        $columns = @($line.Trim().Trim(';').Split(';').Trim())
        if ($columns.Count -eq 1) {
            $section = $columns[0]
            $pathSection = [regex]::Match($section, "^(?<corner>.+?) (?<check>Setup|Hold|Recovery|Removal): '(?<clock>.+)'$")
            $checkSection = [regex]::Match($section, '^(?<corner>.+?) (?<check>Setup|Hold|Recovery|Removal|Minimum Pulse Width) Summary$')
            $pathsInSection = 0
        }
        elseif ($section -eq 'SDC File List' -and $columns.Count -eq 3 -and $columns[0] -ne 'SDC File Path') {
            $file = Get-RtlDiagnosticInputFile $columns[0] $work
            if ($file) {
                if ($sdcFiles.Contains($file)) { $duplicateEntry = $true }
                $sdcFiles[$file] = $columns[1]
            }
        }
        elseif ($section -eq 'Clocks' -and $columns.Count -ge 3 -and $columns[2] -match '^\d+(?:\.\d+)?$') {
            if ($clocks.Contains($columns[0])) { $duplicateEntry = $true }
            $clocks[$columns[0]] = [double]::Parse($columns[2], $culture)
        }
        elseif ($section -eq 'Unconstrained Paths' -and $columns.Count -eq 3 -and
                $columns[0] -in $coverageNames -and $columns[1] -match '^\d[\d,]*$' -and $columns[2] -match '^\d[\d,]*$') {
            if ($coverage.Contains($columns[0])) { $duplicateEntry = $true }
            $coverage[$columns[0]] = [ordered]@{
                setup = [long]$columns[1].Replace(',', '')
                hold = [long]$columns[2].Replace(',', '')
            }
        }
        elseif ($checkSection -and $checkSection.Success -and $columns.Count -eq 3 -and
                $columns[1] -match $number -and $columns[2] -match $number) {
            $id = $checkSection.Groups['corner'].Value + "`n" + $checkSection.Groups['check'].Value + "`n" + $columns[0]
            $actual = @{
                slackNs = [double]::Parse($columns[1], $culture)
                tnsNs = [double]::Parse($columns[2], $culture)
            }
            if (-not $checks.TryAdd($id, $actual)) { $duplicateEntry = $true }
        }
        elseif ($pathSection -and $pathSection.Success -and $pathsInSection -lt 2 -and $columns.Count -ge 5 -and
                $columns[0] -match $number) {
            $paths.Add([ordered]@{
                corner = $pathSection.Groups['corner'].Value
                check = $pathSection.Groups['check'].Value
                clock = $pathSection.Groups['clock'].Value
                slackNs = [double]::Parse($columns[0], $culture)
                fromNode = $columns[1]
                toNode = $columns[2]
                launchClock = $columns[3]
                latchClock = $columns[4]
                dataDelayNs = if ($columns.Count -ge 8 -and $columns[7] -match $number) {
                    [double]::Parse($columns[7], $culture)
                }
            })
            $pathsInSection++
        }
    }
    $unconstrained = @($coverage.Values | Where-Object { $_.setup -gt 0 -or $_.hold -gt 0 })
    $worstPaths = @($paths | Group-Object { $_.check } | ForEach-Object {
        $_.Group | Sort-Object { $_.slackNs } | Select-Object -First 2
    } | Sort-Object { $_.slackNs })
    return @{
        clocks = $clocks
        sdcFiles = $sdcFiles
        corners = $corners
        checks = $checks
        duplicateEntry = $duplicateEntry
        assumedClocks = $assumedClocks
        reportedViolation = $reportedViolation
        coverage = $coverage
        coverageAvailable = $coverage.Count -eq $coverageNames.Count -or $reportedIncomplete
        constraintsComplete = $coverage.Count -eq $coverageNames.Count -and -not $reportedIncomplete -and $unconstrained.Count -eq 0
        paths = $worstPaths
    }
}

function Test-RtlTimeQuestConsistency($Summary, $Tables) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not $Summary.complete -or $Tables.duplicateEntry -or $Summary.checks.Count -ne $Tables.checks.Count -or
        $Tables.corners.Count -eq 0) { return $false }
    foreach ($check in $Summary.checks) {
        $id = "$($check.corner)`n$($check.check)`n$($check.clock)"
        if (-not $seen.Add($id) -or -not $Tables.corners.Contains($check.corner) -or -not $Tables.checks.ContainsKey($id)) {
            return $false
        }
        $row = $Tables.checks[$id]
        if ($row.slackNs -ne $check.slackNs -or $row.tnsNs -ne $check.tnsNs) { return $false }
    }
    return $true
}

function Add-RtlTimeQuestEvidence($Result, $Settings, [string]$QsfPath, [string[]]$ExpectedSdcFiles) {
    $Result.summaryPath = [IO.Path]::ChangeExtension($QsfPath, '.sta.summary')
    $Result.reportPath = [IO.Path]::ChangeExtension($QsfPath, '.sta.rpt')
    if (-not [IO.File]::Exists($Result.summaryPath) -or -not [IO.File]::Exists($Result.reportPath)) {
        Set-RtlHardwareGateFailure $Result 'error' 'missing_reports' 'TimeQuest did not produce both timing reports.'
        return
    }
    $summary = Read-RtlTimeQuestChecks $Result.summaryPath
    $checks = $summary.checks
    $tables = Read-RtlTimeQuestTables $Result.reportPath
    $Result.clocks = $tables.clocks
    $Result.sdcFiles = $tables.sdcFiles
    $Result.coverage = $tables.coverage
    $Result.constraintsComplete = $tables.constraintsComplete
    $Result.checks = $checks
    $Result.worstPaths = $tables.paths
    $setup = @($checks | Where-Object { $_.check -eq 'Setup' })
    $hold = @($checks | Where-Object { $_.check -eq 'Hold' })
    $Result.worstSetupSlackNs = if ($setup.Count) { ($setup.slackNs | Measure-Object -Minimum).Minimum }
    $Result.worstHoldSlackNs = if ($hold.Count) { ($hold.slackNs | Measure-Object -Minimum).Minimum }

    foreach ($file in $ExpectedSdcFiles) {
        if ($tables.sdcFiles[$file] -ne 'OK') {
            Set-RtlHardwareGateFailure $Result 'error' 'sdc_not_read' "TimeQuest did not report reading the expected SDC file '$file' successfully."
            return
        }
    }
    if (@($tables.sdcFiles.Keys)[-1] -cne $ExpectedSdcFiles[-1]) {
        Set-RtlHardwareGateFailure $Result 'error' 'report_format' 'TimeQuest did not read the generated nanosecond format assignment after the project SDC files.'
        return
    }
    if ($tables.assumedClocks) {
        Set-RtlHardwareGateFailure $Result 'failed' 'clock_mismatch' 'TimeQuest derived default clocks because it found no user-constrained base clocks.'
        return
    }
    if ($tables.clocks.Count -eq 0 -or -not (Test-RtlTimeQuestConsistency $summary $tables)) {
        Set-RtlHardwareGateFailure $Result 'error' 'unrecognized_timing' 'TimeQuest timing summaries and per-corner report tables are incomplete or inconsistent.'
        return
    }
    foreach ($clock in $Settings.clocks.Keys) {
        $expected = $Settings.clocks[$clock]
        $actual = $tables.clocks[$clock]
        if ($null -eq $actual -or [Math]::Abs($actual - $expected) -gt 0.0005) {
            $actualText = if ($null -eq $actual) { 'missing' } else { "$actual ns" }
            Set-RtlHardwareGateFailure $Result 'failed' 'clock_mismatch' "TimeQuest clock '$clock' expected $expected ns, reported $actualText."
            return
        }
        foreach ($corner in $tables.corners) {
            if (-not $tables.checks.ContainsKey("$corner`nSetup`n$clock") -or -not $tables.checks.ContainsKey("$corner`nHold`n$clock")) {
                Set-RtlHardwareGateFailure $Result 'failed' 'missing_checks' "TimeQuest did not report setup and hold checks for clock '$clock' at $corner."
                return
            }
        }
    }
    if ($Settings.requireFullyConstrained -and -not $tables.coverageAvailable) {
        Set-RtlHardwareGateFailure $Result 'error' 'unrecognized_coverage' 'TimeQuest reports did not provide conclusive timing constraint coverage.'
        return
    }
    if ($Settings.requireFullyConstrained -and -not $tables.constraintsComplete) {
        Set-RtlHardwareGateFailure $Result 'failed' 'unconstrained_paths' 'TimeQuest reported incomplete timing constraints. See the coverage counts in the report.'
        return
    }
    $violations = @(foreach ($check in $checks) {
        $minimum = switch ($check.check) {
            'Setup' { $Settings.minSetupSlackNs }
            'Hold' { $Settings.minHoldSlackNs }
            default { 0 }
        }
        if ($check.slackNs -lt $minimum -or $check.tnsNs -lt 0) {
            $check.requiredSlackNs = $minimum
            $check
        }
    })
    $Result.violations = @($violations | Sort-Object { $_.slackNs - $_.requiredSlackNs } | Select-Object -First 12)
    if ($violations.Count) {
        $worst = $Result.violations[0]
        $message = "TimeQuest $($worst.check) violation for '$($worst.clock)' at $($worst.corner). Slack $($worst.slackNs) ns, required $($worst.requiredSlackNs) ns, TNS $($worst.tnsNs) ns."
        Set-RtlHardwareGateFailure $Result 'failed' 'slack_violation' $message
    }
    elseif ($tables.reportedViolation) {
        Set-RtlHardwareGateFailure $Result 'failed' 'slack_violation' 'TimeQuest flagged a timing violation. See the detailed timing report.'
    }
}

function Add-RtlFitResult($Synthesis, $Report, [string]$LogDirectory, [int]$TimeoutSeconds) {
    $settings = $Synthesis.timing
    $directory = Join-Path $LogDirectory 'synthesis'
    $qsf = $Report.synthesis.qsfPath
    $work = [IO.Path]::GetDirectoryName($qsf)
    $name = [IO.Path]::GetFileNameWithoutExtension($qsf)

    Write-RtlProgress 'Running Quartus placement and routing...' 'fit'
    $arguments = @($name, '--read_settings_files=on', '--write_settings_files=off')
    $process = Invoke-RtlProcess $Synthesis.fitter $arguments $work (Join-Path $directory 'quartus_fit') $TimeoutSeconds
    $fit = Get-RtlQuartusResult $process 'fitter' '\bFitter was successful\.' $TimeoutSeconds $Synthesis.failOnWarnings
    $fit.summaryPath = [IO.Path]::ChangeExtension($qsf, '.fit.summary')
    $fit.reportPath = [IO.Path]::ChangeExtension($qsf, '.fit.rpt')
    $fit.pinReportPath = [IO.Path]::ChangeExtension($qsf, '.pin')
    if ($fit.status -eq 'passed') {
        if (-not [IO.File]::Exists($fit.summaryPath)) {
            Set-RtlHardwareGateFailure $fit 'error' 'missing_reports' 'Quartus Fitter did not produce its utilization summary.'
        } else {
            $fit.resources = Read-RtlFitterResources $fit.summaryPath
            if ($settings -and $null -ne $settings.maxLogicElements) {
                if (-not $fit.resources.Contains('logicElements')) {
                    Set-RtlHardwareGateFailure $fit 'error' 'unrecognized_utilization' 'The Fitter summary does not contain a supported logic element count.'
                }
                elseif ($fit.resources.logicElements -gt $settings.maxLogicElements) {
                    $message = "Quartus Fitter used $($fit.resources.logicElements) logic elements. Configured limit is $($settings.maxLogicElements)."
                    Set-RtlHardwareGateFailure $fit 'failed' 'logic_elements_limit' $message
                }
            }
        }
    }
    if ($fit.status -eq 'passed' -and $Synthesis.board) { Add-RtlBoardEvidence $fit $Synthesis.board }
    Set-RtlHardwareStage $Report 'fit' $fit
    if ($fit.status -ne 'passed' -or -not $settings) { return }

    Write-RtlProgress 'Running TimeQuest post-fit timing analysis...' 'timing'
    $process = Invoke-RtlProcess $settings.analyzer @($name) $work (Join-Path $directory 'quartus_sta') $TimeoutSeconds
    $timing = Get-RtlQuartusResult $process 'TimeQuest' '\bTimeQuest Timing Analyzer was successful\.' $TimeoutSeconds $Synthesis.failOnWarnings
    if ($timing.status -eq 'passed') { Add-RtlTimeQuestEvidence $timing $settings $qsf $Report.synthesis.sdcFiles }
    Set-RtlHardwareStage $Report 'timing' $timing
}
