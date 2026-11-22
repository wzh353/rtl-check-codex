. (Join-Path $PSScriptRoot 'Waveform.ps1')
. (Join-Path $PSScriptRoot 'Synthesis.ps1')
. (Join-Path $PSScriptRoot 'Timing.ps1')
. (Join-Path $PSScriptRoot 'ModelSim.ps1')
. (Join-Path $PSScriptRoot 'Board.ps1')
. (Join-Path $PSScriptRoot 'Pango.ps1')
. (Join-Path $PSScriptRoot 'Vendor.ps1')
. (Join-Path $PSScriptRoot 'Regression.ps1')

function Resolve-RtlProjectItem([string]$Root, $Name, [switch]$Directory) {
    if ($Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name)) {
        throw "Expected a path relative to the configuration directory: $Name"
    }
    $fullPath = [IO.Path]::GetFullPath($Name, $Root)
    $relative = [IO.Path]::GetRelativePath($Root, $fullPath).Replace('\', '/')
    if ($relative -eq '..' -or $relative.StartsWith('../') -or [IO.Path]::IsPathRooted($relative)) {
        throw "Path is outside the configuration directory: $Name"
    }
    if ($Directory) {
        if (-not [IO.Directory]::Exists($fullPath)) { throw "Directory not found: $fullPath" }
    }
    elseif (-not [IO.File]::Exists($fullPath)) {
        throw "File not found: $fullPath"
    }
    return $relative
}

function Read-RtlTestSuite([string]$Root, $Config, [string[]]$Sources) {
    if ($Config['top'] -isnot [string] -or $Config['top'] -cnotmatch '\A[A-Za-z_][A-Za-z0-9_$]*\z') {
        throw 'Set top to the name of the testbench module, or the RTL top module for compile-only checks.'
    }
    if ($Config.Contains('testbenches') -and $Config['testbenches'] -isnot [array]) {
        throw 'testbenches must be an array.'
    }
    $benches = @(foreach ($path in $Config['testbenches']) { Resolve-RtlProjectItem $Root $path })
    if (@($Sources + $benches | Sort-Object -Unique).Count -ne ($Sources.Count + $benches.Count)) {
        throw 'List each compilation input only once across sources and testbenches.'
    }
    $marker = if ($Config.Contains('passMarker')) { $Config['passMarker'] } else { 'RTL_CHECK_PASS' }
    if ($marker -isnot [string] -or [string]::IsNullOrWhiteSpace($marker) -or $marker -match '[\r\n]') {
        throw 'passMarker must be a nonempty single line.'
    }
    $waveform = if ($Config.Contains('waveform')) {
        if ($benches.Count -eq 0) { throw 'waveform requires a testbench.' }
        Read-RtlWaveformSettings $Config['waveform'] $Config['top']
    }
    return @{ Top = $Config['top']; Sources = $Sources; Testbenches = $benches; PassMarker = $marker; Waveform = $waveform }
}

function Read-RtlMacroDefinitions($Config, [string]$FieldName) {
    if ($Config.Contains('defines') -and $Config['defines'] -isnot [array]) {
        throw "$FieldName must be an array."
    }
    foreach ($define in $Config['defines']) {
        if ($define -isnot [string] -or $define -cnotmatch '\A[A-Za-z_][A-Za-z0-9_$]*(=[^\r\n]*)?\z') {
            throw "Expected a macro NAME or NAME=VALUE in $FieldName."
        }
        $define
    }
}

