function Get-RtlWaveformAcceptanceSuite($Project, [string]$Regression) {
    if (-not $Regression) { return $Project }
    return $Project.Regressions | Where-Object { $_.Id -ceq $Regression } | Select-Object -First 1
}

function Read-RtlWaveformAcceptanceSettings($Project, $Settings) {
    if ($Settings -isnot [System.Collections.IDictionary]) { throw 'waveformAcceptance must be an object.' }
    $keys = @('regression', 'observer', 'observerTop', 'signals', 'expectedSource', 'locations')
    foreach ($key in $Settings.Keys) {
        if ($key -cnotin $keys) { throw "Unknown waveformAcceptance field: $key" }
    }
    $regression = $Settings['regression']
    if ($Settings.Contains('regression') -and ($regression -isnot [string] -or [string]::IsNullOrWhiteSpace($regression))) {
        throw 'waveformAcceptance.regression must name a public regression.'
    }
    $suite = Get-RtlWaveformAcceptanceSuite $Project $regression
    if (-not $suite -or -not $suite.Testbenches.Count) {
        throw 'Waveform acceptance requires a public self-checking testbench.'
    }
    if ($Settings['observerTop'] -isnot [string] -or $Settings['observerTop'] -cnotmatch '\A[A-Za-z_][A-Za-z0-9_$]*\z' -or
        $Settings['observerTop'] -ceq $suite.Top) {
        throw 'waveformAcceptance.observerTop must name a separate Verilog module.'
    }
    $observer = Resolve-RtlProjectItem $Project.Root $Settings['observer']
    if ([IO.Path]::GetExtension($observer) -notin @('.v', '.sv') -or $observer -in @(Get-RtlBaselineFiles $Project)) {
        throw 'The waveform observer must be a separate Verilog file used only for export.'
    }
    $signals = (Read-RtlWaveformSettings @{ signals = $Settings['signals'] } $suite.Top).signals
    if ($Settings['expectedSource'] -cnotin @('testbench', 'reference_model')) {
        throw 'waveformAcceptance.expectedSource must be testbench or reference_model.'
    }
    if ($Settings['locations'] -isnot [System.Collections.IDictionary] -or -not $Settings['locations'].Count) {
        throw 'waveformAcceptance.locations must map check IDs to public testbench files and line anchors.'
    }
    $locations = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($id in $Settings['locations'].Keys) {
        $site = $Settings['locations'][$id]
        if ($id -cnotmatch '\A[A-Za-z_][A-Za-z0-9_-]*\z' -or $site -isnot [System.Collections.IDictionary] -or
            ($site.Keys | Where-Object { $_ -cnotin @('file', 'anchor') }) -or $site['anchor'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($site['anchor']) -or $site['anchor'] -match '[\r\n]') {
            throw "Invalid waveform acceptance check location '$id'."
        }
        $file = Resolve-RtlProjectItem $Project.Root $site['file']
        if ($file -cnotin $suite.Testbenches) { throw "Waveform acceptance check '$id' must point into the selected public testbench." }
        $locations[$id] = @{ file = $file; anchor = $site['anchor'].Trim() }
    }
    return @{
        case = if ($regression) { $regression } else { 'primary' }
        regression = $regression; observer = $observer; observerTop = $Settings['observerTop']
        expectedSource = $Settings['expectedSource']; signals = $signals; locations = $locations
    }
}

function New-RtlWaveformAcceptanceReport($Settings) {
    return [ordered]@{
        status = 'not_run'; diagnostic = 'Waveform export runs after project acceptance passes.'
        case = $Settings.case; top = $null; expectedSource = $Settings.expectedSource
        rtlSha256 = $null; testInputSha256 = $null; observerSha256 = $null
        rtlFiles = @(); testInputFiles = @(); testParameters = $null
        timescale = $null; timeUnit = 'ns'; randomSeeds = $null; sampleCount = 0
        vcdPath = $null; gtkwPath = $null; stimulusPath = $null; openCommand = $null
        samplingLogPath = $null; compile = $null; simulate = $null
    }
}

function Get-RtlWaveformAcceptanceLocations($Settings, [string]$Work) {
    $locations = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($id in $Settings.locations.Keys) {
        $site = $Settings.locations[$id]
        $number = 0
        $matches = @(foreach ($line in [IO.File]::ReadLines((Join-Path $Work $site.file))) {
            $number++
            if ($line.Trim() -ceq $site.anchor) { $number }
        })
        if ($matches.Count -ne 1) { throw "Check '$id' must match one line in $($site.file)." }
        $locations[$id] = "$($site.file):$($matches[0])"
    }
    return $locations
}

function Read-RtlWaveformAcceptanceVcd([string]$Path, [string[]]$Signals) {
    $variables = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scope = [Collections.Generic.List[string]]::new()
    $timescale = $null
    $header = $true
    $lastTick = [ulong]0
    $reader = [IO.StreamReader]::new($Path)
    try {
        while ($null -ne ($raw = $reader.ReadLine())) {
            $line = $raw.Trim()
            if ($header) {
                switch -CaseSensitive -Regex ($line) {
                    '^\$timescale$' { $timescale = $reader.ReadLine() }
                    '^\$timescale\s+(.+?)\s+\$end$' { $timescale = $Matches[1] }
                    '^\$scope\s+\S+\s+(\S+)\s+\$end$' { $scope.Add($Matches[1]) }
                    '^\$upscope\s+\$end$' {
                        if (-not $scope.Count) { throw 'The VCD scope is incomplete.' }
                        $scope.RemoveAt($scope.Count - 1)
                    }
                    '^\$var\s+(?:wire|reg|logic|integer|parameter|event|tri)\s+(\d+)\s+(\S+)\s+(\S+)(?:\s+(\[-?\d+(?::-?\d+)?\]))?\s+\$end$' {
                        $name = ($scope.ToArray() + $Matches[3]) -join '.'
                        if ($name -cin $Signals) {
                            $variables.Add($name, @{
                                leaf = $Matches[3]; id = $Matches[2]; width = [int]$Matches[1]
                                viewName = $name + $Matches[4]
                            })
                        }
                    }
                    '^\$enddefinitions\s+\$end$' { $header = $false }
                }
                continue
            }
            if ($line -cmatch '^#(\d+)$') {
                $tick = [ulong]$Matches[1]
                if ($tick -lt $lastTick) { throw 'The VCD timestamps are out of order.' }
                $lastTick = $tick
            } elseif ($line -match '^(?:b[01xz]+\s+|[01xz])(\S+)$') {
                $null = $seen.Add($Matches[1])
            }
        }
    }
    finally { $reader.Dispose() }
    $scaleParts = [regex]::Match([string]$timescale, '^\s*(1|10|100)\s*(fs|ps|ns|us|ms|s)\s*$')
    if ($header -or $scope.Count -or -not $scaleParts.Success) {
        throw 'The VCD did not provide a complete header and timescale.'
    }
    $scale = [decimal]$scaleParts.Groups[1].Value
    $unit = $scaleParts.Groups[2].Value
    $ns = @{ fs = 0.000001; ps = 0.001; ns = 1; us = 1e3; ms = 1e6; s = 1e9 }
    foreach ($signal in $Signals) {
        if (-not $variables.ContainsKey($signal) -or -not $seen.Contains($variables[$signal].id)) {
            throw "The VCD did not contain samples for '$signal'."
        }
    }
    return @{ timescale = "$scale$unit"; tickNs = $scale * [decimal]$ns[$unit]; lastTick = $lastTick; variables = $variables }
}

function Read-RtlWaveformAcceptanceValues([string]$Text, $Variables, [switch]$AllowMissing) {
    $values = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    if ($Text -ceq '-' -and $AllowMissing) { return $values }
    foreach ($entry in $Text.Split(',')) {
        if ($entry -notmatch '\A(?<name>[A-Za-z_][A-Za-z0-9_$.]*)=(?<bits>[01xz]+)\z') {
            throw 'Observer values must be comma-separated name=bits with 0, 1, X or Z.'
        }
        $name = $Matches.name
        $bits = $Matches.bits.ToUpperInvariant()
        $variable = if ($Variables.ContainsKey($name)) { $Variables[$name] } else {
            $Variables.Values | Where-Object { $_.leaf -ceq $name }
        }
        if (@($variable).Count -ne 1 -or $null -eq $variable -or $variable.width -ne $bits.Length -or $values.Contains($name)) {
            throw "Observer value '$name' must match one selected VCD signal and its bit width."
        }
        $values[$name] = $bits
    }
    return $values
}

function Read-RtlWaveformAcceptanceLog([string]$Path, $Vcd, $Locations) {
    $seeds = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $seedless = $false
    $drives = [Collections.Generic.Dictionary[ulong, object]]::new()
    $samples = [Collections.Generic.List[object]]::new()
    $lastSample = [ulong]0
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if (-not $line.StartsWith('RTL_WAVE_', [StringComparison]::Ordinal)) { continue }
        $fields = $line.Split('|')
        switch -CaseSensitive ($fields[0]) {
            'RTL_WAVE_SEED' {
                if ($fields.Count -eq 2 -and $fields[1] -ceq 'none' -and -not $seedless -and -not $seeds.Count) {
                    $seedless = $true
                } elseif (-not $seedless -and $fields.Count -eq 3 -and
                    $fields[1] -cmatch '\A[A-Za-z_][A-Za-z0-9_]*\z' -and $fields[2] -cmatch '\A-?\d+\z' -and
                    -not $seeds.Contains($fields[1])) {
                    $seeds[$fields[1]] = $fields[2]
                } else { throw 'Invalid or duplicate observer seed record.' }
            }
            'RTL_WAVE_DRIVE' {
                $tick = [ulong]0
                if ($fields.Count -ne 3 -or -not [ulong]::TryParse($fields[1], [ref]$tick) -or
                    $tick -gt $Vcd.lastTick -or $drives.ContainsKey($tick)) { throw 'Invalid or duplicate observer drive record.' }
                $drives.Add($tick, (Read-RtlWaveformAcceptanceValues $fields[2] $Vcd.variables))
            }
            'RTL_WAVE_SAMPLE' {
                $drive = [ulong]0
                $sample = [ulong]0
                if ($fields.Count -ne 7 -or -not [ulong]::TryParse($fields[1], [ref]$drive) -or
                    -not [ulong]::TryParse($fields[2], [ref]$sample) -or $sample -lt $drive -or
                    $sample -lt $lastSample -or $sample -gt $Vcd.lastTick -or
                    [string]::IsNullOrWhiteSpace($fields[3]) -or -not $Locations.Contains($fields[4])) {
                    throw 'Invalid observer sample time, scene or check location.'
                }
                $expected = Read-RtlWaveformAcceptanceValues $fields[5] $Vcd.variables -AllowMissing
                $actual = Read-RtlWaveformAcceptanceValues $fields[6] $Vcd.variables
                foreach ($name in $expected.Keys) {
                    if (-not $actual.Contains($name) -or $actual[$name] -cne $expected[$name]) {
                        throw "Replay sample $sample disagrees with the recorded expectation for '$name'."
                    }
                }
                $samples.Add(@{
                    scene = $fields[3]; driveTick = $drive; sampleTick = $sample; location = $Locations[$fields[4]]
                    expected = $expected; actual = $actual
                })
                $lastSample = $sample
            }
            default { throw 'Unrecognized waveform observer record.' }
        }
    }
    if (-not $samples.Count -or (-not $seedless -and -not $seeds.Count)) {
        throw 'The observer must report at least one assertion sample and its random seeds or explicit seedless status.'
    }
    foreach ($sample in $samples) {
        if (-not $drives.ContainsKey($sample.driveTick)) { throw "No drive record at tick $($sample.driveTick)." }
        $sample.inputs = $drives[$sample.driveTick]
    }
    return @{ samples = $samples.ToArray(); seeds = @{ status = if ($seedless) { 'not_used' } else { 'recorded' }; values = $seeds } }
}

