function Read-RtlPangoSettings([string]$Root, $Settings, $Result) {
    $keys = @('engine', 'top', 'family', 'device', 'package', 'speedGrade', 'executable', 'defines', 'fdc',
        'board', 'timing', 'failOnWarnings')
    foreach ($key in $Settings.Keys) {
        if ($key -cnotin $keys) { throw "Unknown Pango synthesis field: $key" }
    }
    foreach ($key in @('family', 'device', 'package')) {
        if ($Settings[$key] -isnot [string] -or $Settings[$key] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]*\z') {
            throw "Set synthesis.$key to the Pango part identifier."
        }
    }
    if ($Settings['speedGrade'] -isnot [string] -or $Settings['speedGrade'] -cnotmatch '\A-[0-9]+\z') {
        throw 'Set synthesis.speedGrade to the Pango speed grade, for example "-6".'
    }
    $Result.package = $Settings['package']
    $Result.speedGrade = $Settings['speedGrade']
    if ($Result.defines.Count) {
        throw 'For Pango, define synthesis macros in an RTL header listed in supportFiles.'
    }
    $Result.fdc = if ($Settings.Contains('fdc')) {
        $file = Resolve-RtlProjectItem $Root $Settings['fdc']
        if ([IO.Path]::GetExtension($file) -ne '.fdc') { throw 'synthesis.fdc must name a Pango FDC file.' }
        $file
    }
    $Result.constraintFiles = @($Result.fdc | Where-Object { $_ })
    $Result.board = if ($Settings.Contains('board')) {
        $board = $Settings['board']
        if ($board -isnot [System.Collections.IDictionary] -or @($board.Keys | Where-Object { $_ -cne 'requireAllPins' }).Count) {
            throw 'Pango synthesis.board accepts only requireAllPins.'
        }
        if ($board.Contains('requireAllPins') -and $board['requireAllPins'] -isnot [bool]) {
            throw 'synthesis.board.requireAllPins must be a boolean.'
        }
        @{ requireAllPins = -not $board.Contains('requireAllPins') -or $board['requireAllPins']; profile = $null }
    }
    $Result.timing = if ($Settings.Contains('timing')) {
        $timing = $Settings['timing']
        if ($timing -isnot [System.Collections.IDictionary]) { throw 'synthesis.timing must be an object.' }
        foreach ($key in $timing.Keys) {
            if ($key -cnotin @('clocks', 'minSetupSlackNs', 'minHoldSlackNs')) {
                throw "Unknown Pango synthesis.timing field: $key"
            }
        }
        $limits = Read-RtlTimingLimits $timing
        if (@($limits.clocks.Keys | Where-Object { $_ -match '\s' }).Count) {
            throw 'Pango timing clock names must contain no whitespace.'
        }
        $limits
    }
    if (($Result.board -or $Result.timing) -and -not $Result.fdc) {
        throw 'Pango board or timing checks require synthesis.fdc.'
    }
    if ($Settings.Contains('failOnWarnings') -and $Settings['failOnWarnings'] -isnot [array]) {
        throw 'Pango synthesis.failOnWarnings must be an array of warning codes.'
    }
    $Result.failOnWarnings = @(foreach ($code in $Settings['failOnWarnings']) {
        if ($code -isnot [string] -or $code -cnotmatch '\A[A-Za-z][A-Za-z0-9_]*-\d+\z') {
            throw 'Expected a Pango warning code, for example "Timing-4087".'
        }
        $code
    })
    return $Result
}

function Find-RtlPangoShell([string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not [IO.File]::Exists($ExplicitPath)) { throw "pds_shell was not found: $ExplicitPath" }
        return $ExplicitPath
    }
    $command = Get-Command pds_shell -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'pds_shell was not found. Set synthesis.executable or add the PDS bin directory to PATH.'
}