function Read-RtlProject([string]$ConfigPath) {
    $root = [IO.Path]::GetDirectoryName($ConfigPath)
    $bytes = [IO.File]::ReadAllBytes($ConfigPath)
    $configText = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $config = ConvertFrom-Json -InputObject $configText -AsHashtable
    if ($config -isnot [System.Collections.IDictionary]) { throw 'Expected a JSON configuration object.' }
    if ($config['sources'] -isnot [array] -or $config['sources'].Count -eq 0) {
        throw 'Set sources to a nonempty array of RTL filenames.'
    }
    foreach ($key in @('supportFiles', 'includeDirs', 'repairFiles', 'simulationSources')) {
        if ($config.Contains($key) -and $config[$key] -isnot [array]) { throw "$key must be an array." }
    }

    $sources = @(foreach ($path in $config['sources']) { Resolve-RtlProjectItem $root $path })
    $project = Read-RtlTestSuite $root $config $sources
    $models = @(foreach ($path in $config['simulationSources']) {
        $file = Resolve-RtlProjectItem $root $path
        if ([IO.Path]::GetExtension($file) -notin @('.v', '.sv')) { throw "Expected a Verilog simulation source: $path" }
        $file
    })
    $compilationInputs = $models + $sources + $project.Testbenches
    if ($models.Count -gt 0 -and @($compilationInputs | Sort-Object -Unique).Count -ne $compilationInputs.Count) {
        throw 'List each compilation input only once across sources, simulationSources and testbenches.'
    }
    $project.SimulationSources = $models
    $support = @(foreach ($path in $config['supportFiles']) { Resolve-RtlProjectItem $root $path })
    $includeDirs = @(foreach ($path in $config['includeDirs']) { Resolve-RtlProjectItem $root $path -Directory })
    $defines = @(Read-RtlMacroDefinitions $config 'defines')
    $specification = if ($config.Contains('specification')) { Resolve-RtlProjectItem $root $config['specification'] }
    $configName = [IO.Path]::GetFileName($ConfigPath)
    $project.Root = $root
    $project.SupportFiles = $support
    $project.IncludeDirs = $includeDirs
    $project.Defines = $defines
    $project.Specification = $specification
    $project.RepairFiles = $config['repairFiles']
    $project.Simulator = Read-RtlSimulatorSettings $root $config
    $project.ConfigName = $configName
    $project.ConfigBytes = $bytes
    $project.Validation = $null
    $project.Synthesis = if ($config.Contains('synthesis')) { Read-RtlSynthesisSettings $root $config['synthesis'] }
    $constraints = if ($project.Synthesis) { $project.Synthesis.constraintFiles }
    $project.InputFiles = @($compilationInputs + $support + $specification + $configName + $constraints |
        Where-Object { $_ } | Sort-Object -Unique)
    $project.Regressions = @(Read-RtlRegressions $project $config)

    if ($config.Contains('validation')) {
        if ($project.Testbenches.Count -eq 0 -and $project.Regressions.Count -eq 0) {
            throw 'validation requires a primary testbench or public regression.'
        }
        $suite = Read-RtlExtraSuite $project $config['validation'] 'validation'
        $publicFiles = @(Get-RtlPublicFiles $project)
        if ($suite.Testbenches | Where-Object { $_ -in $publicFiles }) {
            throw 'Keep validation.testbenches separate from primary and regression inputs.'
        }
        $project.Validation = $suite
    }
    return $project
}

function Get-RtlBaselineFiles($Project) {
    $public = @(Get-RtlPublicFiles $Project)
    if ($Project['Validation']) { return @($public + $Project.Validation.InputFiles | Sort-Object -Unique) }
    return $public
}

function Get-RtlInputDigest([string]$Root, [string[]]$InputFiles) {
    $entries = @(foreach ($file in $InputFiles) {
        $path = Join-Path $Root $file
        if (-not [IO.File]::Exists($path)) { return }
        "$file $((Get-FileHash -LiteralPath $path).Hash)"
    })
    $data = [Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data))
}

function Copy-RtlInputs($Project, [string]$SourceRoot, [string]$DestinationRoot,
                        [switch]$WithValidation, [string[]]$Files) {
    $null = [IO.Directory]::CreateDirectory($DestinationRoot)
    $includeDirs = if ($WithValidation) {
        Get-RtlProjectSuites $Project | ForEach-Object { $_.IncludeDirs } | Select-Object -Unique
    } else { $Project.IncludeDirs }
    foreach ($dir in $includeDirs) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $DestinationRoot $dir))
    }
    $inputs = if ($PSBoundParameters.ContainsKey('Files')) { $Files }
    elseif ($WithValidation) { Get-RtlBaselineFiles $Project }
    else { $Project.InputFiles }
    foreach ($relative in $inputs) {
        Assert-RtlCheckActive
        $destination = Join-Path $DestinationRoot $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy((Join-Path $SourceRoot $relative), $destination)
    }
}

function Write-RtlFiles([string]$Root, [System.Collections.IDictionary]$Files) {
    foreach ($relative in $Files.Keys) {
        $path = Join-Path $Root $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::WriteAllBytes($path, $Files[$relative])
    }
}

