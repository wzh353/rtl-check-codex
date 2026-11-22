. (Join-Path $PSScriptRoot 'Vivado.ps1')
. (Join-Path $PSScriptRoot 'Gowin.ps1')
. (Join-Path $PSScriptRoot 'GowinTiming.ps1')
. (Join-Path $PSScriptRoot 'Lattice.ps1')
. (Join-Path $PSScriptRoot 'Libero.ps1')
. (Join-Path $PSScriptRoot 'Efinity.ps1')

$script:RtlVendorTools = [ordered]@{
    vivado = @{ label = 'AMD Vivado'; command = 'vivado'; constraints = @('.xdc'); required = @(); fields = @() }
    gowin = @{ label = 'Gowin EDA'; command = 'gw_sh'; constraints = @('.cst', '.sdc'); required = @('deviceVariant'); fields = @('timing') }
    radiant = @{ label = 'Lattice Radiant'; command = 'radiantc'; constraints = @('.pdc', '.sdc', '.fdc'); required = @('performance'); fields = @() }
    diamond = @{ label = 'Lattice Diamond'; command = 'diamondc'; constraints = @('.lpf', '.sdc', '.fdc'); required = @(); fields = @() }
    libero = @{ label = 'Microchip Libero SoC'; command = 'libero'; constraints = @('.sdc'); required = @('family', 'package'); fields = @('speed') }
    efinity = @{ label = 'Efinix Efinity'; command = 'efx_run'; constraints = @(); required = @('family', 'timingModel'); fields = @() }
}

function Read-RtlVendorSettings([string]$Root, $Settings, $Result) {
    $engine = $Result.engine
    $vendor = $script:RtlVendorTools[$engine]
    $keys = @('engine', 'top', 'family', 'device', 'executable', 'defines', 'constraintFiles', 'implementation') +
        $vendor.required + $vendor.fields
    foreach ($key in $Settings.Keys) {
        if ($key -cnotin $keys) { throw "Unknown synthesis field for $($vendor.label): $key" }
    }
    foreach ($key in @('family', 'deviceVariant', 'performance', 'package', 'speed', 'timingModel')) {
        $value = $Settings[$key]
        if ($key -in $vendor.required -or $Settings.Contains($key)) {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                throw "synthesis.$key must be a nonempty string for $($vendor.label)."
            }
        }
        $Result[$key] = $value
    }
    if ($Settings.Contains('implementation') -and $Settings['implementation'] -isnot [bool]) {
        throw 'synthesis.implementation must be a boolean.'
    }
    $Result.implementation = $Settings['implementation'] -eq $true
    if ($Result.implementation -and $engine -eq 'efinity') {
        throw 'Efinity currently supports synthesis only.'
    }
    if ($Result.defines.Count -and $engine -in @('gowin', 'efinity')) {
        throw "synthesis.defines is unavailable for $($vendor.label). Declare hardware macros in a project HDL header."
    }
    if ($Settings.Contains('constraintFiles') -and $Settings['constraintFiles'] -isnot [array]) {
        throw 'synthesis.constraintFiles must be an array.'
    }
    $files = @(foreach ($name in $Settings['constraintFiles']) {
        $path = Resolve-RtlProjectItem $Root $name
        if ([IO.Path]::GetExtension($path) -notin $vendor.constraints) {
            throw "Unsupported synthesis constraint file for $($vendor.label): $name"
        }
        $path
    })
    if (@($files | Sort-Object -Unique).Count -ne $files.Count) {
        throw 'List each synthesis constraint file once.'
    }
    $singleFileTypes = if ($engine -eq 'gowin') { @('.cst', '.sdc') } else { @('.lpf', '.pdc') }
    foreach ($extension in $singleFileTypes) {
        if (@($files | Where-Object { [IO.Path]::GetExtension($_) -eq $extension }).Count -gt 1) {
            throw "Only one $extension constraint file is supported for $($vendor.label)."
        }
    }
    $Result.constraintFiles = $files
    $Result.board = $null
    $Result.timing = $null
    if ($Settings.Contains('timing')) {
        if ($Settings.Contains('implementation') -and -not $Result.implementation) {
            throw 'Gowin timing requires place and route. Remove synthesis.implementation or set it to true.'
        }
        $Result.timing = Read-RtlGowinTimingSettings $Settings['timing'] $files
        $Result.implementation = $true
    }
    return $Result
}