function Read-RtlPangoPinConstraints([string]$Path) {
    $ports = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $attributes = @{ LOC = 'pin'; STANDARD = 'ioStandard'; VCCIO = 'voltage'; DIRECTION = 'direction' }
    $pattern = '^\s*define_attribute\s+\{p:(?<port>[A-Za-z_][A-Za-z0-9_.$]*(?:\[-?\d+\])*)\}\s+' +
        '\{PAP_IO_(?<key>LOC|STANDARD|VCCIO|DIRECTION)\}\s+\{(?<value>[A-Za-z0-9_.-]+)\}\s*(?:#.*)?$'
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*#' -or $line -notmatch 'PAP_IO_(?:LOC|STANDARD|VCCIO|DIRECTION)\b') { continue }
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) { throw "Expected a literal Pango pin constraint in $Path. $line" }
        $port = $match.Groups['port'].Value
        $field = $attributes[$match.Groups['key'].Value]
        if (-not $ports.Contains($port)) { $ports[$port] = @{} }
        if ($ports[$port].ContainsKey($field)) { throw "Duplicate Pango $field constraint for port '$port'." }
        $ports[$port][$field] = $match.Groups['value'].Value
    }
    if (-not $ports.Count) { throw 'Pango board checking requires explicit pin constraints in the FDC.' }
    $pins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($port in $ports.Keys) {
        $values = $ports[$port]
        if (-not $values['pin'] -or -not $values['ioStandard'] -or -not $values['voltage']) {
            throw "Set PAP_IO_LOC, PAP_IO_STANDARD and PAP_IO_VCCIO for Pango port '$port'."
        }
        if ($values.voltage -notmatch '\A[0-9]+(?:\.[0-9]+)?\z') {
            throw "Expected a numeric PAP_IO_VCCIO voltage for Pango port '$port'."
        }
        $values.voltage = [decimal]::Parse($values.voltage, [Globalization.CultureInfo]::InvariantCulture)
        if (-not $pins.Add($values.pin)) { throw "Pango pin '$($values.pin)' is assigned more than once." }
    }
    return $ports
}

function Read-RtlPangoImplementedPins([string]$Path) {
    $columns = [ordered]@{ PORT = 'name'; LOC = 'pin'; IOSTANDARD = 'ioStandard'; VCCIO = 'voltage'; DIRECTION = 'direction'; CONSTRAINT = 'constrained' }
    $ports = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $section = $false
    $indexes = $null
    $borders = 0
    $columnCount = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*IO Port Info:\s*$') { $section = $true; continue }
        if (-not $section) { continue }
        $row = $line.Trim()
        if ($row -match '^\+-{4,}\+$') {
            $borders++
            if ($borders -eq 3) {
                if ($ports.Count) { return $ports }
                return
            }
            if ($borders -eq 2 -and -not $indexes) { return }
            continue
        }
        if (-not $row.StartsWith('|')) { return }
        $values = @($row.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if (-not $indexes) {
            if ($borders -ne 1) { return }
            $indexes = @{}
            $columnCount = $values.Count
            foreach ($name in $columns.Keys) {
                $index = [array]::IndexOf($values, [string]$name)
                if ($index -lt 0 -or [array]::LastIndexOf($values, [string]$name) -ne $index) { return }
                $indexes[$name] = $index
            }
            continue
        }
        if ($borders -ne 2 -or $values.Count -ne $columnCount) { return }
        $pin = @{}
        foreach ($name in $columns.Keys) { $pin[$columns[$name]] = $values[$indexes[$name]] }
        if (-not $pin.name -or $ports.Contains($pin.name) -or $pin.constrained -cnotin @('YES', 'NO')) { return }
        $pin.constrained = $pin.constrained -ceq 'YES'
        if ($pin.voltage -match '\A[0-9]+(?:\.[0-9]+)?\z') {
            $pin.voltage = [decimal]::Parse($pin.voltage, [Globalization.CultureInfo]::InvariantCulture)
        }
        $ports[$pin.name] = $pin
    }
}

