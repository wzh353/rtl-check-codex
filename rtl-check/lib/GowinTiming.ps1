function Read-RtlGowinTimingSettings($Settings, [string[]]$ConstraintFiles) {
    if ($Settings -isnot [System.Collections.IDictionary]) { throw 'synthesis.timing must be an object.' }
    foreach ($key in $Settings.Keys) {
        if ($key -cnotin @('clocks', 'minSetupSlackNs', 'minHoldSlackNs')) { throw "Unknown Gowin synthesis.timing field: $key" }
    }
    $sdc = @($ConstraintFiles | Where-Object { [IO.Path]::GetExtension($_) -eq '.sdc' })
    if ($sdc.Count -ne 1) { throw 'Gowin timing requires an SDC file in synthesis.constraintFiles.' }
    $result = Read-RtlTimingLimits $Settings
    $result.sdcFile = $sdc[0]
    return $result
}

function Read-RtlGowinTimingTable([string[]]$Section, [string]$Header) {
    $lines = @($Section | Where-Object { $_ -cnotlike '<Report Command>:*' })
    if ($lines.Count -eq 1 -and $lines[0] -ceq 'Nothing to report!') { return @{ rows = @() } }
    $columns = $Header.Split('|')
    if ($lines.Count -lt 3 -or (($lines[0].Trim() -split '\s{2,}') -join '|') -cne $Header -or
        $lines[1] -cnotmatch '^\s*(?:=+\s+)*=+\s*$') { return }
    $rules = [regex]::Matches($lines[1], '=+')
    if ($rules.Count -ne $columns.Count) { return }
    $rows = @(for ($index = 2; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Length -le $rules[-1].Index) { return }
        $row = @{}
        for ($column = 0; $column -lt $columns.Count; $column++) {
            $start = $rules[$column].Index
            $end = if ($column + 1 -lt $columns.Count) { $rules[$column + 1].Index } else { $line.Length }
            $row[$columns[$column]] = $line.Substring($start, $end - $start).Trim()
        }
        $row
    })
    return @{ rows = $rows }
}