function Format-RtlWaveformAcceptanceValues($Values, [string[]]$Names) {
    $items = foreach ($name in $Names) {
        $value = $Values[$name]
        if ($null -eq $value) { $value = '未指定' }
        elseif ($value.Length -le 64 -and $value -cmatch '\A[01]+\z') { $value = [Convert]::ToUInt64($value, 2) }
        "$name=$value"
    }
    return $items -join ', '
}

function Write-RtlWaveformAcceptanceTable([string]$Path, $Report, $Settings, $Trace, [decimal]$TickNs) {
    $expectedFrom = if ($Settings.expectedSource -eq 'reference_model') { "观察模块 $($Settings.observer) 中的参考模型" } else { '所列测试台位置的断言' }
    $seeds = if ($Trace.seeds.status -eq 'not_used') { '未使用' } else {
        @($Trace.seeds.values.Keys | ForEach-Object { "$_=$($Trace.seeds.values[$_])" }) -join ', '
    }
    $lines = @(
        '# 波形验收对照表', ''
        "公开用例 $($Report.case) 已通过原断言。VCD 时基为 $($Report.timescale)，表格时间以 ns 计。"
        "RTL 摘要为 $($Report.rtlSha256)。测试输入与原参数摘要为 $($Report.testInputSha256)。随机种子为 $seeds。"
        "输入取自驱动记录，实测输出取自采样记录。预期输出来自$expectedFrom。没有提供的预期值标为未指定。"
        '[同一次回放的采样日志](../replay/simulate.stdout.log)', ''
        '| 场景 | 输入驱动时刻 | 输出采样时刻 | DUT 输入 | 预期输出 | 实测输出 | 测试台位置 |'
        '| --- | --- | --- | --- | --- | --- | --- |'
    )
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $rows = foreach ($sample in $Trace.samples) {
        $drive = ([decimal]$sample.driveTick * $TickNs).ToString('0.######', $invariant)
        $time = ([decimal]$sample.sampleTick * $TickNs).ToString('0.######', $invariant)
        $inputs = Format-RtlWaveformAcceptanceValues $sample.inputs @($sample.inputs.Keys)
        $expected = Format-RtlWaveformAcceptanceValues $sample.expected @($sample.actual.Keys)
        $actual = Format-RtlWaveformAcceptanceValues $sample.actual @($sample.actual.Keys)
        $location = $sample.location.Replace('|', '\|')
        "| $($sample.scene) | $drive ns | $time ns | $inputs | $expected | $actual | $location |"
    }
    [IO.File]::WriteAllLines($Path, [string[]]($lines + $rows))
}

