function Read-RtlExtraSuite($Project, $Config, [string]$Field) {
    if ($Config -isnot [System.Collections.IDictionary] -or $Config['testbenches'] -isnot [array] -or
        $Config['testbenches'].Count -eq 0) {
        throw "$Field must be an object with a top and a nonempty array of testbenches."
    }
    foreach ($key in @('supportFiles', 'includeDirs')) {
        if ($Config.Contains($key) -and $Config[$key] -isnot [array]) { throw "$Field.$key must be an array." }
    }
    $suite = Read-RtlTestSuite $Project.Root $Config $Project.Sources
    $suite.Simulator = Read-RtlSimulatorSettings $Project.Root $Config $Project.Simulator
    $suite.SimulationSources = $Project.SimulationSources
    if ($suite.Testbenches | Where-Object { $_ -in $suite.SimulationSources }) {
        throw "List each compilation input only once across simulationSources and $Field.testbenches."
    }
    $support = @(foreach ($file in $Config['supportFiles']) { Resolve-RtlProjectItem $Project.Root $file })
    $include = @(foreach ($folder in $Config['includeDirs']) { Resolve-RtlProjectItem $Project.Root $folder -Directory })
    $localDefines = @(Read-RtlMacroDefinitions $Config "$Field.defines")
    $definedHere = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($definition in $localDefines) {
        if (-not $definedHere.Add($definition.Split('=', 2)[0])) { throw "List each macro name once in $Field.defines." }
    }
    $inheritedDefines = @($Project.Defines | Where-Object { -not $definedHere.Contains($_.Split('=', 2)[0]) })
    $suite.SupportFiles = @($Project.SupportFiles + $support | Sort-Object -Unique)
    $suite.IncludeDirs = @($Project.IncludeDirs + $include | Select-Object -Unique)
    $suite.Defines = $inheritedDefines + $localDefines
    $suite.InputFiles = @($suite.SimulationSources + $suite.Sources + $suite.Testbenches + $suite.SupportFiles | Sort-Object -Unique)
    return $suite
}

function Read-RtlRegressions($Project, $Config) {
    if (-not $Config.Contains('regressions')) { return }
    if ($Config['regressions'] -isnot [array]) { throw 'regressions must be an array.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $keys = @('id', 'top', 'testbenches', 'passMarker', 'simulator', 'waveform', 'supportFiles', 'includeDirs', 'defines')
    foreach ($case in $Config['regressions']) {
        if ($case -isnot [System.Collections.IDictionary] -or $case['id'] -isnot [string] -or
            $case['id'] -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z') {
            throw 'Each regression requires an id made of letters, digits, underscores or hyphens.'
        }
        $id = $case['id']
        if (-not $seen.Add($id)) { throw "Duplicate regression id '$id'." }
        foreach ($key in $case.Keys) {
            if ($key -cnotin $keys) { throw "Unknown field '$key' in regression '$id'." }
        }
        $suite = Read-RtlExtraSuite $Project $case "regressions.$id"
        $suite.Id = $id
        $suite
    }
}

function Get-RtlPublicFiles($Project) {
    $caseFiles = @(foreach ($case in $Project['Regressions']) { $case.InputFiles })
    return @($Project.InputFiles + $caseFiles | Sort-Object -Unique)
}

function Get-RtlProjectSuites($Project) {
    $Project
    foreach ($case in $Project['Regressions']) { $case }
    if ($Project['Validation']) { $Project.Validation }
}

function Invoke-RtlPublicRegressions($Project, $Report, [string]$LogDirectory, [string]$Compiler, [string]$Simulator,
                                     [int]$TimeoutSeconds, [string]$ReferenceRoot, [System.Collections.IDictionary]$Overrides) {
    foreach ($suite in $Project['Regressions']) {
        $Report.stage = 'regression'
        Write-RtlProgress "Running public regression '$($suite.Id)'..." 'regression'
        $folder = '{0:D2}-{1}' -f ($Report.regressions.Count + 1), $suite.Id
        $logs = Join-Path (Join-Path $LogDirectory 'regressions') $folder
        $work = Join-Path $logs 'work'
        Copy-RtlInputs $suite $ReferenceRoot $work
        if ($Overrides) { Write-RtlFiles $work $Overrides }
        $result = Invoke-RtlSimulationCheck $suite $work $logs $Compiler $Simulator $TimeoutSeconds $ReferenceRoot $Overrides
        $Report.regressions += [ordered]@{ id = $suite.Id; workingDirectory = $work; check = $result }
        if ($result.status -eq 'passed') {
            $Report.regressionsPassed++
            continue
        }
        $Report.failedRegression = $suite.Id
        foreach ($key in @('status', 'exitCode', 'timedOut', 'firstError', 'waveform')) { $Report[$key] = $result[$key] }
        $Report.diagnostic = "Public regression '$($suite.Id)' failed. $($result.diagnostic)"
        return
    }
}
