#requires -Version 7.2

param([string]$QuartusMap)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $toolRoot 'rtl-check.ps1'
if (-not $QuartusMap) {
    $command = Get-Command quartus_map -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $QuartusMap = $command.Source }
    elseif ($env:QUARTUS_ROOTDIR) {
        $QuartusMap = @('bin64/quartus_map.exe', 'bin/quartus_map.exe' | ForEach-Object {
            Join-Path $env:QUARTUS_ROOTDIR $_
        } | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1) -join ''
    }
}
if (-not $QuartusMap -or -not [IO.File]::Exists($QuartusMap)) {
    Write-Host 'SKIP Quartus integration tests. Provide -QuartusMap or install quartus_map.'
    exit 0
}

$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-synthesis-tests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($root)
$fixture = Join-Path $toolRoot 'examples/counter'
$source = Join-Path $root 'counter.sv'
Copy-Item -LiteralPath (Join-Path $fixture 'counter.sv') -Destination $source
$original = [IO.File]::ReadAllText($source)
$config = Join-Path $root 'rtlcheck.json'
$settings = @{
    top = 'counter_tb'
    sources = @('counter.sv')
    testbenches = @('counter_tb.sv')
    synthesis = @{
        top = 'counter'
        family = 'Cyclone IV E'
        device = 'EP4CE6E22C8'
        executable = $QuartusMap
        failOnWarnings = @(13410)
    }
}
[IO.File]::WriteAllText((Join-Path $root 'counter_tb.sv'), @'
module counter_tb;
    reg clk = 0, rst_n = 0, en = 1;
    wire [7:0] count;
    counter dut (clk, rst_n, en, count);
    initial begin
        #5 clk = 1;
        #1;
        if (count !== 0) $fatal(1, "reset failed");
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule
'@)

function Invoke-Check([int]$ExpectedExit) {
    [IO.File]::WriteAllText($config, (ConvertTo-Json -InputObject $settings -Depth 5))
    $output = & ([Environment]::ProcessPath) -NoProfile -File $tool check -Config $config -TimeoutSeconds 45 -Json
    if ($LASTEXITCODE -ne $ExpectedExit) { throw "Expected exit $ExpectedExit, got $LASTEXITCODE. $output" }
    return ($output -join "`n" | ConvertFrom-Json -AsHashtable)
}

try {
    $failed = Invoke-Check 1
    if ($failed.initial.stage -ne 'synthesize' -or $failed.initial.simulate.exitCode -ne 0 -or
        $failed.initial.synthesis.status -ne 'failed' -or $failed.initial.firstError.code -ne 13410 -or
        $failed.initial.firstError.message -notmatch 'count\[0\]' -or [IO.File]::ReadAllText($source) -cne $original) {
        throw 'A configured stuck-pin warning must fail synthesis after successful simulation.'
    }
    Write-Host 'PASS Rejects a configured Quartus warning after successful simulation'

    $settings.synthesis['failOnWarnings'] = @()
    $reported = Invoke-Check 0
    if ($reported.initial.synthesis.status -ne 'passed' -or
        13410 -notin $reported.initial.synthesis.warnings.code -or $reported.initial.synthesis.logicCells -le 0) {
        throw 'The full check must expose synthesis warnings and resource counts.'
    }
    Write-Host 'PASS Reports Quartus warnings and synthesized logic cell count'

    $settings.synthesis['failOnWarnings'] = @(13410)
    [IO.File]::WriteAllText($source, $original.Replace("count + 8'd2", "count + 8'd1"))
    $passing = Invoke-Check 0
    if ($passing.initial.synthesis.status -ne 'passed' -or 13410 -in $passing.initial.synthesis.warnings.code) {
        throw 'The repaired counter must pass the same synthesis gate.'
    }
    Write-Host 'PASS Accepts the corrected RTL on the same FPGA target'

    $settings['defines'] = @('SIMULATION=1')
    $simBranch = @'
`ifdef SIMULATION
            count <= count + 8'd1;
`else
            count <= count + 8'd2;
`endif
'@
    [IO.File]::WriteAllText($source, $original.Replace("            count <= count + 8'd2;", $simBranch))
    $separate = Invoke-Check 1
    if ($separate.initial.firstError.code -ne 13410) { throw 'The behavioral macro leaked into synthesis.' }
    $settings.synthesis.defines = @('SIMULATION=1')
    $optIn = Invoke-Check 0
    if ($optIn.initial.synthesis.status -ne 'passed') { throw 'Explicit synthesis macros were not passed.' }
    Write-Host 'PASS Keeps simulation macros separate from explicit synthesis macros'

    $settings.synthesis.defines = @()
    [IO.File]::WriteAllText($source, ("// padding`n" * 1000) +
        $original.Replace("            count <= count + 8'd2;", $simBranch.Replace("8'd2;", ';')))
    $syntax = Invoke-Check 1
    if ($syntax.initial.firstError.inputFile -ne 'counter.sv' -or $syntax.initial.firstError.line -lt 1000) {
        throw 'Expected the location of the hardware-only syntax error.'
    }
    Write-Host 'PASS Normalizes a Quartus error location in a long source'
    $settings.Remove('defines')
    [IO.File]::WriteAllText($source, $original.Replace("count + 8'd2", "count + 8'd1"))

    $settings.synthesis.device = 'DEVICE_DOES_NOT_EXIST'
    $badPart = Invoke-Check 2
    if ($badPart.initial.synthesis.status -ne 'error' -or $badPart.error -notmatch 'FPGA part' -or $badPart.attempts.Count -ne 0) {
        throw 'An invalid target part must stay a configuration error.'
    }
    Write-Host 'PASS Classifies an invalid FPGA part as a configuration error'

    $settings.synthesis.device = 'EP4CE6E22C8'
    $settings.synthesis.executable = (Get-Command iverilog -CommandType Application -ErrorAction Stop).Source
    $launcher = Invoke-Check 2
    if ($launcher.initial.synthesis.status -ne 'error' -or $launcher.error -notmatch 'Quartus result') {
        throw 'Missing Quartus completion diagnostics must be a tool error.'
    }
    Write-Host 'PASS Classifies launcher failures without a design diagnostic as tool errors'

    $settings.synthesis.executable = 'quartus_map-does-not-exist.exe'
    $missing = Invoke-Check 2
    if ($missing.initial -or $missing.error -notmatch 'quartus_map') { throw 'Expected an early tool configuration error.' }
    Write-Host 'PASS Reports a missing Quartus executable as a tool error'
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved) -match '^rtl-synthesis-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host '8 synthesis tests passed.'