function Export-RtlWaveformAcceptance($Project, $Summary, [string]$Baseline, [System.Collections.IDictionary]$Overrides,
                                      [string]$Compiler, [string]$Simulator, [int]$TimeoutSeconds) {
    $settings = $Project.WaveformAcceptance
    $result = New-RtlWaveformAcceptanceReport $settings
    $Summary.waveformAcceptance = $result
    $suite = Get-RtlWaveformAcceptanceSuite $Project $settings.regression
    $result.top = $suite.Top
    if ($suite.Simulator.engine -ne 'icarus') {
        $result.status = 'unsupported_simulator'
        $result.diagnostic = 'Waveform acceptance currently requires Icarus.'
        return
    }
    $phase = 'export_error'
    try {
        Assert-RtlCheckActive
        Write-RtlProgress "Exporting verified waveform for '$($settings.case)'..." 'waveform-acceptance'
        $directory = Join-Path $Summary.runDirectory 'waveform-acceptance'
        $replayDirectory = Join-Path $directory 'replay'
        $work = Join-Path $replayDirectory 'work'
        Copy-RtlInputs $suite $Baseline $work -Files @($suite.InputFiles + $settings.observer)
        if ($Overrides) { Write-RtlFiles $work $Overrides }
        $result.rtlFiles = @($suite.Sources)
        $result.testInputFiles = @($suite.Testbenches + $suite.SimulationSources + $suite.SupportFiles | Sort-Object -Unique)
        $result.rtlSha256 = Get-RtlInputDigest $work $result.rtlFiles
        $result.observerSha256 = (Get-FileHash -LiteralPath (Join-Path $work $settings.observer)).Hash
        $result.testParameters = [ordered]@{
            compile = @(Get-RtlCompileArguments $suite '<program>'); simulate = @('-N', '<program>')
            passMarker = $suite.PassMarker; engine = 'icarus'
        }
        $testInputs = [ordered]@{
            fileDigest = Get-RtlInputDigest $work $result.testInputFiles
            parameters = $result.testParameters
        } | ConvertTo-Json -Depth 6 -Compress
        $result.testInputSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($testInputs)))
        $frozen = @($suite.InputFiles + $settings.observer | Sort-Object -Unique)
        $fingerprint = Get-RtlInputDigest $work $frozen
        if (-not $fingerprint) { throw 'Could not bind the waveform replay to its input snapshot.' }
        $phase = 'invalid_evidence'
        $locations = Get-RtlWaveformAcceptanceLocations $settings $work

        $probe = 'rtlcheck_accept_' + [guid]::NewGuid().ToString('N')
        $limit = 32MB
        $probeText = @"