function Add-RtlPangoBoardEvidence($Fit, $Board) {
    $ports = Read-RtlPangoImplementedPins $Fit.reportPath
    if (-not $ports) {
        Set-RtlHardwareGateFailure $Fit 'error' 'unrecognized_pin_report' 'PDS did not report a conclusive implemented I/O table.'
        return
    }
    $matched = 0
    $mismatches = @(foreach ($name in $Board.profile.Keys) {
        $expected = $Board.profile[$name]
        $actual = $ports[$name]
        $issues = @(if (-not $actual) { 'port absent from the routed design' } else {
            if (-not $actual.constrained) { 'pin was not constrained' }
            foreach ($field in $expected.Keys) {
                if ($actual[$field] -ne $expected[$field]) { "$field expected $($expected[$field]), routed $($actual[$field])" }
            }
        })
        if ($issues.Count) { @{ port = $name; issues = $issues; expected = $expected; actual = $actual } }
        else { $matched++ }
    }
    if ($Board.requireAllPins) {
        foreach ($name in $ports.Keys) {
            if (-not $Board.profile.Contains($name)) { @{ port = $name; issues = @('port has no fixed pin constraint'); actual = $ports[$name] } }
        }
    })
    $Fit.board = [ordered]@{
        matchedPinCount = $matched
        portCount = $ports.Count
        ports = $ports
        mismatches = $mismatches
    }
    if ($mismatches.Count) {
        $details = @($mismatches | Select-Object -First 12 | ForEach-Object { "$($_.port) ($($_.issues -join ', '))" })
        Set-RtlHardwareGateFailure $Fit 'failed' 'board_mismatch' "PDS implemented pins differ from the board constraints. $($details -join '. ')"
    }
}

function Read-RtlPangoTimingReport([string]$Path) {
    $clocks = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $checks = [Collections.Generic.List[object]]::new()
    $sections = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $closed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $clockPairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $section = $null
    $design = $null
    $number = [Globalization.CultureInfo]::InvariantCulture
    $lines = [IO.File]::ReadLines($Path).GetEnumerator()
    try {
        while ($lines.MoveNext()) {
            $line = $lines.Current
            if ($closed.Count -eq 5 -and $design) { break }
            if ($line -match '^\s*Design Summary\s*:\s*(\S.*?)\s*$') {
                if ($design) { return }
                $design = $Matches[1]
            }
            $nextSection = $null
            if ($line -match '^\s*Clock Summary:\s*$') {
                $nextSection = 'clocks'
            } elseif ($line -match '^\s*(Setup|Hold) Summary\((Slow|Fast) Corner\):\s*$') {
                $kind = $Matches[1].ToLowerInvariant()
                $corner = $Matches[2].ToLowerInvariant()
                $nextSection = "$kind-$corner"
            }
            if ($nextSection) {
                if ($section -or -not $sections.Add($nextSection)) { return }
                $section = $nextSection
                $header = $false
                $readingRows = $false
                continue
            }
            if (-not $section) { continue }
            if ($line -match '^=+\s*$') {
                if (-not $readingRows) { return }
                $null = $closed.Add($section)
                $section = $null
                continue
            }
            if (-not $readingRows) {
                if ($line -match '^-{8,}\s*$') {
                    if (-not $header) { return }
                    $readingRows = $true
                } elseif ($section -eq 'clocks') {
                    $header = $header -or $line -match '^\s*Clock\s+Period\s+Waveform\s+Type\s+Loads\s+Loads\s+Sources\s*$'
                } else {
                    $slack = if ($kind -eq 'setup') { 'WNS' } else { 'WHS' }
                    $header = $header -or $line -match "^\s*Launch Clock\s+Capture Clock\s+$slack\(ns\)\s+"
                }
                continue
            }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($section -eq 'clocks') {
                if ($line -notmatch '^\s*(\S+)\s+(\d+(?:\.\d+)?)\s+\{[^{}]*\}\s+(\S+)\s+(\d+)\s+\d+\s+\{(.*)\}\s*$' -or
                    $clocks.Contains($Matches[1])) { return }
                $clocks[$Matches[1]] = @{
                    periodNs = [double]::Parse($Matches[2], $number)
                    type = $Matches[3]
                    loads = [long]$Matches[4]
                    sources = $Matches[5].Trim()
                }
                continue
            }
            if ($line -notmatch '^\s*(\S+)\s+(\S+)\s+(-?\d+(?:\.\d+)?)\s+-?\d+(?:\.\d+)?\s+(\d+)\s+(\d+)\s*$') { return }
            $launch = $Matches[1]
            $capture = $Matches[2]
            $failed = [long]$Matches[4]
            $total = [long]$Matches[5]
            if ($total -lt 1 -or $failed -gt $total -or -not $clockPairs.Add("$section $launch $capture")) { return }
            $checks.Add(@{
                type = $kind; corner = $corner; launchClock = $launch; captureClock = $capture
                slackNs = [double]::Parse($Matches[3], $number); failingEndpoints = $failed; endpoints = $total
            })
        }
    } finally {
        $lines.Dispose()
    }
    if ($closed.Count -ne 5 -or $design -cnotin @('All Constraints Met.', 'Some Constraints Violated.')) { return }
    if ($checks | Where-Object { -not $clocks.Contains($_.launchClock) -or -not $clocks.Contains($_.captureClock) }) { return }
    return @{ clocks = $clocks; checks = @($checks.ToArray()); designSummary = $design }
}

