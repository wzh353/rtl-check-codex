#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'lib/Check.ps1')
. (Join-Path $toolRoot 'lib/Repair.ps1')
$cli = Join-Path $toolRoot 'rtl-check.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-regression-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$fixture = Join-Path $root 'project'
Copy-Item -LiteralPath (Join-Path $toolRoot 'examples/counter') -Destination $fixture -Recurse
$configPath = Join-Path $fixture 'rtlcheck.json'
$source = Join-Path $fixture 'counter.sv'
$validation = Join-Path $fixture 'counter_validation_tb.sv'
$guard = Join-Path $fixture 'guard_tb.sv'
$guardData = Join-Path $fixture 'guard.data'
$stress = Join-Path $fixture 'reset_regression_tb.sv'
$fixed = [IO.File]::ReadAllText($source).Replace("count + 8'd2", "count + 8'd1")
$asynchronous = $fixed.Replace('posedge clk)', 'posedge clk or negedge rst_n)')
[IO.File]::WriteAllText($source, $asynchronous)
[IO.File]::WriteAllText($guardData, 'fixture for the first regression')
[IO.File]::WriteAllText($guard, @'
module guard_tb;
    integer handle;
    initial begin
        handle = $fopen("guard.data", "r");
        if (handle == 0 || `EXPECT_VALUE != 5) $fatal(1, "case files or override missing");
        $fclose(handle);
        $display("GUARD_PASS");
        $finish;
    end
endmodule
'@)
$validationText = [IO.File]::ReadAllText($validation)
[IO.File]::WriteAllText($stress, $validationText.Replace('counter_validation_tb', 'reset_regression_tb').
    Replace('independent reset check', 'public reset check'))
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
$config.repairFiles = @('counter.sv')
$config.defines = @('EXPECT_VALUE=1')
$config.regressions = @(
    @{ id = 'case-data'; top = 'guard_tb'; testbenches = @('guard_tb.sv'); supportFiles = @('guard.data')
        defines = @('EXPECT_VALUE=5'); passMarker = 'GUARD_PASS' },
    @{ id = 'reset-timing'; top = 'reset_regression_tb'; testbenches = @('reset_regression_tb.sv')
        passMarker = $config.validation.passMarker }
)

function Invoke-RegressionTest([string]$Name, [int]$ExpectedExit, [scriptblock]$Verify,
                               [string]$Mode = 'check') {
    [IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $config -Depth 8))
    $raw = & ([Environment]::ProcessPath) -NoProfile -File $cli $Mode -Config $configPath -Json
    $actual = $LASTEXITCODE
    $result = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($actual -ne $ExpectedExit) {
        throw "$Name returned $actual instead of $ExpectedExit. $($result.error) $($result.initial.diagnostic)"
    }
    & $Verify $result
    Write-Host "PASS $Name"
    return $result
}

try {
    $null = Invoke-RegressionTest 'Runs additional test tops and reports the first failure with its evidence' 1 {
        param($result)
        $initial = $result.initial
        $guardCheck = $initial.regressions[0].check
        $failedCheck = $initial.regressions[1].check
        if ($initial.simulate.exitCode -ne 0 -or $initial.stage -ne 'regression' -or
            $initial.failedRegression -ne 'reset-timing' -or $initial.regressionsPassed -ne 1 -or
            $guardCheck.status -ne 'passed' -or $failedCheck.stage -ne 'simulate' -or
            $initial.firstError.inputFile -ne 'reset_regression_tb.sv' -or $result.validation) {
            throw 'Expected a pass in the first case and a structured independent failure in the second case.'
        }
        if (-not [IO.File]::Exists((Join-Path $guardCheck.simulate.workingDirectory 'guard.data')) -or
            [IO.File]::Exists((Join-Path $initial.simulate.workingDirectory 'guard.data')) -or
            [IO.File]::Exists((Join-Path $failedCheck.simulate.workingDirectory 'guard.data')) -or
            [IO.File]::Exists((Join-Path $guardCheck.simulate.workingDirectory 'counter_validation_tb.sv'))) {
            throw 'Per-case runtime files must be isolated from other test runs and the private testbench.'
        }
    }

    [IO.File]::WriteAllText($source, $fixed)
    $good = Invoke-RegressionTest 'Runs independent validation after every public case passes' 0 {
        param($result)
        if ($result.initial.regressionsPassed -ne 2 -or $result.validation.status -ne 'passed' -or $result.attempts.Count) {
            throw 'Expected all public checks followed by independent validation.'
        }
    }

    [IO.File]::AppendAllText($guardData, "`nchanged after the run")
    $project = Read-RtlProject $configPath
    $baseline = Join-Path $good.runDirectory 'baseline'
    $candidate = @{ 'counter.sv' = [Text.Encoding]::UTF8.GetBytes($fixed + "`n// candidate") }
    $failure = try { Publish-RtlRepair $project $baseline $candidate } catch { $_.Exception.Message }
    if ($failure -notmatch 'changed since the baseline: guard\.data' -or [IO.File]::ReadAllText($source) -cne $fixed) {
        throw 'A changed regression fixture must prevent publication.'
    }
    Write-Host 'PASS Refuses publication when a regression input changed'

    $config.regressions[1].id = 'CASE-DATA'
    $null = Invoke-RegressionTest 'Rejects duplicate case identifiers before compiling' 2 {
        param($result)
        if ($result.initial -or $result.error -notmatch 'Duplicate regression id') { throw 'Expected a duplicate case ID error.' }
    }
    $config.regressions[1].id = 'reset-timing'

    $config.regressions[1].supportFiles = @('counter_validation_tb.sv')
    $null = Invoke-RegressionTest 'Rejects a private testbench staged as public case data' 2 {
        param($result)
        if ($result.initial -or $result.error -notmatch 'validation.testbenches') { throw 'Expected private testbench disjointness.' }
    }
    $null = $config.regressions[1].Remove('supportFiles')

    $config.top = 'counter'
    $null = $config.Remove('testbenches')
    $null = Invoke-RegressionTest 'Allows public regressions to provide self-checking tests after compile-only top' 0 {
        param($result)
        if ($result.initial.simulate -or $result.initial.regressionsPassed -ne 2 -or $result.validation.status -ne 'passed') {
            throw 'Expected the public cases and holdout to run after a compile-only design entry.'
        }
    } -Mode repair
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-regression-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '6 regression suite tests passed.'
