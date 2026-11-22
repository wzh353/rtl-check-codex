function Read-RtlSimulatorSettings([string]$Root, $Config, $Default = @{ engine = 'icarus' }) {
    if (-not $Config.Contains('simulator')) { return $Default }
    $settings = $Config['simulator']
    if ($settings -isnot [System.Collections.IDictionary] -or $settings['engine'] -cnotin @('icarus', 'modelsim')) {
        throw 'simulator.engine must be icarus or modelsim.'
    }
    foreach ($key in $settings.Keys) {
        if ($key -cne 'engine' -and ($key -cne 'binDirectory' -or $settings['engine'] -ne 'modelsim')) {
            throw "Unsupported simulator field '$key' for $($settings['engine'])."
        }
    }
    $bin = if ($settings.Contains('binDirectory')) {
        if ($settings['binDirectory'] -isnot [string] -or [string]::IsNullOrWhiteSpace($settings['binDirectory'])) {
            throw 'simulator.binDirectory must be a nonempty path to the ModelSim executable directory.'
        }
        [IO.Path]::GetFullPath($settings['binDirectory'], $Root)
    }
    return @{ engine = $settings['engine']; binDirectory = $bin }
}

function Initialize-RtlModelSimTools($Settings) {
    $bin = $Settings.binDirectory
    if (-not $bin) { $bin = [IO.Path]::GetDirectoryName((Find-RtlExecutable 'vsim')) }
    foreach ($name in @('vlib', 'vlog', 'vsim')) {
        $file = if ($IsWindows) { "$name.exe" } else { $name }
        $path = Join-Path $bin $file
        if (-not [IO.File]::Exists($path)) { throw "ModelSim $name was not found in $bin." }
        $Settings[$name] = $path
    }
    $ini = Join-Path (Split-Path -Parent $bin) 'modelsim.ini'
    if (-not [IO.File]::Exists($ini)) { $ini = Join-Path $bin 'modelsim.ini' }
    if (-not [IO.File]::Exists($ini)) { throw "The ModelSim installation near $bin has no modelsim.ini." }
    $Settings.installationIni = $ini.Replace('\', '/')
}

function Get-RtlModelSimFirstError($Process, [string]$WorkDirectory) {
    $pattern = '^\s*(?:#\s*)?\*\*\s+(?:Error|Fatal)(?: \([^)]+\))?:\s*(?<detail>.*)$'
    $entry = Select-String -LiteralPath @($Process.stdout, $Process.stderr) -Pattern $pattern -List -Context 0,1 |
        Select-Object -First 1
    if (-not $entry) { return }
    $message = $entry.Matches[0].Groups['detail'].Value
    $file = $null
    $line = $null
    $time = $null
    $unit = $null
    $scope = $null
    $location = [regex]::Match($message, '^(?:\([a-z]+-\d+\)\s+)?"?(?<file>.+?)"?\((?<line>\d+)(?::\d+)?\):\s*')
    if ($location.Success) {
        $file = $location.Groups['file'].Value
        $line = [int]$location.Groups['line'].Value
    }
    if ($entry.Context -and $entry.Context.PostContext) {
        $next = $entry.Context.PostContext[0]
        $stamp = [regex]::Match($next, '^\s*#?\s*Time:\s*(?<time>\d+(?:\.\d+)?)\s*(?<unit>fs|ps|ns|us|ms|sec|s)\b')
        if ($stamp.Success) {
            $time = [decimal]::Parse($stamp.Groups['time'].Value, [Globalization.CultureInfo]::InvariantCulture)
            $unit = $stamp.Groups['unit'].Value
            $path = [regex]::Match($next, '\b(?:Scope|Instance):\s*(\S+)')
            if ($path.Success) { $scope = $path.Groups[1].Value }
            $position = [regex]::Match($next, '\bFile:\s*(.+?)\s+Line:\s*(\d+)\s*$')
            if ($position.Success) {
                $file = $position.Groups[1].Value.Trim('"')
                $line = [int]$position.Groups[2].Value
            }
        }
    }
    return [ordered]@{
        file = $file
        inputFile = Get-RtlDiagnosticInputFile $file $WorkDirectory
        line = $line
        simulationTime = $time
        simulationTimeUnit = $unit
        scope = $scope
        message = $message.Substring(0, [Math]::Min(2000, $message.Length))
        text = $entry.Line.Substring(0, [Math]::Min(2400, $entry.Line.Length))
        textHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($entry.Line)))
        log = $entry.Path
    }
}