function Add-RtlPangoTimingEvidence($Result, $Settings) {
    $native = Read-RtlPangoTimingReport $Result.reportPath
    if (-not $native) {
        Set-RtlHardwareGateFailure $Result 'error' 'unrecognized_timing_report' 'PDS did not report conclusive setup and hold timing at both corners.'
        return
    }
    $Result.clocks = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($name in $native.clocks.Keys) { $Result.clocks[$name] = $native.clocks[$name].periodNs }
    $Result.clockDetails = $native.clocks
    $Result.checks = $native.checks
    $Result.designSummary = $native.designSummary
    $setup = @($native.checks | Where-Object type -eq 'setup' | Sort-Object { $_.slackNs })
    $hold = @($native.checks | Where-Object type -eq 'hold' | Sort-Object { $_.slackNs })
    $Result.worstSetupSlackNs = if ($setup.Count) { $setup[0].slackNs }
    $Result.worstHoldSlackNs = if ($hold.Count) { $hold[0].slackNs }
    $clockIssues = @(foreach ($name in $Settings.clocks.Keys) {
        $clock = $native.clocks[$name]
        $period = $Settings.clocks[$name]
        if (-not $clock -or $clock.type -notin @('Declared', 'Generated') -or [Math]::Abs($clock.periodNs - $period) -gt 0.0001) {
            "$name expected a declared or generated $period ns clock"
            continue
        }
        if ($clock.loads -le 0 -or -not $clock.sources) {
            "$name has no measured clock loads or source"
            continue
        }
        foreach ($kind in @('setup', 'hold')) {
            foreach ($corner in @('slow', 'fast')) {
                $covered = $native.checks | Where-Object {
                    $_.type -eq $kind -and $_.corner -eq $corner -and ($_.launchClock -ceq $name -or $_.captureClock -ceq $name)
                } | Select-Object -First 1
                if (-not $covered) { "$name has no $kind checks at the $corner corner" }
            }
        }
    })
    if ($clockIssues.Count) {
        Set-RtlHardwareGateFailure $Result 'failed' 'clock_mismatch' "PDS clock requirements were not met. $($clockIssues -join '. ')"
        return
    }
    $Result.violations = @(foreach ($check in $native.checks) {
        $minimum = if ($check.type -eq 'setup') { $Settings.minSetupSlackNs } else { $Settings.minHoldSlackNs }
        if ($check.slackNs -lt $minimum -or $check.failingEndpoints) {
            [ordered]@{
                type = $check.type; corner = $check.corner; launchClock = $check.launchClock; captureClock = $check.captureClock
                slackNs = $check.slackNs; minimumNs = $minimum; failingEndpoints = $check.failingEndpoints
            }
        }
    })
    if ($Result.violations.Count -or $native.designSummary -ne 'All Constraints Met.') {
        $message = "PDS timing did not meet the configured requirements. Setup slack $($Result.worstSetupSlackNs) ns, hold slack $($Result.worstHoldSlackNs) ns. $($native.designSummary)"
        Set-RtlHardwareGateFailure $Result 'failed' 'slack_violation' $message
    }
}