function Find-RtlVendorExecutable($Settings) {
    $vendor = $script:RtlVendorTools[$Settings.engine]
    if ($Settings.executable) {
        if (-not [IO.File]::Exists($Settings.executable)) {
            throw "$($vendor.label) executable was not found: $($Settings.executable)"
        }
        return $Settings.executable
    }
    $commands = @($vendor.command)
    if ($Settings.engine -eq 'efinity' -and -not $IsWindows) { $commands += 'efx_run.py' }
    $command = Get-Command -Name $commands -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $launcher = if ($IsWindows -and $Settings.engine -in @('diamond', 'radiant')) { 'pnmainc.exe from the matching installation' }
    else { $vendor.command }
    throw "$($vendor.label) was not found. Set synthesis.executable to $launcher or add $($vendor.command) to PATH."
}

function Get-RtlVendorEnvironment($Settings) {
    $variables = @{}
    if ($IsWindows -and $Settings.engine -in @('radiant', 'diamond')) {
        $bin = [IO.Path]::GetDirectoryName($Settings.executable)
        if ([IO.Path]::GetFileName($bin) -eq 'nt64') {
            $root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($bin))
            $foundry = Join-Path $root 'ispfpga'
            $variables.PATH = "$bin;$(Join-Path $foundry 'bin/nt64');$env:PATH"
            if ([IO.Directory]::Exists($foundry)) { $variables.FOUNDRY = $foundry }
        }
    }
    return $variables
}