function Get-RtlModelSimErrorCount($Process) {
    $line = Select-String -LiteralPath @($Process.stdout, $Process.stderr) -Pattern '^\s*(?:#\s*)?Errors:\s*(\d+),\s*Warnings:\s*\d+\s*$' |
        Select-Object -Last 1
    if ($line) { return [int]$line.Matches[0].Groups[1].Value }
}

function Test-RtlModelSimSetupFailure($FirstError) {
    $configuration = 'failed to open -modelsimini file'
    $licensing = '(?:(?:unable|failed|could not) to check\s*out\b[^\r\n]{0,80}\blicen[cs]e|licen[cs]e checkout fail|no valid licen[cs]e)'
    $library = '\(vlog-9\) Problem while writing token file'
    return $FirstError -and $FirstError.message -match "$configuration|$licensing|$library"
}

function Set-RtlModelSimFailure($Report, $Process, [string]$Status, [string]$Message) {
    $Report.status = $Status
    $Report.diagnostic = Get-RtlDiagnostics $Process $Message $Report.firstError
}

function Invoke-RtlModelSimCheck($Project, [string]$WorkDirectory, [string]$LogDirectory, [int]$TimeoutSeconds,
                                [string]$VcdName = '') {
    $path = New-RtlToolPath $WorkDirectory ([IO.Path]::GetDirectoryName($LogDirectory))
    try {
        $report = Invoke-RtlModelSimNative $Project $path.execution $LogDirectory $TimeoutSeconds $VcdName
        foreach ($step in @('library', 'compile', 'elaborate', 'simulate')) {
            Restore-RtlReportedToolPath $report[$step] $path
        }
        return $report
    }
    finally { Remove-RtlToolPath $path }
}