function Assert-RtlCheckActive([string]$CancellationFile = $env:RTL_CHECK_CANCEL_FILE) {
    if ($CancellationFile -and [IO.File]::Exists($CancellationFile)) {
        throw [OperationCanceledException]::new('The RTL operation was cancelled before publication.')
    }
}

function New-RtlToolPath([string]$WorkingDirectory, [string]$AliasTarget = $WorkingDirectory) {
    $working = [IO.Path]::GetFullPath($WorkingDirectory)
    $path = @{ working = $working; execution = $working; junction = $null; target = $null }
    # Leave room for the long internal filenames of older Windows EDA tools.
    if (-not $IsWindows -or $working.Length -lt 144) { return $path }
    $target = [IO.Path]::GetFullPath($AliasTarget)
    $relative = [IO.Path]::GetRelativePath($target, $working)
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.(?:[/\\]|$)') {
        throw 'The native working directory must be inside the proposed alias target.'
    }
    $alias = Join-Path ([IO.Path]::GetTempPath()) ('rtlw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $execution = if ($relative -eq '.') { $alias } else { Join-Path $alias $relative }
    if ($execution.Length -ge $working.Length) { return $path }
    $null = [IO.Directory]::CreateDirectory($target)
    $path.junction = (New-Item -ItemType Junction -Path $alias -Target $target).FullName
    $path.target = $target
    $path.execution = $execution
    return $path
}

function Restore-RtlReportedToolPath($Process, $Path) {
    if ($Process -and $Path.junction) {
        $Process.executionDirectory = $Path.execution
        $Process.workingDirectory = $Path.working
    }
}

function Remove-RtlToolPath($Path) {
    if (-not $Path.junction) { return }
    $entry = Get-Item -LiteralPath $Path.junction
    if ($entry.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath([string]$entry.Target) -ne $Path.target) {
        throw "The temporary EDA path changed before cleanup: $($Path.junction)"
    }
    [IO.Directory]::Delete($Path.junction, $false)
}

function Find-RtlExecutable([string]$Name) {
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "Executable '$Name' was not found. Add it to PATH." }
    return $command.Source
}

function Wait-RtlOperation([scriptblock]$Wait, [Diagnostics.Stopwatch]$Watch, [long]$DeadlineMs,
                           [string]$CancellationFile) {
    do {
        Assert-RtlCheckActive $CancellationFile
        $remainingMs = [int][Math]::Max(0, $DeadlineMs - $Watch.ElapsedMilliseconds)
        $waitMs = if ($CancellationFile) { [Math]::Min($remainingMs, 100) } else { $remainingMs }
        if (& $Wait $waitMs) { return $true }
    } while ($remainingMs -gt $waitMs)
    Assert-RtlCheckActive $CancellationFile
    return $false
}

function Enter-RtlInputLock {
    # Projects can share RTL files despite using different configuration directories.
    $mutex = [Threading.Mutex]::new($false, 'local-rtl-check-publication')
    $owned = $false
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { $owned = Wait-RtlOperation { param($ms) $mutex.WaitOne($ms) } $watch 10000 $env:RTL_CHECK_CANCEL_FILE }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another RTL operation is copying or publishing inputs. Try again.' }
        return $mutex
    }
    finally {
        if (-not $owned) { $mutex.Dispose() }
    }
}