module $probe;
    initial begin
        `$dumpfile("../waveform.vcd");
        `$dumplimit($limit);
        `$dumpvars(1, $($settings.signals -join ', '));
    end
endmodule
"@
        [IO.File]::WriteAllText((Join-Path $replayDirectory 'probe.sv'), $probeText)
        $tops = @($settings.observerTop, $probe)
        $sources = @("./$($settings.observer)", '../probe.sv')
        $phase = 'replay_failed'
        $replay = Invoke-RtlIcarusCheck $suite $work $replayDirectory $Compiler $Simulator $TimeoutSeconds $tops $sources
        $result.compile = $replay.compile
        $result.simulate = $replay.simulate
        $result.samplingLogPath = if ($replay.simulate) { $replay.simulate.stdout }
        if ($replay.status -ne 'passed') {
            $result.status = if ($replay.stage -eq 'compile') { 'compile_failed' } else { 'replay_failed' }
            $result.diagnostic = $replay.diagnostic
            return
        }
        $phase = 'invalid_evidence'
        if ((Get-RtlInputDigest $work $frozen) -cne $fingerprint) { throw 'A replay input changed during simulation.' }
        $vcd = Join-Path $replayDirectory 'waveform.vcd'
        if (-not [IO.File]::Exists($vcd)) { throw 'The passing replay did not produce its VCD.' }
        if ([IO.FileInfo]::new($vcd).Length -ge $limit -or
            (Select-String -LiteralPath @($replay.simulate.stdout, $replay.simulate.stderr) -Pattern '^WARNING: Dump file limit' -Quiet)) {
            $result.status = 'capture_limit'
            $result.diagnostic = 'The replay reached the 32 MiB waveform limit.'
            return
        }
        $capture = Read-RtlWaveformAcceptanceVcd $vcd $settings.signals
        $trace = Read-RtlWaveformAcceptanceLog $result.samplingLogPath $capture $locations
        $result.timescale = $capture.timescale
        $result.randomSeeds = $trace.seeds
        $result.sampleCount = $trace.samples.Count
        Assert-RtlCheckActive

        $phase = 'export_error'
        $pending = Join-Path $directory 'pending'
        $artifacts = Join-Path $directory 'artifacts'
        $null = [IO.Directory]::CreateDirectory($pending)
        $gtkw = @(
            '[*] GTKWave save file'
            ('[dumpfile] "' + (Join-Path $artifacts 'waveform.vcd').Replace('\', '/') + '"')
            '@28'
        )
        $gtkw += @(foreach ($signal in $settings.signals) { $capture.variables[$signal].viewName })
        [IO.File]::WriteAllLines((Join-Path $pending 'waveform.gtkw'), [string[]]$gtkw)
        Write-RtlWaveformAcceptanceTable (Join-Path $pending 'stimulus.md') $result $settings $trace $capture.tickNs
        [IO.File]::Move($vcd, (Join-Path $pending 'waveform.vcd'))
        [IO.Directory]::Move($pending, $artifacts)
        $result.vcdPath = Join-Path $artifacts 'waveform.vcd'
        $result.gtkwPath = Join-Path $artifacts 'waveform.gtkw'
        $result.stimulusPath = Join-Path $artifacts 'stimulus.md'
        $command = Get-Command gtkwave -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $viewer = if ($command) { $command.Source } else { 'gtkwave' }
        $words = foreach ($argument in @($viewer, $result.vcdPath, $result.gtkwPath)) { "'" + $argument.Replace("'", "''") + "'" }
        $result.openCommand = '& ' + ($words -join ' ')
        $result.status = 'ready'
        $result.diagnostic = $null
    }
    catch [OperationCanceledException] {
        $result.status = 'cancelled'
        $result.diagnostic = 'Waveform export was cancelled after project acceptance.'
    }
    catch {
        $result.status = $phase
        $result.diagnostic = $_.Exception.Message
    }
}