function Invoke-RtlModelSimNative($Project, [string]$WorkDirectory, [string]$LogDirectory, [int]$TimeoutSeconds,
                                 [string]$VcdName) {
    $settings = $Project.Simulator
    $report = New-RtlCheckReport 'modelsim'
    $report.library = $null
    $report.elaborate = $null
    $id = [guid]::NewGuid().ToString('N')
    $library = "rtlcheck_$id"
    $ini = "$library.ini"
    $config = @('[Library]', "work = $library", "others = $($settings.installationIni)")
    [IO.File]::WriteAllLines((Join-Path $WorkDirectory $ini), [string[]]$config)

    $process = Invoke-RtlProcess $settings.vlib @($library) $WorkDirectory (Join-Path $LogDirectory 'vlib') $TimeoutSeconds
    $report.library = $process
    $report.exitCode = $process.exitCode
    $report.timedOut = $process.timedOut
    if ($process.timedOut -or $process.exitCode -ne 0 -or -not [IO.Directory]::Exists((Join-Path $WorkDirectory $library))) {
        $report.firstError = Get-RtlModelSimFirstError $process $WorkDirectory
        Set-RtlModelSimFailure $report $process 'error' 'ModelSim could not initialize the isolated work library.'
        return $report
    }

    $arguments = @('-modelsimini', $ini, '-sv', '-work', 'work')
    foreach ($dir in $Project.IncludeDirs) { $arguments += "+incdir+./$dir" }
    foreach ($define in $Project.Defines) { $arguments += @('-define', $define) }
    $arguments += @(Get-RtlSimulationSourceArguments $Project)
    $process = Invoke-RtlProcess $settings.vlog $arguments $WorkDirectory (Join-Path $LogDirectory 'compile') $TimeoutSeconds
    $report.compile = $process
    $report.exitCode = $process.exitCode
    $report.timedOut = $process.timedOut
    $report.firstError = Get-RtlModelSimFirstError $process $WorkDirectory
    $errorCount = Get-RtlModelSimErrorCount $process
    if ($process.timedOut) {
        Set-RtlModelSimFailure $report $process 'failed' "ModelSim compilation timed out after $TimeoutSeconds s."
        return $report
    }
    if (Test-RtlModelSimSetupFailure $report.firstError) {
        Set-RtlModelSimFailure $report $process 'error' 'ModelSim could not use its work library, configuration or license.'
        return $report
    }
    if ($null -eq $errorCount) {
        Set-RtlModelSimFailure $report $process 'error' 'ModelSim did not return a conclusive compiler result.'
        return $report
    }
    if ($process.exitCode -ne 0 -or $report.firstError -or $errorCount -ne 0) {
        Set-RtlModelSimFailure $report $process 'failed' 'ModelSim compilation failed.'
        return $report
    }

    $simulate = $Project.Testbenches.Count -gt 0
    $started = "RTL_CHECK_MODELSIM_LOADED_$id"
    $completed = "RTL_CHECK_MODELSIM_DONE_$id"
    $scriptName = "$library.do"
    $commands = @('onerror {quit -force -code 2}', 'onbreak {resume}', "puts {$started}")
    if ($VcdName) {
        $commands += @("vcd file {$VcdName}", 'vcd limit 33554432')
        foreach ($signal in $Project.Waveform.signals) {
            $commands += 'vcd add {/' + $signal.Replace('.', '/') + '}'
        }
    }
    if ($simulate) { $commands += 'run -all' }
    if ($VcdName) { $commands += 'vcd flush' }
    $commands += @("puts {$completed}", 'quit -force -code 0')
    [IO.File]::WriteAllLines((Join-Path $WorkDirectory $scriptName), [string[]]$commands)

    $arguments = @('-modelsimini', $ini, '-c', '-t', 'fs', '-onfinish', 'stop', '-lic_noqueue')
    if ($Project.Waveform) { $arguments += '-voptargs=+acc' }
    $arguments += @("work.$($Project.Top)", '-do', "do $scriptName")
    $logName = if ($simulate) { 'simulate' } else { 'elaborate' }
    $process = Invoke-RtlProcess $settings.vsim $arguments $WorkDirectory (Join-Path $LogDirectory $logName) $TimeoutSeconds
    $report.exitCode = $process.exitCode
    $report.timedOut = $process.timedOut
    $loaded = Select-String -LiteralPath $process.stdout -Pattern ("^" + $started + '$') -CaseSensitive -Quiet
    if ($simulate -and $loaded) {
        $report.stage = 'simulate'
        $report.simulate = $process
    } else {
        $report.elaborate = $process
    }
    $report.firstError = Get-RtlModelSimFirstError $process $WorkDirectory
    $errorCount = Get-RtlModelSimErrorCount $process
    if ($process.timedOut) {
        Set-RtlModelSimFailure $report $process 'failed' "ModelSim $($report.stage) timed out after $TimeoutSeconds s."
    } elseif (-not $loaded -and (Test-RtlModelSimSetupFailure $report.firstError)) {
        Set-RtlModelSimFailure $report $process 'error' 'ModelSim could not use its configuration or license.'
    } elseif (-not $loaded -and ($report.firstError -or $errorCount -gt 0)) {
        Set-RtlModelSimFailure $report $process 'failed' 'ModelSim could not elaborate the requested design hierarchy.'
    } elseif ($report.firstError -or $errorCount -gt 0) {
        Set-RtlModelSimFailure $report $process 'failed' 'ModelSim reported a simulation error.'
    } elseif ($simulate -and (Select-String -LiteralPath $process.stdout -Pattern '^\s*#\s*\*\*\s+Note:\s+\$stop\b' -Quiet)) {
        Set-RtlModelSimFailure $report $process 'failed' 'Simulation encountered an explicit $stop.'
    } elseif (-not $loaded -or $process.exitCode -ne 0 -or $null -eq $errorCount -or
              -not (Select-String -LiteralPath $process.stdout -Pattern ("^" + $completed + '$') -CaseSensitive -Quiet)) {
        Set-RtlModelSimFailure $report $process 'error' 'ModelSim did not return a conclusive run result.'
    } elseif ($simulate -and -not (Select-String -LiteralPath $process.stdout -Pattern ('^# ' + [regex]::Escape($Project.PassMarker) + '$') -CaseSensitive -Quiet)) {
        Set-RtlModelSimFailure $report $process 'failed' "Simulation ended without the success line: $($Project.PassMarker)"
    } else {
        $report.status = 'passed'
    }
    return $report
}