function Read-RtlPangoTranscript($Process, $Actions) {
    $completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $issues = [Collections.Generic.List[object]]::new()
    foreach ($log in @($Process.stdout, $Process.stderr)) {
        $pending = $Actions.Keys | Where-Object { -not $completed.Contains($_) } | Select-Object -First 1
        $stage = if ($pending) { $Actions[$pending] } else { $Actions[$Actions.Count - 1] }
        $duringAction = $false
        foreach ($line in [IO.File]::ReadLines($log)) {
            if ($line -match '^Process "([^"]+)" (started|done)\.\s*$' -and $Actions.Contains($Matches[1])) {
                $stage = $Actions[$Matches[1]]
                $duringAction = $Matches[2] -eq 'started'
                if (-not $duringAction) { $null = $completed.Add($Matches[1]) }
                continue
            }
            if ($line -cnotmatch '^(?<severity>[EWCF]):\s*(?:(?<code>[A-Za-z][A-Za-z0-9_]*-\d+):\s*)?(?<message>\S.*?)\s*$') { continue }
            $message = $Matches['message']
            if ($message -eq 'Failed to execute the script :') { continue }
            $file = $null
            $lineNumber = $null
            $location = [regex]::Match($message, '^\[(.+?)\(line number:\s*(\d+)\)\]\s*\|?\s*(.*)$')
            if ($location.Success) {
                $file = $location.Groups[1].Value
                $lineNumber = [int]$location.Groups[2].Value
                $message = $location.Groups[3].Value
            }
            $issues.Add([ordered]@{
                stage = $stage; duringAction = $duringAction; severity = $Matches['severity']; code = $Matches['code']
                message = $message; file = $file; inputFile = Get-RtlDiagnosticInputFile $file $Process.workingDirectory
                line = $lineNumber; text = $line; log = $log
            })
        }
    }
    return @{ completed = $completed; issues = $issues.ToArray() }
}

function Get-RtlPangoStageResult($Process, $Transcript, [string]$Stage, [string[]]$Actions, [string[]]$Blocking,
                                 [bool]$Last, [int]$TimeLimit) {
    $missing = @($Actions | Where-Object { -not $Transcript.completed.Contains($_) })
    $issues = @($Transcript.issues | Where-Object stage -eq $Stage)
    $warnings = @($issues | Where-Object severity -in 'W', 'C')
    $errors = @($issues | Where-Object severity -in 'E', 'F')
    $toolError = $errors | Where-Object {
        -not $_.duringAction -or $_.severity -eq 'F' -or $_.code -like 'Flow-*' -or
        $_.message -match '(?i)licen[cs]e|internal (?:compiler )?error|(?:cannot|failed to)\s+(?:open|load).*(?:library|database|architecture)'
    } | Select-Object -First 1
    $designError = $errors | Where-Object {
        ($_.inputFile -and [IO.Path]::GetExtension($_.inputFile) -in @('.v', '.sv', '.vh', '.svh')) -or
        $_.code -match '^(?:Verilog|VHDL|Timing|DesignRuleCheck|DeviceMap|Placer|Router)-\d+$' -or
        ($_.code -like 'ConstraintEditor-*' -and $_.message -match '(?i)\bport\b.*(?:not found|absent|no matching)')
    } | Select-Object -First 1
    $errorEntry = if ($toolError) { $toolError } elseif ($designError) { $designError } elseif ($errors.Count) { $errors[0] }
    $blockingWarning = $warnings | Where-Object { $_.code -in $Blocking } | Select-Object -First 1
    $result = [ordered]@{
        engine = 'pango'; status = 'passed'; reason = $null; diagnostic = $null; process = $Process
        warnings = $warnings; firstError = if ($errorEntry) { $errorEntry } else { $blockingWarning }
    }
    if ($Process.timedOut -and ($missing.Count -or $Last)) {
        Set-RtlHardwareGateFailure $result 'error' 'tool_timeout' "PDS exceeded the $TimeLimit second time limit."
    } elseif ($errorEntry) {
        $isToolFailure = $toolError -or -not $designError
        $status = if ($isToolFailure) { 'error' } else { 'failed' }
        $reason = if ($isToolFailure) { 'tool_diagnostic' } else { 'design_diagnostic' }
        Set-RtlHardwareGateFailure $result $status $reason "PDS $Stage reported an error." $errorEntry
    } elseif ($missing.Count -or ($Last -and $Process.exitCode -ne 0)) {
        Set-RtlHardwareGateFailure $result 'error' 'missing_tool_result' "PDS did not finish $Stage."
    } elseif ($blockingWarning) {
        Set-RtlHardwareGateFailure $result 'failed' 'blocking_warning' "PDS $Stage reported $($blockingWarning.code). $($blockingWarning.message)"
    }
    return $result
}