function ConvertFrom-RtlGowinDecimal([string]$Text) {
    $value = [double]0
    if ([double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
        [double]::IsFinite($value)) { return $value }
}

function Read-RtlGowinTimingReport([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    $headers = @(
        '1. Timing Messages', '2.1 STA Tool Run Summary', '2.2 Clock Summary', '2.4 Total Negative Slack Summary',
        '3.1.1 Setup Paths Table', '3.1.2 Hold Paths Table', '3.8 Timing Constraints Report'
    )
    $sections = @{}
    $core = $false
    $active = $null
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if (-not $core) {
            $core = $line -ceq 'Note:Core Timing Report'
            continue
        }
        if ($line -cmatch '^[0-9.]+ [A-Za-z]') {
            $heading = $line.TrimEnd()
            $active = $null
            if ($heading -cin $headers) {
                if ($sections.ContainsKey($heading)) { return }
                $active = [Collections.Generic.List[string]]::new()
                $sections[$heading] = $active
            }
        }
        elseif ($null -ne $active -and -not [string]::IsNullOrWhiteSpace($line)) { $active.Add($line) }
    }
    if ($sections.Count -ne $headers.Count) { return }

    $fields = @{}
    foreach ($line in $sections[$headers[0]].ToArray() + $sections[$headers[1]].ToArray()) {
        if ($line -cnotmatch '^<(?<key>[^>]+)>:\s*(?<value>.*)$') { continue }
        if ($fields.ContainsKey($Matches.key)) { return }
        $fields[$Matches.key] = $Matches.value.Trim()
    }
    $coverage = [ordered]@{}
    $labels = [ordered]@{
        analyzedPaths = 'Numbers of Paths Analyzed'
        analyzedEndpoints = 'Numbers of Endpoints Analyzed'
        setupViolatingEndpoints = 'Numbers of Setup Violated Endpoints'
        holdViolatingEndpoints = 'Numbers of Hold Violated Endpoints'
    }
    foreach ($key in $labels.Keys) {
        $count = 0
        if (-not [int]::TryParse($fields[$labels[$key]], [ref]$count) -or $count -lt 0) { return }
        $coverage[$key] = $count
    }
    if ($fields['Report Title'] -cne 'Timing Analysis Report' -or -not $fields['Timing Constraints File'] -or
        -not $fields['Setup Delay Model'] -or -not $fields['Hold Delay Model']) { return }

    $clockTable = Read-RtlGowinTimingTable $sections[$headers[2]] 'NO.|Clock Name|Type|Period|Frequency|Rise|Fall|Source|Master|Objects'
    $negativeTable = Read-RtlGowinTimingTable $sections[$headers[3]] 'Clock Name|Analysis Type|EndPoints TNS|Number of EndPoints'
    $constraintTable = Read-RtlGowinTimingTable $sections[$headers[6]] 'SDC Command Type|State|Detail Command'
    if (-not $clockTable -or -not $negativeTable -or -not $constraintTable) { return }
    $clocks = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($row in $clockTable.rows) {
        $period = ConvertFrom-RtlGowinDecimal $row['Period']
        $name = $row['Clock Name']
        if (-not $name -or $clocks.Contains($name) -or $null -eq $period -or $period -le 0) { return }
        $clocks[$name] = @{ periodNs = $period; type = $row['Type'] }
    }
    $negative = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $negativeTable.rows) {
        $kind = $row['Analysis Type'].ToLowerInvariant()
        $name = $row['Clock Name']
        $tns = ConvertFrom-RtlGowinDecimal $row['EndPoints TNS']
        $count = 0
        $key = "$kind/$name"
        if (-not $name -or $kind -notin @('setup', 'hold') -or $negative.ContainsKey($key) -or
            $null -eq $tns -or $tns -gt 0 -or
            -not [int]::TryParse($row['Number of EndPoints'], [ref]$count) -or $count -lt 0 -or ($count -eq 0 -and $tns -lt 0)) { return }
        $negative[$key] = @{ type = $kind; clock = $name; tnsNs = $tns; failingEndpoints = $count }
    }
    $paths = @{}
    $pathHeader = 'Path Number|Path Slack|From Node|To Node|From Clock|To Clock|Relation|Clock Skew|Data Delay'
    foreach ($kind in @('setup', 'hold')) {
        $section = if ($kind -eq 'setup') { $headers[4] } else { $headers[5] }
        $table = Read-RtlGowinTimingTable $sections[$section] $pathHeader
        if (-not $table) { return }
        $index = 0
        $checks = @(foreach ($row in $table.rows) {
            $index++
            $slack = ConvertFrom-RtlGowinDecimal $row['Path Slack']
            if ($row['Path Number'] -cne [string]$index -or $null -eq $slack -or
                -not $row['From Node'] -or -not $row['To Node']) { return }
            [ordered]@{
                type = $kind; slackNs = $slack
                from = $row['From Node']; to = $row['To Node']
                launchClock = $row['From Clock'] -creplace ':\[[RF]\]$', ''
                captureClock = $row['To Clock'] -creplace ':\[[RF]\]$', ''
                dataDelayNs = ConvertFrom-RtlGowinDecimal $row['Data Delay']
            }
        })
        $paths[$kind] = @($checks | Sort-Object slackNs)
        $count = $coverage["$($kind)ViolatingEndpoints"]
        $hasViolations = $null -ne ($negative.Values | Where-Object { $_.type -eq $kind -and $_.failingEndpoints -gt 0 } | Select-Object -First 1)
        if (($count -gt 0) -ne $hasViolations -or
            ($checks.Count -and (($count -eq 0 -and $paths[$kind][0].slackNs -lt 0) -or
                ($count -gt 0 -and $paths[$kind][0].slackNs -gt 0)))) { return }
    }
    return @{
        constraintFile = $fields['Timing Constraints File']; clocks = $clocks
        coverage = $coverage; paths = $paths; negative = $negative; constraints = $constraintTable.rows
        setupDelayModel = $fields['Setup Delay Model']; holdDelayModel = $fields['Hold Delay Model']
    }
}