function Exit-RtlInputLock([Threading.Mutex]$Mutex) {
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Copy-RtlProjectBaseline($Project, [string]$DestinationRoot) {
    $mutex = Enter-RtlInputLock
    try {
        Copy-RtlInputs $Project $Project.Root $DestinationRoot -WithValidation
        [IO.File]::WriteAllBytes((Join-Path $DestinationRoot $Project.ConfigName), $Project.ConfigBytes)
    }
    finally { Exit-RtlInputLock $mutex }
}

function Stop-RtlChildProcess([Diagnostics.Process]$Process) {
    if (-not $Process.HasExited) {
        try { $Process.Kill($true) }
        catch [InvalidOperationException] { if (-not $Process.HasExited) { throw } }
    }
    if (-not $Process.WaitForExit(5000)) { throw 'Unable to stop the RTL child process.' }
}

function Invoke-RtlProcess([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory,
                           [string]$LogPrefix, [int]$TimeoutSeconds, [string]$InputText = '',
                           [System.Collections.IDictionary]$Environment) {
    $cancellationFile = $env:RTL_CHECK_CANCEL_FILE
    Assert-RtlCheckActive $cancellationFile
    $settings = [Diagnostics.ProcessStartInfo]::new($Executable)
    $settings.WorkingDirectory = $WorkingDirectory
    $settings.UseShellExecute = $false
    $settings.CreateNoWindow = $true
    $settings.RedirectStandardInput = $true
    $settings.RedirectStandardOutput = $true
    $settings.RedirectStandardError = $true
    $settings.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $settings.ArgumentList.Add($argument) }
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $settings.Environment[$key] = $Environment[$key] }
    }

    $stdout = "$LogPrefix.stdout.log"
    $stderr = "$LogPrefix.stderr.log"
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $settings
    $outLog = [IO.File]::Create($stdout)
    $errLog = $null
    $captureTasks = $null
    $started = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $limitMs = $TimeoutSeconds * 1000
    try {
        $errLog = [IO.File]::Create($stderr)
        $started = $process.Start()
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outLog)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($errLog)
        $captureTasks = [Threading.Tasks.Task[]]@($outTask, $errTask)
        $inputWritten = $true
        if ($InputText) {
            $payload = [Text.Encoding]::UTF8.GetBytes($InputText)
            $inputWrite = $process.StandardInput.BaseStream.WriteAsync($payload, 0, $payload.Length)
            try {
                $inputWritten = Wait-RtlOperation { param($ms) $inputWrite.Wait($ms) } $watch $limitMs $cancellationFile
            }
            catch [AggregateException] {
                # A child that closes its input early can still report its exit code and diagnostics.
                if ($_.Exception.GetBaseException() -isnot [IO.IOException]) { throw }
            }
        }
        if ($inputWritten) { $process.StandardInput.Close() }

        $timedOut = -not $inputWritten -or -not (Wait-RtlOperation { param($ms) $process.WaitForExit($ms) } $watch $limitMs $cancellationFile)
        if ($timedOut) { Stop-RtlChildProcess $process }
        $drained = Wait-RtlOperation { param($ms) [Threading.Tasks.Task]::WaitAll($captureTasks, $ms) } $watch ($watch.ElapsedMilliseconds + 5000) $cancellationFile
        if (-not $drained) {
            throw "Could not finish collecting output from $Executable."
        }
        return [ordered]@{
            executable = $Executable
            arguments = $Arguments
            workingDirectory = $WorkingDirectory
            exitCode = if (-not $timedOut) { $process.ExitCode }
            timedOut = $timedOut
            elapsedMs = $watch.ElapsedMilliseconds
            stdout = $stdout
            stderr = $stderr
        }
    }
    catch [OperationCanceledException] {
        if ($started) { Stop-RtlChildProcess $process }
        if ($captureTasks) {
            try { $null = [Threading.Tasks.Task]::WaitAll($captureTasks, 1000) }
            catch [AggregateException] {
                # A reader may see a closed pipe after the child is stopped.
            }
        }
        throw
    }
    finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true) } catch [InvalidOperationException] {}
        }
        $process.Dispose()
        $outLog.Dispose()
        if ($errLog) { $errLog.Dispose() }
    }
}

