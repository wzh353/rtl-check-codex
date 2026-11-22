function Read-RtlWaveformSettings($Settings, [string]$Top) {
    if ($Settings -isnot [System.Collections.IDictionary] -or $Settings['signals'] -isnot [array] -or
        $Settings['signals'].Count -lt 1 -or $Settings['signals'].Count -gt 16) {
        throw 'waveform.signals must list one to sixteen signal names.'
    }
    $signals = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($signal in $Settings['signals']) {
        if ($signal -isnot [string] -or $signal.Length -gt 160 -or
            $signal -cnotmatch '\A[A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)+\z' -or
            -not $signal.StartsWith("$Top.", [StringComparison]::Ordinal)) {
            throw "waveform signal '$signal' must be a hierarchical signal under $Top."
        }
        if (-not $signals.Add($signal)) { throw "Duplicate waveform signal '$signal'." }
    }
    $maxEvents = if ($Settings.Contains('maxEvents')) { $Settings['maxEvents'] } else { 12 }
    if (($maxEvents -isnot [int] -and $maxEvents -isnot [long]) -or $maxEvents -lt 1 -or $maxEvents -gt 32) {
        throw 'waveform.maxEvents must be an integer from 1 to 32.'
    }
    return @{ signals = $Settings['signals']; maxEvents = [int]$maxEvents }
}

function ConvertTo-RtlVcdTick([decimal]$Time, [string]$Unit, [string]$Timescale) {
    $scale = [regex]::Match($Timescale, '^\s*(1|10|100)\s*(fs|ps|ns|us|ms|s|sec)\s*$')
    $femtoseconds = @{ fs = 1; ps = 1e3; ns = 1e6; us = 1e9; ms = 1e12; s = 1e15; sec = 1e15 }
    if (-not $scale.Success -or -not $femtoseconds.ContainsKey($Unit)) {
        throw 'Could not align the simulator time unit with the VCD timescale.'
    }
    $tick = $Time * [decimal]$femtoseconds[$Unit] / ([decimal]$scale.Groups[1].Value * [decimal]$femtoseconds[$scale.Groups[2].Value])
    if ($tick -ne [decimal]::Truncate($tick) -or $tick -lt 0 -or $tick -gt [ulong]::MaxValue) {
        throw 'The failure time does not have an exact tick in the VCD.'
    }
    return [ulong]$tick
}

function Add-RtlVcdVectorChanges($SplitVectors, $DirtyVectors, $Values, $Changes) {
    foreach ($name in $DirtyVectors) {
        $bits = $SplitVectors[$name]
        $width = [Math]::Min(128, $bits.Count)
        $tail = [char[]]::new($width)
        $bits.CopyTo($bits.Count - $width, $tail, 0, $width)
        $value = [string]::new($tail)
        if ($bits.Count -gt 128) { $value = 'LSB128:' + $value }
        $Values[$name] = $value
        $Changes[$name] = $value
    }
    $DirtyVectors.Clear()
}