function Add-RtlGowinTimingEvidence($Result, $Settings, [string]$ExecutionWork, [string]$ReportedWork) {
    $native = Read-RtlGowinTimingReport $Result.reportPath
    if (-not $native) {
        Set-RtlHardwareGateFailure $Result 'error' 'unrecognized_timing_report' 'Gowin did not provide a complete, consistent post-route timing report.'
        return
    }
    $sdc = Get-RtlDiagnosticInputFile $native.constraintFile $ExecutionWork
    if (-not $sdc) { $sdc = Get-RtlDiagnosticInputFile $native.constraintFile $ReportedWork }
    $Result.sdcFile = $sdc
    if (($IsWindows -and $sdc -ne $Settings.sdcFile) -or (-not $IsWindows -and $sdc -cne $Settings.sdcFile)) {
        Set-RtlHardwareGateFailure $Result 'error' 'sdc_not_read' "Gowin timing did not report the configured SDC file '$($Settings.sdcFile)'."
        return
    }
    $Result.clocks = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($name in $native.clocks.Keys) { $Result.clocks[$name] = $native.clocks[$name].periodNs }
    $Result.coverage = $native.coverage
    $Result.delayModels = @{ setup = $native.setupDelayModel; hold = $native.holdDelayModel }
    $Result.worstSetupSlackNs = if ($native.paths.setup.Count) { $native.paths.setup[0].slackNs }
    $Result.worstHoldSlackNs = if ($native.paths.hold.Count) { $native.paths.hold[0].slackNs }
    $Result.worstPaths = @($native.paths.setup | Select-Object -First 1) + @($native.paths.hold | Select-Object -First 1)
    $clockCommands = @($native.constraints | Where-Object { $_['Detail Command'] -match '^create_(?:generated_)?clock\s' })
    foreach ($name in $Settings.clocks.Keys) {
        $expected = $Settings.clocks[$name]
        $actual = $Result.clocks[$name]
        if ($null -eq $actual -or [Math]::Abs($actual - $expected) -gt 0.0005) {
            $observed = if ($null -eq $actual) { 'missing' } else { "$actual ns" }
            Set-RtlHardwareGateFailure $Result 'error' 'clock_mismatch' "Gowin clock '$name' expected $expected ns, reported $observed."
            return
        }
        foreach ($kind in @('setup', 'hold')) {
            $path = $native.paths[$kind] | Where-Object { $_.launchClock -ceq $name -or $_.captureClock -ceq $name } | Select-Object -First 1
            if (-not $path -or -not $native.negative.ContainsKey("$kind/$name")) {
                Set-RtlHardwareGateFailure $Result 'error' 'missing_checks' "Gowin did not report a measured $kind path for clock '$name'."
                return
            }
        }
    }
    if (-not ($clockCommands | Where-Object { $_['State'] -in @('Active', 'Actived') })) {
        Set-RtlHardwareGateFailure $Result 'error' 'inactive_constraints' 'Gowin did not report an active SDC clock constraint.'
        return
    }
    $limits = @{ setup = $Settings.minSetupSlackNs; hold = $Settings.minHoldSlackNs }
    $Result.violations = @(foreach ($path in $Result.worstPaths) {
        $minimum = $limits[$path.type]
        $endpoints = $Result.coverage["$($path.type)ViolatingEndpoints"]
        if ($path.slackNs -lt $minimum -or $endpoints -gt 0) {
            [ordered]@{ type = $path.type; slackNs = $path.slackNs; minimumNs = $minimum; failingEndpoints = $endpoints }
        }
    })
    if ($Result.violations.Count) {
        Set-RtlHardwareGateFailure $Result 'failed' 'slack_violation' "Gowin post-route timing failed. Setup slack $($Result.worstSetupSlackNs) ns, hold slack $($Result.worstHoldSlackNs) ns."
    }
}