function Get-RtlDiagnosticInputFile([string]$File, [string]$WorkDirectory) {
    if (-not $File -or -not $WorkDirectory) { return }
    try {
        $path = [IO.Path]::GetFullPath($File, $WorkDirectory)
        $relative = [IO.Path]::GetRelativePath($WorkDirectory, $path).Replace('\', '/')
        if (-not [IO.Path]::IsPathRooted($relative) -and $relative -notmatch '^\.\.(?:/|$)') { $relative }
    }
    catch [ArgumentException] {}
    catch [NotSupportedException] {}
}

function Get-RtlFirstError($Process, [string]$Stage, [string]$WorkDirectory) {
    $location = '(?:(?<file>.+?):(?<line>\d+):\s*)?'
    if ($Stage -eq 'compile') {
        $logs = @($Process.stderr, $Process.stdout)
        $pattern = '^\s*' + $location + '(?<message>(?:syntax error|error\b|fatal\b|sorry\b|Include file\b.*\bnot found\b).*)$'
    } else {
        $logs = @($Process.stdout, $Process.stderr)
        $pattern = '^\s*(?:ERROR|FATAL):\s*' + $location + '(?<message>.*)$'
    }
    $entry = Select-String -LiteralPath $logs -Pattern $pattern -CaseSensitive -List -Context 0,1 | Select-Object -First 1
    if (-not $entry) { return }
    $groups = $entry.Matches[0].Groups
    $file = if ($groups['file'].Success) { $groups['file'].Value }
    $simulationTime = $null
    $scope = $null
    if ($Stage -eq 'simulate' -and $entry.Context -and $entry.Context.PostContext) {
        $timeLine = [regex]::Match($entry.Context.PostContext[0], '^\s*Time:\s*(\d+)\s+Scope:\s*(.+?)\s*$')
        $parsed = [ulong]0
        if ($timeLine.Success -and [ulong]::TryParse($timeLine.Groups[1].Value, [ref]$parsed)) {
            $simulationTime = $parsed
            $scope = $timeLine.Groups[2].Value
        }
    }
    return [ordered]@{
        file = $file
        inputFile = Get-RtlDiagnosticInputFile $file $WorkDirectory
        line = if ($groups['line'].Success) { [int]$groups['line'].Value }
        simulationTime = $simulationTime
        scope = $scope
        message = $groups['message'].Value.Substring(0, [Math]::Min(2000, $groups['message'].Length))
        text = $entry.Line.Substring(0, [Math]::Min(2400, $entry.Line.Length))
        textHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($entry.Line)))
        log = $entry.Path
    }
}

function Get-RtlDiagnostics($Process, [string]$Message, $FirstError) {
    $parts = @($Message)
    if ($FirstError) { $parts += $FirstError.text }
    foreach ($path in @($Process.stdout, $Process.stderr)) {
        $tail = (Get-Content -LiteralPath $path -Tail 16 -Encoding utf8 |
            Where-Object { -not $FirstError -or $_ -cne $FirstError.text }) -join "`n"
        if ($tail.Length -gt 4000) { $tail = "...`n" + $tail.Substring($tail.Length - 4000) }
        if ($tail) { $parts += $tail }
    }
    return ($parts -join "`n")
}

function Get-RtlCompileArguments($Project, [string]$Program) {
    $compileArgs = @('-g2012', '-grelative-include', '-Wall', '-s', $Project.Top, '-o', $Program)
    foreach ($dir in $Project.IncludeDirs) { $compileArgs += @('-I', "./$dir") }
    foreach ($define in $Project.Defines) { $compileArgs += "-D$define" }
    $compileArgs += @(Get-RtlSimulationSourceArguments $Project)
    return $compileArgs
}

function Get-RtlSimulationSourceArguments($Project) {
    foreach ($source in (@($Project['SimulationSources']) + $Project.Sources + $Project.Testbenches)) {
        if ($source) { "./$source" }
    }
}

function New-RtlCheckReport([string]$Engine) {
    return [ordered]@{
        engine = $Engine
        status = 'failed'
        stage = 'compile'
        exitCode = $null
        timedOut = $false
        firstError = $null
        diagnostic = $null
        compile = $null
        simulate = $null
        waveform = $null
        regressions = @()
        regressionsPassed = 0
        failedRegression = $null
        synthesis = $null
        fit = $null
        timing = $null
    }
}