function Invoke-RtlVendorProcess($Settings, [string[]]$Arguments, [string]$Work, [string]$ArtifactRelative,
                                [string]$LogPrefix, [int]$TimeoutSeconds, [string]$SetupBatch) {
    $environment = Get-RtlVendorEnvironment $Settings
    $executable = $Settings.executable
    if ($IsWindows -and ($SetupBatch -or [IO.Path]::GetExtension($executable) -in @('.cmd', '.bat'))) {
        $environment.RTL_CHECK_EDA_LAUNCHER = $executable
        $wrapper = "$ArtifactRelative/launch.cmd"
        $lines = @('@echo off', 'setlocal DisableDelayedExpansion')
        if ($SetupBatch) {
            $environment.RTL_CHECK_EDA_SETUP = $SetupBatch
            $environment.RTL_CHECK_EDA_WORK = $Work
            $setupDirectory = [IO.Path]::GetDirectoryName($SetupBatch)
            if ([IO.Path]::GetFileName($setupDirectory) -eq 'bin') {
                $setupDirectory = [IO.Path]::GetDirectoryName($setupDirectory)
            }
            $environment.RTL_CHECK_EDA_SETUP_DIR = $setupDirectory
            $lines += @(
                'cd /d "%RTL_CHECK_EDA_SETUP_DIR%"'
                'if errorlevel 1 exit /b %errorlevel%'
                'call "%%RTL_CHECK_EDA_SETUP%%"'
                'if errorlevel 1 exit /b %errorlevel%'
                'setlocal DisableDelayedExpansion'
                'cd /d "%RTL_CHECK_EDA_WORK%"'
                'if errorlevel 1 exit /b %errorlevel%'
            )
        }
        $words = @(for ($index = 0; $index -lt $Arguments.Count; $index++) {
            $argument = $Arguments[$index]
            if ($argument -cmatch '\A[A-Za-z0-9_.:/-]+\z') {
                $argument
            } else {
                if ($argument -match '["\r\n\0]') { throw 'Invalid Windows FPGA launcher argument.' }
                $name = "RTL_CHECK_EDA_ARGUMENT_$index"
                $environment[$name] = $argument
                '"%{0}%"' -f $name
            }
        })
        $lines += '"%RTL_CHECK_EDA_LAUNCHER%" ' + ($words -join ' ')
        [IO.File]::WriteAllLines((Join-Path $Work $wrapper), [string[]]$lines)
        $executable = $env:ComSpec
        $Arguments = @('/d', '/s', '/c', $wrapper.Replace('/', '\'))
    }
    return Invoke-RtlProcess $executable $Arguments $Work $LogPrefix $TimeoutSeconds -Environment $environment
}

function Write-RtlVendorTcl($Project, [string]$Work, [string]$ArtifactRelative, $Steps) {
    $settings = $Project.Synthesis
    $folder = Join-Path $Work $ArtifactRelative
    $values = [ordered]@{
        top = $settings.top; device = $settings.device; family = $settings.family
        device_variant = $settings.deviceVariant; performance = $settings.performance
        package = $settings.package; speed = $settings.speed
    }
    # Tcl file normalize resolves Windows junctions and can reintroduce the long path.
    $inputs = @("set rtlcheck_artifacts $(ConvertTo-RtlTclWord $folder.Replace('\', '/'))")
    $inputs += @(foreach ($key in $values.Keys) { "set rtlcheck_$key $(ConvertTo-RtlTclWord $values[$key])" })
    $pathLists = [ordered]@{
        sources = $Project.Sources; include_dirs = $Project.IncludeDirs; constraints = $settings.constraintFiles
    }
    foreach ($key in $pathLists.Keys) {
        $paths = foreach ($path in $pathLists[$key]) {
            ConvertTo-RtlTclWord (Join-Path $Work $path).Replace('\', '/')
        }
        $inputs += "set rtlcheck_$key [list $($paths -join ' ')]"
    }
    $defines = foreach ($define in $settings.defines) { ConvertTo-RtlTclWord $define }
    $inputs += "set rtlcheck_defines [list $($defines -join ' ')]"
    [IO.File]::WriteAllLines((Join-Path $folder 'inputs.tcl'), [string[]]$inputs)

    $driver = @("source -encoding utf-8 $ArtifactRelative/inputs.tcl") + (@'
set rtlcheck_status [open [file join $rtlcheck_artifacts stages.log] {WRONLY CREAT EXCL}]
proc rtlcheck_mark {event stage} {
    global rtlcheck_status
    puts $rtlcheck_status "$event $stage"
    flush $rtlcheck_status
    catch {puts "RTL_CHECK_VENDOR_$event $stage"; flush stdout}
}
proc rtlcheck_stage {stage} {
    global rtlcheck_artifacts
    rtlcheck_mark BEGIN $stage
    if {[catch {uplevel #0 [list source -encoding utf-8 [file join $rtlcheck_artifacts $stage.tcl]]} message]} {
        set error_file [open [file join $rtlcheck_artifacts stage-error.log] {WRONLY CREAT EXCL}]
        fconfigure $error_file -encoding utf-8
        puts $error_file "ERROR: $message"
        close $error_file
        catch {puts stderr "RTL_CHECK_VENDOR_ERROR $message"; flush stderr}
        exit 1
    }
    rtlcheck_mark OK $stage
}
'@ -split '\r?\n')
    foreach ($stage in $Steps.Keys) {
        [IO.File]::WriteAllLines((Join-Path $folder "$stage.tcl"), [string[]]$Steps[$stage])
        $driver += "rtlcheck_stage $stage"
    }
    [IO.File]::WriteAllLines((Join-Path $folder 'run.tcl'), [string[]]($driver + @('close $rtlcheck_status', 'exit 0')))
}

function Get-RtlVendorArguments($Settings, [string]$ArtifactRelative) {
    $entry = "$ArtifactRelative/run.tcl"
    switch ($Settings.engine) {
        vivado { return @('-mode', 'batch', '-nojournal', '-source', $entry) }
        libero { return @("SCRIPT:$entry", "LOGFILE:$ArtifactRelative/libero-console.log") }
        radiant {
            if ($IsWindows -and [IO.Path]::GetFileNameWithoutExtension($Settings.executable) -eq 'radiantc') {
                return @('-source', $entry)
            }
        }
    }
    return @($entry)
}

function Get-RtlVendorFirstError($Process, [string[]]$AdditionalLogs, [string]$ReportedWork) {
    $logs = @($Process.stdout, $Process.stderr) + $AdditionalLogs
    $issuePattern = '^\s*(?:ERROR|FATAL)\s*(?:\((?<code>[^)]+)\)|(?<code>\d+))?\s*[:-]\s*(?:\[(?<code>[^]]+)\]\s*)?(?<message>.*)$|^\s*@E[:|]\s*(?<message>.*)$'
    $extension = '\.(?:svh|vh|sv|v|sdc|xdc|cst|pdc|fdc|lpf)'
    $location = "\[(?<file>[^]]+$extension):(?<line>\d+)\]|\((?<file>[^()]+$extension)\)\s*:\s*(?<line>\d+)"
    $location += '|["](?<file>[^"]+' + $extension + ')["]:\s*(?<line>\d+)|(?<file>(?:[A-Za-z]:)?[^():\r\n]+' +
        $extension + ')\((?<line>\d+)\)'
    $first = $null
    foreach ($entry in (Select-String -LiteralPath $logs -Pattern $issuePattern)) {
        $groups = $entry.Matches[0].Groups
        $messageText = $groups['message'].Value
        $match = [regex]::Match($messageText, $location, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $file = if ($match.Success) { $match.Groups['file'].Value.Trim() }
        $line = 0
        $hasLine = $match.Success -and [int]::TryParse($match.Groups['line'].Value, [ref]$line)
        $inputFile = Get-RtlDiagnosticInputFile $file $Process.workingDirectory
        if (-not $inputFile) { $inputFile = Get-RtlDiagnosticInputFile $file $ReportedWork }
        $issue = [ordered]@{
            code = $groups['code'].Value; file = $file; inputFile = $inputFile
            line = if ($hasLine) { $line }
            message = $messageText; text = $entry.Line.Trim(); log = $entry.Path
        }
        if (-not $first) { $first = $issue }
        if ($issue.message -match '(?i)(licen[cs]e|flexnet).*(checkout|fail|error|unavailable|denied|not found|expired)') {
            $issue.infrastructure = $true
            return $issue
        }
        if ($file -and $inputFile -and (-not $first.inputFile -or -not $first.line)) { $first = $issue }
    }
    return $first
}

function New-RtlVendorStageResult($Settings, $Process, [string]$Stage, [string]$Artifacts, [string]$ReportPath,
                                  $FirstError, [bool]$Passed, [int]$TimeoutSeconds) {
    $vendor = $script:RtlVendorTools[$Settings.engine]
    $label = $vendor.label
    $result = [ordered]@{
        engine = $Settings.engine; status = 'passed'; reason = $null; process = $Process
        artifactDirectory = $Artifacts; reportPath = $ReportPath; firstError = $null; diagnostic = $null
    }
    if ($Passed) { return $result }
    $status = 'error'
    $reason = 'inconclusive_result'
    $message = "No conclusive $label result was found for $Stage."
    if ($Process.timedOut) {
        $reason = 'timeout'
        $message = "$label timed out after $TimeoutSeconds s."
    }
    elseif ($FirstError -and $FirstError['infrastructure']) {
        $reason = 'license_error'
        $message = "$label could not use its licence."
    }
    elseif ($FirstError -and (($FirstError.file -and [IO.Path]::GetExtension($FirstError.file) -in $vendor.constraints) -or
                ($Settings.engine -eq 'gowin' -and $FirstError.code -eq 'TA2003'))) {
        $reason = 'invalid_constraints'
        $message = "$label rejected an FPGA constraint."
    }
    elseif ($Stage -eq 'setup' -and (-not $FirstError -or -not $FirstError.inputFile)) {
        $reason = 'setup_failed'
        $message = "$label could not configure the FPGA build."
    }
    elseif ($FirstError -and ($FirstError.inputFile -or
                $FirstError.code -match '^(?:Synth |VRFC |Place |Route |DRC |EX\d|PR\d|CG\d|62001109$|71001187$|60001149$)' -or
                $FirstError.message -match '^par:\s+(?:I/O initial placement is unsuccessful|netsanitycheck:)')) {
        $status = 'failed'
        $reason = 'design_error'
        $message = "$label $Stage failed."
    }
    $result.firstError = $FirstError
    Set-RtlHardwareGateFailure $result $status $reason $message $FirstError
    return $result
}

function Get-RtlVendorReportPath([string]$Engine, [string]$Stage, [string]$Artifacts) {
    $name = switch ("$Engine/$Stage") {
        'vivado/synthesize' { 'utilization.rpt' }
        'vivado/fit' { 'timing-summary.rpt' }
        'gowin/synthesize' { 'gowin/impl/gwsynthesis/rtlcheck_syn.rpt.html' }
        'gowin/fit' { 'gowin/impl/pnr/rtlcheck.rpt.txt' }
        'libero/synthesize' { 'libero-synthesize.log' }
        'libero/fit' { 'libero-fit.log' }
    }
    if ($name) {
        $path = Join-Path $Artifacts $name
        if ([IO.File]::Exists($path)) { $path }
    }
}

function Add-RtlVendorSynthesisResult($Project, $Report, [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides,
                                     [string]$LogDirectory, [int]$TimeoutSeconds, [string]$Work) {
    $settings = $Project.Synthesis
    $engine = $settings.engine
    $tool = $script:RtlVendorTools[$engine]
    Copy-RtlHardwareInputs $Project $ReferenceRoot $Work $Overrides $settings.constraintFiles
    $relative = 'rtlcheck_vendor_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $artifactPath = Join-Path $Work $relative
    $null = [IO.Directory]::CreateDirectory($artifactPath)
    $logFolder = Join-Path $LogDirectory 'synthesis'
    $log = Join-Path $logFolder $engine
    $reportedWork = Join-Path $logFolder 'work'
    Write-RtlProgress "Running $($tool.label) hardware checks..." $engine
    if ($engine -eq 'efinity') {
        $plan = New-RtlEfinityInvocation $Project $Work $relative
        $process = Invoke-RtlVendorProcess $settings $plan.arguments $Work $relative $log $TimeoutSeconds $plan.setupBatch
        $nativeReport = if ([IO.File]::Exists($plan.reportPath)) { $plan.reportPath }
        $mapLog = [IO.Path]::ChangeExtension($plan.reportPath, '.out')
        $nativeLogs = @(@($mapLog, $nativeReport) | Where-Object { $_ -and [IO.File]::Exists($_) })
        $firstError = Get-RtlVendorFirstError $process $nativeLogs $reportedWork
        $netlist = $plan.netlists | Where-Object { [IO.File]::Exists($_) -and [IO.FileInfo]::new($_).Length -gt 0 } | Select-Object -First 1
        $passed = -not $process.timedOut -and $process.exitCode -eq 0 -and $netlist -and
            $nativeReport -and [IO.FileInfo]::new($nativeReport).Length -gt 0 -and -not $firstError
        $result = New-RtlVendorStageResult $settings $process 'synthesize' $artifactPath $nativeReport $firstError $passed $TimeoutSeconds
        Set-RtlHardwareStage $Report 'synthesize' $result
        return
    }

    $steps = switch ($engine) {
        vivado { Get-RtlVivadoSteps $Project }
        gowin { Get-RtlGowinSteps $Project }
        libero { Get-RtlLiberoSteps $Project }
        default { Get-RtlLatticeSteps $Project }
    }
    Write-RtlVendorTcl $Project $Work $relative $steps
    $process = Invoke-RtlVendorProcess $settings (Get-RtlVendorArguments $settings $relative) $Work $relative $log $TimeoutSeconds
    $nativeLogs = @(Get-ChildItem -LiteralPath $artifactPath -Recurse -File -Filter '*.srr' | ForEach-Object FullName)
    $nativeLogs += @(foreach ($name in @('libero-console.log', 'stage-error.log')) {
        $path = Join-Path $artifactPath $name
        if ([IO.File]::Exists($path)) { $path }
    })
    $firstError = Get-RtlVendorFirstError $process $nativeLogs $reportedWork
    $expected = @(foreach ($stage in $steps.Keys) { "BEGIN $stage"; "OK $stage" })
    $statusPath = Join-Path $artifactPath 'stages.log'
    $observed = @(if ([IO.File]::Exists($statusPath)) { [IO.File]::ReadAllLines($statusPath) })
    $matched = 0
    while ($matched -lt $expected.Count -and $matched -lt $observed.Count -and $expected[$matched] -ceq $observed[$matched]) {
        $matched++
    }
    $passed = $matched -eq $expected.Count -and $observed.Count -eq $expected.Count -and
        -not $process.timedOut -and $process.exitCode -eq 0 -and -not $firstError
    $lastGate = [int][Math]::Min([Math]::Floor($matched / 2), $steps.Count - 1)
    $stages = @($steps.Keys)
    for ($index = 1; $index -le [Math]::Max(1, $lastGate); $index++) {
        $stage = $stages[$index]
        $reportedPhase = if ($lastGate -eq 0 -and $matched -eq 1) { 'setup' } else { $stage }
        $stagePassed = $passed -or $index -lt $lastGate
        $nativeReport = Get-RtlVendorReportPath $engine $stage $artifactPath
        $result = New-RtlVendorStageResult $settings $process $reportedPhase $artifactPath $nativeReport $firstError $stagePassed $TimeoutSeconds
        Set-RtlHardwareStage $Report $stage $result
    }
    if ($engine -eq 'gowin' -and $passed -and $settings.timing) {
        Write-RtlProgress 'Checking Gowin post-route timing...' 'gowin-timing'
        $nativeReport = Join-Path $artifactPath 'gowin/impl/pnr/rtlcheck.tr'
        $result = New-RtlVendorStageResult $settings $process 'timing' $artifactPath $nativeReport $null $true $TimeoutSeconds
        Add-RtlGowinTimingEvidence $result $settings.timing $Work $reportedWork
        Set-RtlHardwareStage $Report 'timing' $result
    }
}