function Read-RtlVcdTrace([string]$Path, [string[]]$Signals, [int]$MaxEvents, [decimal]$FailureTime,
                          [string]$FailureTimeUnit) {
    $scopes = [Collections.Generic.List[string]]::new()
    $variables = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $changes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $splitVectors = [Collections.Generic.Dictionary[string, Collections.Generic.List[char]]]::new([StringComparer]::Ordinal)
    $dirtyVectors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $events = [Collections.Generic.Queue[object]]::new()
    $timescale = $null
    $header = $true
    $tick = [ulong]0
    $failureTick = $FailureTime

    $reader = [IO.StreamReader]::new($Path)
    try {
        while ($null -ne ($raw = $reader.ReadLine())) {
            if ($raw.Length -eq 0) { continue }
            $line = $raw.Trim()
            if ($header) {
                switch -CaseSensitive -Regex ($line) {
                    '^\$timescale$' {
                        $timescale = $reader.ReadLine().Trim()
                    }
                    '^\$timescale\s+(.+?)\s+\$end$' {
                        $timescale = $Matches[1]
                    }
                    '^\$scope\s+\S+\s+(\S+)\s+\$end$' {
                        $scopes.Add($Matches[1])
                    }
                    '^\$upscope\b' {
                        if ($scopes.Count) { $scopes.RemoveAt($scopes.Count - 1) }
                    }
                    '^\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)(?:\s+\[(-?\d+)\])?\s+' {
                        $name = (@($scopes) + $Matches[3]) -join '.'
                        if ($name -cin $Signals) {
                            $id = $Matches[2]
                            if (-not $variables.ContainsKey($id)) {
                                $variables[$id] = [Collections.Generic.List[object]]::new()
                            }
                            $width = [int]$Matches[1]
                            $slot = if ($width -eq 1 -and $Matches.ContainsKey(4)) {
                                # ModelSim emits some wire vectors as scalar declarations in packed bit order.
                                if (-not $splitVectors.ContainsKey($name)) {
                                    $splitVectors[$name] = [Collections.Generic.List[char]]::new()
                                }
                                $splitVectors[$name].Count
                                $splitVectors[$name].Add('x')
                            }
                            $variables[$id].Add(@{ name = $name; width = $width; bitSlot = $slot })
                        }
                    }
                    '^\$enddefinitions\b' {
                        if ($FailureTimeUnit) {
                            $failureTick = ConvertTo-RtlVcdTick $FailureTime $FailureTimeUnit $timescale
                        }
                        $header = $false
                    }
                }
                continue
            }
            if ($line -cmatch '^#(\d+)$') {
                $nextTick = [ulong]$Matches[1]
                if ($dirtyVectors.Count) { Add-RtlVcdVectorChanges $splitVectors $dirtyVectors $values $changes }
                if ($changes.Count) {
                    $events.Enqueue(@{ tick = $tick; changes = $changes })
                    if ($events.Count -gt $MaxEvents) { $null = $events.Dequeue() }
                    $changes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
                }
                if ($nextTick -gt $FailureTick) { break }
                $tick = $nextTick
                continue
            }
            if ($line -match '^b([01xz]+)\s+(\S+)$' -or $line -match '^([01xz])(\S+)$') {
                $bits = $Matches[1].ToLowerInvariant()
                $id = $Matches[2]
                if (-not $variables.ContainsKey($id)) { continue }
                foreach ($signal in $variables[$id]) {
                    if ($null -ne $signal.bitSlot) {
                        $splitVectors[$signal.name][$signal.bitSlot] = $bits[-1]
                        $null = $dirtyVectors.Add($signal.name)
                        continue
                    }
                    $fill = if ($bits[0] -in @('x', 'z')) { $bits[0] } else { [char]'0' }
                    $width = [Math]::Min($signal.width, 128)
                    $value = if ($bits.Length -gt $width) { $bits.Substring($bits.Length - $width) }
                    else { $bits.PadLeft($width, $fill) }
                    if ($signal.width -gt 128) { $value = 'LSB128:' + $value }
                    $values[$signal.name] = $value
                    $changes[$signal.name] = $value
                }
            }
        }
        if ($dirtyVectors.Count) { Add-RtlVcdVectorChanges $splitVectors $dirtyVectors $values $changes }
        if ($changes.Count) {
            $events.Enqueue(@{ tick = $tick; changes = $changes })
            if ($events.Count -gt $MaxEvents) { $null = $events.Dequeue() }
        }
    }
    finally {
        $reader.Dispose()
    }
    return [ordered]@{
        timescale = $timescale
        failureTick = [ulong]$failureTick
        values = $values
        events = $events.ToArray()
        missingSignals = @($Signals | Where-Object { -not $values.ContainsKey($_) })
    }
}