function Invoke-RtlIcarusCheck($Project, [string]$WorkDirectory, [string]$LogDirectory,
                              [string]$Compiler, [string]$Simulator, [int]$TimeoutSeconds) {
    # Keep the output binary outside the sources and runtime data.
    $program = Join-Path $LogDirectory 'simulation.vvp'
    $compileArgs = @(Get-RtlCompileArguments $Project $program)
    $result = Invoke-RtlProcess $Compiler $compileArgs $WorkDirectory (Join-Path $LogDirectory 'compile') $TimeoutSeconds
    $report = New-RtlCheckReport 'icarus'
    $report.compile = $result
    $report.exitCode = $result.exitCode
    $report.timedOut = $result.timedOut
    if ($result.timedOut -or $result.exitCode -ne 0) {
        $message = if ($result.timedOut) { "Compilation timed out after $TimeoutSeconds s." } else { 'Compilation failed.' }
        $report.firstError = Get-RtlFirstError $result 'compile' $WorkDirectory
        $report.diagnostic = Get-RtlDiagnostics $result $message $report.firstError
        return $report
    }
    if ($Project.Testbenches.Count -eq 0) {
        $report.status = 'passed'
        return $report
    }

    $result = Invoke-RtlProcess $Simulator @('-N', $program) $WorkDirectory (Join-Path $LogDirectory 'simulate') $TimeoutSeconds
    $report.stage = 'simulate'
    $report.simulate = $result
    $report.exitCode = $result.exitCode
    $report.timedOut = $result.timedOut
    $report.firstError = Get-RtlFirstError $result 'simulate' $WorkDirectory
    $message = if ($result.timedOut) {
        "Simulation timed out after $TimeoutSeconds s."
    } elseif ($result.exitCode -ne 0) {
        'Simulation failed.'
    } elseif ($report.firstError) {
        'Simulation reported an assertion error.'
    } elseif (-not (Select-String -LiteralPath $result.stdout -Pattern ('^' + [regex]::Escape($Project.PassMarker) + '$') -CaseSensitive -Quiet)) {
        "Simulation ended without the success line: $($Project.PassMarker)"
    }
    if ($message) {
        $report.diagnostic = Get-RtlDiagnostics $result $message $report.firstError
    } else {
        $report.status = 'passed'
    }
    return $report
}

function Invoke-RtlSimulationCheck($Project, [string]$WorkDirectory, [string]$LogDirectory,
                                   [string]$Compiler, [string]$Simulator, [int]$TimeoutSeconds,
                                   [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides) {
    $report = if ($Project['Simulator'] -and $Project.Simulator.engine -eq 'modelsim') {
        Invoke-RtlModelSimCheck $Project $WorkDirectory $LogDirectory $TimeoutSeconds
    } else {
        Invoke-RtlIcarusCheck $Project $WorkDirectory $LogDirectory $Compiler $Simulator $TimeoutSeconds
    }
    if ($report.status -eq 'failed' -and $report.stage -eq 'simulate' -and $Project['Waveform']) {
        $report.waveform = Invoke-RtlFailureWaveform $Project $report $ReferenceRoot $Overrides $LogDirectory $Compiler $Simulator $TimeoutSeconds
    }
    return $report
}

function Invoke-RtlCheck($Project, [string]$WorkDirectory, [string]$LogDirectory,
                         [string]$Compiler, [string]$Simulator, [int]$TimeoutSeconds,
                         [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides) {
    $report = Invoke-RtlSimulationCheck $Project $WorkDirectory $LogDirectory $Compiler $Simulator $TimeoutSeconds $ReferenceRoot $Overrides
    if ($report.status -ne 'passed') { return $report }
    Invoke-RtlPublicRegressions $Project $report $LogDirectory $Compiler $Simulator $TimeoutSeconds $ReferenceRoot $Overrides
    if ($report.status -eq 'passed') {
        Add-RtlSynthesisResult $Project $report $ReferenceRoot $Overrides $LogDirectory $TimeoutSeconds
    }
    return $report
}

function Invoke-RtlValidation($Project, $Summary, [string]$Baseline, [string]$Compiler, [string]$Simulator,
                              [int]$TimeoutSeconds, [System.Collections.IDictionary]$Files) {
    if (-not $Project.Validation) { return $true }

    Write-RtlProgress 'Running independent validation...' 'validation'
    $logs = Join-Path $Summary.runDirectory 'validation'
    $work = Join-Path $logs 'work'
    Copy-RtlInputs $Project.Validation $Baseline $work
    if ($Files) { Write-RtlFiles $work $Files }

    $Summary.validation = Invoke-RtlSimulationCheck $Project.Validation $work $logs $Compiler $Simulator $TimeoutSeconds $Baseline $Files
    if ($Summary.validation.status -eq 'error') { throw $Summary.validation.diagnostic }
    if ($Summary.validation.status -eq 'passed') { return $true }
    $Summary.stopReason = 'validation_failed'
    Write-RtlProgress $Summary.validation.diagnostic
    return $false
}
