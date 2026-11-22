function Read-RtlBoardSettings([string]$Root, $Settings) {
    if ($Settings -isnot [System.Collections.IDictionary]) { throw 'synthesis.board must be an object.' }
    foreach ($key in $Settings.Keys) {
        if ($key -cnotin @('qsf', 'requireAllPins')) { throw "Unknown synthesis.board field: $key" }
    }
    $qsf = Resolve-RtlProjectItem $Root $Settings['qsf']
    if ([IO.Path]::GetExtension($qsf) -ne '.qsf') { throw 'synthesis.board.qsf must name a Quartus Settings File.' }
    if ($Settings.Contains('requireAllPins') -and $Settings['requireAllPins'] -isnot [bool]) {
        throw 'synthesis.board.requireAllPins must be a boolean.'
    }
    return @{
        qsf = $qsf
        requireAllPins = if ($Settings.Contains('requireAllPins')) { $Settings['requireAllPins'] } else { $true }
        profile = $null
    }
}

function Remove-RtlQsfQuotes([string]$Value) {
    if ($Value.StartsWith('"') -or $Value.StartsWith('{')) { return $Value.Substring(1, $Value.Length - 2) }
    return $Value
}

function Read-RtlBoardProfile([string]$Path, $Synthesis) {
    $literal = '(?:"[^"]*"|\{[^{}]*\}|[^\s";{}#]+)'
    $end = '(?:\s+#.*)?$'
    $portName = '[A-Za-z_][A-Za-z0-9_$]*'
    $locations = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $standards = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $usedPins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $globals = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unusedSettings = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $assignments = [Collections.Generic.List[string]]::new()
    $defaultStandard = $null
    $lineNumber = 0
    $boardGlobals = '^(?:FAMILY|DEVICE|STRATIX_DEVICE_IO_STANDARD|SEED|MIN_CORE_JUNCTION_TEMP|MAX_CORE_JUNCTION_TEMP|USE_CONFIGURATION_DEVICE|CRC_ERROR_OPEN_DRAIN|RESERVE_ALL_UNUSED_PINS|(?:CYCLONEII_)?RESERVE_[A-Z0-9_]+_AFTER_CONFIGURATION|OUTPUT_IO_TIMING_(?:NEAR|FAR)_END_VMEAS|POWER_BOARD_THERMAL_MODEL|POWER_PRESET_COOLING_SOLUTION)$'
    foreach ($raw in [IO.File]::ReadLines($Path)) {
        $lineNumber++
        $line = $raw.Trim()
        $where = "$($Synthesis.board.qsf):$lineNumber"
        if ($line.EndsWith('\')) { throw "Use a single literal QSF statement per line in $where." }
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^set_location_assignment\b') {
            if ($line -notmatch ("^set_location_assignment\s+(?<pin>$literal)\s+-to\s+(?<port>$literal)" + $end)) {
                throw "Expected a literal pin and port in $where."
            }
            $pin = (Remove-RtlQsfQuotes $Matches['pin']).ToUpperInvariant()
            $port = Remove-RtlQsfQuotes $Matches['port']
            if ($pin -notmatch '^PIN_[A-Z]*[0-9]+$' -or $port -cnotmatch ('^' + $portName + '(?:\[-?\d+\])?$')) {
                throw "Invalid package pin or port in $where."
            }
            if ($locations.Contains($port) -or -not $usedPins.Add($pin)) { throw "Duplicate board location for $port or $pin in $where." }
            $locations[$port] = $pin
            $assignments.Add("set_location_assignment $pin -to $port")
        }
        elseif ($line -match '^set_instance_assignment\s+.*-name\s+IO_STANDARD\b') {
            $standardFirst = "^set_instance_assignment\s+-name\s+IO_STANDARD\s+(?<value>$literal)\s+-to\s+(?<port>$literal)" + $end
            $portFirst = "^set_instance_assignment\s+-to\s+(?<port>$literal)\s+-name\s+IO_STANDARD\s+(?<value>$literal)" + $end
            if ($line -notmatch $standardFirst -and $line -notmatch $portFirst) { throw "Expected a literal I/O standard and port in $where." }
            $port = Remove-RtlQsfQuotes $Matches['port']
            $value = Remove-RtlQsfQuotes $Matches['value']
            if ($port -cnotmatch ('^(?:\*|' + $portName + '(?:\[(?:-?\d+|\*)\])?)$') -or
                [string]::IsNullOrWhiteSpace($value) -or $standards.Contains($port)) {
                throw "Invalid or repeated board I/O standard for $port in $where."
            }
            $standards[$port] = $value
            $assignments.Add("set_instance_assignment -name IO_STANDARD $(ConvertTo-RtlTclWord $value) -to $port")
        }
        elseif ($line -match '^set_global_assignment\s+-name\s+([A-Z0-9_]+)\b' -and $Matches[1] -match $boardGlobals) {
            if ($line -notmatch ("^set_global_assignment\s+-name\s+(?<name>[A-Z0-9_]+)\s+(?<value>$literal)(?:\s+(?<edge>-rise|-fall))?" + $end)) {
                throw "Expected a literal board setting in $where."
            }
            $name = $Matches['name'].ToUpperInvariant()
            $edge = $Matches['edge']
            $value = Remove-RtlQsfQuotes $Matches['value']
            if ([string]::IsNullOrWhiteSpace($value) -or -not $globals.Add("$name$edge") -or
                ($edge -and $name -notlike 'OUTPUT_IO_TIMING_*_END_VMEAS')) {
                throw "Invalid or repeated board setting $name in $where."
            }
            if ($name -in @('DEVICE', 'FAMILY')) {
                if ($value -ne $Synthesis[$name.ToLowerInvariant()]) { throw "Board $name '$value' disagrees with synthesis in $where." }
                continue
            }
            if ($name -eq 'STRATIX_DEVICE_IO_STANDARD') { $defaultStandard = $value }
            $assignments.Add(("set_global_assignment -name $name $(ConvertTo-RtlTclWord $value) $edge").TrimEnd())
        } else {
            if ($line -notmatch ('^(?:set_global_assignment|set_instance_assignment|set_parameter)(?:\s+' + $literal + ')+' + $end)) {
                throw "Expected a standalone QSF assignment or comment in $where."
            }
            if ($line -match ('(?:^|\s)-name\s+(?<name>' + $literal + ')')) {
                $null = $unusedSettings.Add((Remove-RtlQsfQuotes $Matches['name']).ToUpperInvariant())
            }
        }
    }
    if ($locations.get_Count() -eq 0) { throw "No physical pin assignments found in $($Synthesis.board.qsf)." }
    return @{
        locations = $locations
        standards = $standards
        defaultStandard = $defaultStandard
        assignments = $assignments.ToArray()
        unusedQsfSettings = @($unusedSettings | Sort-Object)
    }
}

function Read-RtlFitterPins([string]$ReportPath) {
    $pins = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $sections = @{ 'Input Pins' = 'input'; 'Output Pins' = 'output'; 'Bidir Pins' = 'bidir'; 'Bidirectional Pins' = 'bidir' }
    $direction = $null
    $headers = $null
    foreach ($line in [IO.File]::ReadLines($ReportPath)) {
        if (-not $line.StartsWith(';') -or -not $line.TrimEnd().EndsWith(';')) { continue }
        $columns = @($line.Trim().Trim(';').Split(';').Trim())
        if ($columns.Count -eq 1) {
            $direction = $sections[$columns[0]]
            $headers = $null
        } elseif ($direction -and -not $headers) {
            if ($columns[0] -cne 'Name') { return }
            $headers = $columns
            $pinIndex = [array]::IndexOf($headers, 'Pin #')
            $ioIndex = [array]::IndexOf($headers, 'I/O Standard')
            $ownerIndex = [array]::IndexOf($headers, 'Location assigned by')
            if ($pinIndex -lt 0 -or $ioIndex -lt 0 -or $ownerIndex -lt 0) { return }
        } elseif ($direction -and $headers) {
            if ($columns.Count -ne $headers.Count -or $pins.Contains($columns[0])) { return }
            $location = $columns[$pinIndex].ToUpperInvariant()
            if ($location -notmatch '^(?:PIN_)?[A-Z]*[0-9]+$') { return }
            $pins[$columns[0]] = [ordered]@{
                pin = 'PIN_' + ($location -replace '^PIN_', '')
                direction = $direction
                ioStandard = $columns[$ioIndex]
                assignedBy = $columns[$ownerIndex]
            }
        }
    }
    return $pins
}

function Add-RtlBoardEvidence($Fit, $Board) {
    if (-not [IO.File]::Exists($Fit.reportPath) -or -not $Fit.resources.Contains('pins')) {
        Set-RtlHardwareGateFailure $Fit 'error' 'board_evidence_missing' 'The Fitter reports did not provide both the implemented ports and total pin count.'
        return
    }
    $pins = Read-RtlFitterPins $Fit.reportPath
    if (-not $pins -or $pins.get_Count() -ne $Fit.resources.pins) {
        Set-RtlHardwareGateFailure $Fit 'error' 'board_evidence_missing' 'The physical pin table could not be reconciled with the Fitter pin count.'
        return
    }
    $profile = $Board.profile
    $mismatches = [Collections.Generic.List[object]]::new()
    $matchedPins = 0
    $matchedStandards = 0
    foreach ($entry in $profile.locations.GetEnumerator()) {
        $port = $entry.Key
        $actual = $pins[$port]
        if (-not $actual) {
            $mismatches.Add(@{ kind = 'missing_port'; port = $port; expected = $entry.Value; actual = $null })
        } elseif ($actual.pin -ne $entry.Value -or $actual.assignedBy -ne 'User') {
            $mismatches.Add(@{ kind = 'pin_mismatch'; port = $port; expected = $entry.Value; actual = "$($actual.pin) ($($actual.assignedBy))" })
        } else { $matchedPins++ }
    }
    $matchedStandardTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $pins.GetEnumerator()) {
        $port = $entry.Key
        if ($Board.requireAllPins -and -not $profile.locations.Contains($port)) {
            $mismatches.Add(@{ kind = 'unpinned_port'; port = $port; expected = 'an explicit location'; actual = $entry.Value.pin })
        }
        $bus = if ($port -cmatch '^(.+)\[-?\d+\]$') { $Matches[1] + '[*]' }
        $targets = @($port, $bus, '*' | Where-Object { $_ -and $profile.standards.Contains($_) })
        foreach ($target in $targets) { $null = $matchedStandardTargets.Add($target) }
        $expected = if ($targets.Count) { $profile.standards[$targets[0]] } else { $profile.defaultStandard }
        $standard = $entry.Value.ioStandard
        if ($expected -and ($standard -replace '[\s-]+', '') -ne ($expected -replace '[\s-]+', '')) {
            $mismatches.Add(@{ kind = 'io_standard_mismatch'; port = $port; expected = $expected; actual = $standard })
        } elseif ($expected) {
            $matchedStandards++
        } elseif ($Board.requireAllPins) {
            $mismatches.Add(@{ kind = 'missing_io_standard'; port = $port; expected = 'an explicit I/O standard'; actual = $standard })
        }
    }
    foreach ($setting in $profile.standards.GetEnumerator()) {
        if (-not $matchedStandardTargets.Contains($setting.Key)) {
            $mismatches.Add(@{ kind = 'missing_io_target'; port = $setting.Key; expected = $setting.Value; actual = $null })
        }
    }
    $count = $pins.get_Count()
    $Fit.board = [ordered]@{
        status = if ($mismatches.Count) { 'failed' } else { 'passed' }
        qsf = $Board.qsf
        complete = $mismatches.Count -eq 0 -and $matchedPins -eq $count -and $matchedStandards -eq $count
        portCount = $count
        matchedPinCount = $matchedPins
        matchedIoStandardCount = $matchedStandards
        unusedQsfSettings = $profile.unusedQsfSettings
        pins = $pins
        mismatches = $mismatches.ToArray()
    }
    if ($mismatches.Count) {
        $first = $mismatches[0]
        $actual = if ($first.actual) { $first.actual } else { 'missing' }
        Set-RtlHardwareGateFailure $Fit 'failed' 'board_mismatch' "Board check failed for '$($first.port)' ($($first.kind)). Expected $($first.expected), reported $actual."
    }
}