function Add-RtlPangoSynthesisResult($Project, $Report, [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides,
                                    [string]$LogDirectory, [int]$TimeoutSeconds, [string]$Work) {
    $synthesis = $Project.Synthesis
    $name = 'rtlcheck_pango_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $scriptPath = Join-Path $Work "$name.tcl"
    $projectPath = Join-Path $Work "$name.pds"
    Copy-RtlHardwareInputs $Project $ReferenceRoot $Work $Overrides $synthesis.constraintFiles
    $compile = 'compile -top_module ' + (ConvertTo-RtlTclWord $synthesis.top)
    if ($Project.IncludeDirs.Count) {
        $includeDirs = @(foreach ($dir in $Project.IncludeDirs) { ConvertTo-RtlTclWord "./$dir" })
        $compile += ' -include_path [list ' + ($includeDirs -join ' ') + ']'
    }
    if ($Project.Sources | Where-Object { [IO.Path]::GetExtension($_) -eq '.sv' }) { $compile += ' -system_verilog' }
    $actions = [ordered]@{ Compile = 'synthesize'; Synthesize = 'synthesize' }
    $reports = [ordered]@{ synthesize = "synthesize/$($synthesis.top).snr" }
    $script = @(
        "set_arch -family $($synthesis.family) -device $($synthesis.device) -speedgrade $($synthesis.speedGrade) -package $($synthesis.package)"
        foreach ($source in $Project.Sources) { 'add_design ' + (ConvertTo-RtlTclWord "./$source") }
        if ($synthesis.fdc) { 'add_constraint ' + (ConvertTo-RtlTclWord "./$($synthesis.fdc)") }
        $compile
        'synthesize -ads'
    )
    if ($synthesis.board -or $synthesis.timing) {
        $script += @('dev_map', 'pnr')
        $actions['Device Map'] = 'fit'
        $actions['Place & Route'] = 'fit'
        $reports.fit = "place_route/$($synthesis.top).prr"
    }
    if ($synthesis.timing) {
        $script += 'report_timing'
        $actions['Report Timing'] = 'timing'
        $reports.timing = "report_timing/$($synthesis.top).rtr"
    }
    foreach ($relative in $reports.Values) {
        if (Test-Path -LiteralPath (Join-Path $Work $relative)) {
            throw "A project input occupies the PDS report path: $relative"
        }
    }
    [IO.File]::WriteAllLines($scriptPath, [string[]]$script)
    $timeLimit = $actions.Count * $TimeoutSeconds
    Write-RtlProgress 'Running Pango PDS hardware checks...' 'pango'
    $arguments = @('-file', "$name.tcl", '-work_dir', '.', '-project_name', $name)
    $process = Invoke-RtlProcess $synthesis.executable $arguments $Work (Join-Path (Join-Path $LogDirectory 'synthesis') 'pds_shell') $timeLimit
    $transcript = Read-RtlPangoTranscript $process $actions
    $last = @($reports.Keys)[-1]
    foreach ($stage in $reports.Keys) {
        $required = @($actions.Keys | Where-Object { $actions[$_] -eq $stage })
        $result = Get-RtlPangoStageResult $process $transcript $stage $required $synthesis.failOnWarnings ($stage -eq $last) $timeLimit
        $result.reportPath = Join-Path $Work $reports[$stage]
        if ($stage -eq 'synthesize') {
            $result.projectPath = $projectPath
            $result.scriptPath = $scriptPath
        }
        if ($result.status -eq 'passed') {
            if (-not [IO.File]::Exists($result.reportPath) -or [IO.FileInfo]::new($result.reportPath).Length -le 0) {
                Set-RtlHardwareGateFailure $result 'error' 'missing_tool_report' "PDS did not provide a $stage report."
            } elseif ($stage -eq 'fit' -and $synthesis.board) {
                Add-RtlPangoBoardEvidence $result $synthesis.board
            } elseif ($stage -eq 'timing') {
                Add-RtlPangoTimingEvidence $result $synthesis.timing
            }
        }
        Set-RtlHardwareStage $Report $stage $result
        if ($result.status -ne 'passed') { return }
    }
}