function Invoke-RtlFailureWaveform($Project, $CheckResult, [string]$ReferenceRoot,
                                  [System.Collections.IDictionary]$Overrides, [string]$LogDirectory,
                                  [string]$Compiler, [string]$Simulator, [int]$TimeoutSeconds) {
    $wave = [ordered]@{
        status = 'unavailable'
        path = $null
        compile = $null
        simulate = $null
        replayError = $null
        trace = $null
        diagnostic = $null
    }
    if ($CheckResult.timedOut -or -not $CheckResult.firstError -or $null -eq $CheckResult.firstError.simulationTime) {
        $wave.status = 'not_replayed'
        $wave.diagnostic = 'Waveform replay requires a simulation error with a reported time.'
        return $wave
    }
    if (-not $ReferenceRoot) {
        $wave.diagnostic = 'No pre-simulation snapshot was provided for waveform replay.'
        return $wave
    }
    try {
        $directory = Join-Path $LogDirectory 'waveform'
        $work = Join-Path $directory 'work'
        Copy-RtlInputs $Project $ReferenceRoot $work
        if ($Overrides) { Write-RtlFiles $work $Overrides }
        $probe = 'rtlcheck_wave_' + [guid]::NewGuid().ToString('N')
        $vcdName = "$probe.vcd"
        $vcd = Join-Path $work $vcdName
        $limit = 32MB
        if ($CheckResult.engine -eq 'modelsim') {
            $replay = Invoke-RtlModelSimCheck $Project $work $directory $TimeoutSeconds $vcdName
            $wave.library = $replay.library
            $wave.compile = $replay.compile
            $wave.simulate = $replay.simulate
            $wave.replayError = $replay.firstError
            if ($replay.stage -eq 'compile') {
                $wave.elaborate = $replay.elaborate
                $wave.status = 'compile_failed'
                $wave.diagnostic = $replay.diagnostic
                return $wave
            }
        } else {
            $signalList = $Project.Waveform.signals -join ', '
            $probePath = Join-Path $directory 'probe.sv'
            $probeText = @"
module $probe;
    initial begin
        `$dumpfile("$vcdName");
        `$dumplimit($limit);
        `$dumpvars(1, $signalList);
    end
endmodule
"@
            [IO.File]::WriteAllText($probePath, $probeText)
            $program = Join-Path $directory 'replay.vvp'
            $arguments = @('-s', $probe) + @(Get-RtlCompileArguments $Project $program) + '../probe.sv'
            $wave.compile = Invoke-RtlProcess $Compiler $arguments $work (Join-Path $directory 'compile') $TimeoutSeconds
            if ($wave.compile.timedOut -or $wave.compile.exitCode -ne 0) {
                $wave.status = 'compile_failed'
                $wave.diagnostic = Get-RtlDiagnostics $wave.compile 'Waveform probe compilation failed.'
                return $wave
            }
            $wave.simulate = Invoke-RtlProcess $Simulator @('-N', $program) $work (Join-Path $directory 'simulate') $TimeoutSeconds
            $wave.replayError = Get-RtlFirstError $wave.simulate 'simulate' $work
        }
        if ([IO.File]::Exists($vcd)) { $wave.path = $vcd }
        $originalFile = if ($CheckResult.firstError.inputFile) { $CheckResult.firstError.inputFile } else { $CheckResult.firstError.file }
        $replayFile = if ($wave.replayError) {
            if ($wave.replayError.inputFile) { $wave.replayError.inputFile } else { $wave.replayError.file }
        }
        if ($wave.simulate.timedOut -or $wave.simulate.exitCode -ne $CheckResult.exitCode -or -not $wave.replayError -or
            $wave.replayError.textHash -cne $CheckResult.firstError.textHash -or
            $replayFile -cne $originalFile -or $wave.replayError.line -ne $CheckResult.firstError.line -or
            $wave.replayError.scope -cne $CheckResult.firstError.scope -or
            $wave.replayError.simulationTime -ne $CheckResult.firstError.simulationTime -or
            $wave.replayError['simulationTimeUnit'] -cne $CheckResult.firstError['simulationTimeUnit']) {
            $wave.status = 'different_failure'
            $wave.diagnostic = 'The replay did not reproduce the original simulator error and time.'
            return $wave
        }
        if (-not $wave.path) {
            $wave.diagnostic = 'The replay did not produce its VCD file.'
        } elseif ([IO.FileInfo]::new($vcd).Length -ge $limit -or
            (Select-String -LiteralPath @($wave.simulate.stdout, $wave.simulate.stderr) -Pattern '^WARNING: Dump file limit' -Quiet)) {
            $wave.status = 'capture_limit'
            $wave.diagnostic = 'The replay reached the 32 MiB waveform limit.'
        } else {
            $trace = Read-RtlVcdTrace $vcd $Project.Waveform.signals $Project.Waveform.maxEvents $CheckResult.firstError.simulationTime $CheckResult.firstError['simulationTimeUnit']
            if ($trace.values.Count -gt 0 -and $trace.timescale) {
                $wave.trace = $trace
                $wave.status = 'captured'
            } else {
                $wave.diagnostic = 'The VCD file did not contain sampled values and a timescale.'
            }
        }
    }
    catch [OperationCanceledException] { throw }
    catch {
        $wave.diagnostic = $_.Exception.Message
    }
    return $wave
}

function Get-RtlWaveformContext($Waveform) {
    if (-not $Waveform -or $Waveform.status -ne 'captured') { return }
    $trace = $Waveform.trace
    $context = @{
        timescale = $trace.timescale
        failureTick = $trace.failureTick
        values = $trace.values
        missingSignals = $trace.missingSignals
        events = @()
    }
    $used = (ConvertTo-Json -InputObject $context -Depth 6 -Compress).Length
    for ($index = $trace.events.Count - 1; $index -ge 0; $index--) {
        $event = $trace.events[$index]
        $used += (ConvertTo-Json -InputObject $event -Depth 4 -Compress).Length + 1
        if ($used -gt 8000) { break }
        $context.events = @($event) + $context.events
    }
    return $context
}
