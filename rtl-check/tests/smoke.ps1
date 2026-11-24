#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $toolRoot 'rtl-check.ps1'
$example = Join-Path $toolRoot 'examples/counter'
$root = Join-Path ([IO.Path]::GetTempPath()) "rtl-check-tests-$([guid]::NewGuid().ToString('N'))"
$project = Join-Path $root '计数器 with spaces'
$null = [IO.Directory]::CreateDirectory($root)
Copy-Item -LiteralPath $example -Destination $project -Recurse
$source = Join-Path $project 'counter.sv'
$bench = Join-Path $project 'counter_tb.sv'
$manifest = Join-Path $project 'rtlcheck.json'
$originalManifest = [IO.File]::ReadAllText($manifest)
$originalSource = [IO.File]::ReadAllText($source)
$originalBench = [IO.File]::ReadAllText($bench)
$fixedSource = $originalSource.Replace("count + 8'd2", "count + 8'd1")
$script:tests = 0

function Assert-Equal($Actual, $Expected, [string]$Description) {
    if ($Actual -cne $Expected) {
        throw "$Description, expected '$Expected', got '$Actual'."
    }
}

function Invoke-Case([string]$Name, [int]$ExpectedExit, [scriptblock]$Verify,
                    [string]$Mode = 'check', [string[]]$Options = @()) {
    $output = & ([Environment]::ProcessPath) -NoProfile -File $tool $Mode `
        -Config $manifest -OutDir (Join-Path $root 'runs') -Json @Options
    Assert-Equal $LASTEXITCODE $ExpectedExit "$Name exit code ($output)"
    $result = ($output -join "`n") | ConvertFrom-Json -AsHashtable
    & $Verify $result
    $script:tests++
    Write-Host "PASS $Name"
}

try {
    Invoke-Case 'Reports a reproducible functional counterexample' 1 {
        param($result)
        Assert-Equal $result.initial.stage 'simulate' 'Stage'
        Assert-Equal ($result.initial.diagnostic -match 'cycle=3.*expected=1 actual=2') $true 'Counterexample'
        Assert-Equal $result.initial.firstError.compilerHint $null 'Simulation retains its own diagnosis'
        Assert-Equal $result.validation $null 'Independent validation skipped'
        Assert-Equal ([IO.File]::ReadAllText($source)) $originalSource 'Source preserved'
    }

    [IO.File]::WriteAllText($source, $fixedSource)
    Invoke-Case 'Accepts all counter regression cases' 0 {
        param($result)
        Assert-Equal $result.status 'passed' 'Status'
        Assert-Equal $result.initial.stage 'simulate' 'Stage'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $result.runDirectory 'summary.json')) $true 'Saved report'
    }

    Invoke-Case 'Skips Codex on a passing design' 0 {
        param($result)
        Assert-Equal $result.attempts.Count 0 'Repair attempts'
        Assert-Equal $result.applied $false 'Source write'
    } -Mode repair -Options @('-RepairFile', 'counter.sv')

    $configured = ConvertFrom-Json -InputObject $originalManifest -AsHashtable
    $configured.repairFiles = @('counter.sv')
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject $configured -Depth 5))
    Invoke-Case 'Rejects an explicitly empty target when repairFiles is configured' 2 {
        param($result)
        Assert-Equal ($result.error -match 'RepairFile') $true 'Explicit target error'
    } -Mode repair -Options @('-RepairFile', '')
    [IO.File]::WriteAllText($manifest, $originalManifest)

    [IO.File]::WriteAllText($source, "module counter( ;`n")
    Invoke-Case 'Stops at the compile error' 1 {
        param($result)
        Assert-Equal $result.initial.stage 'compile' 'Stage'
        Assert-Equal ($result.initial.diagnostic -match 'syntax error') $true 'Compiler diagnostic'
        Assert-Equal ($result.initial.firstError.file -match 'counter\.sv$') $true 'Compiler source file'
        Assert-Equal $result.initial.firstError.line 1 'Compiler source line'
        Assert-Equal $result.initial.firstError.compilerHint.category 'syntax' 'Syntax category'
    }

    [IO.File]::WriteAllText($source, @'
`include "missing-defines.vh"
module counter; endmodule
'@)
    Invoke-Case 'Reports the missing include before follow-on compiler errors' 1 {
        param($result)
        Assert-Equal ($result.initial.firstError.file -match 'counter\.sv$') $true 'Including source file'
        Assert-Equal ($result.initial.firstError.message -match 'Include file missing-defines\.vh not found') $true 'Root compiler error'
        Assert-Equal $result.initial.firstError.compilerHint.category 'missing_include' 'Header diagnostic category'
        Assert-Equal ($result.initial.diagnostic.Contains('RTL check hint [missing_include]')) $true 'Advice labeled separately from simulator output'
        Assert-Equal ($result.initial.diagnostic.Contains($result.initial.firstError.compilerHint.inspection)) $true 'Hint delivered alongside the original diagnostic'
    }

    $compileExamples = @(
        @{ category = 'unknown_module'; statement = 'missing_cell u_missing();' },
        @{ category = 'unresolved_name'; statement = 'wire bad = missing_wire;' },
        @{ category = 'port_mismatch'; statement = 'probe u_probe(.absent(en));'; helper = 'module probe(input real_port); endmodule' }
    )
    foreach ($item in $compileExamples) {
        $text = $fixedSource.Replace('endmodule', ($item.statement + "`nendmodule")) + "`n" + $item['helper']
        [IO.File]::WriteAllText($source, $text)
        Invoke-Case "Identifies the Icarus $($item.category) diagnostic" 1 {
            param($result)
            Assert-Equal $result.initial.firstError.compilerHint.category $item.category 'Compiler hint category'
            Assert-Equal ($result.initial.diagnostic.Contains($result.initial.firstError.message)) $true 'Original compiler text'
        }
    }

    [IO.File]::WriteAllText($source, $fixedSource.Replace('endmodule', "wire duplicate_name; wire duplicate_name;`nendmodule"))
    Invoke-Case 'Preserves an unclassified compiler diagnostic' 1 {
        param($result)
        Assert-Equal ($result.initial.firstError.message -match 'duplicate_name') $true 'Unclassified compiler message'
        Assert-Equal $result.initial.firstError.compilerHint $null 'No guessed guidance'
    }

    [IO.File]::WriteAllText($source, $fixedSource)
    [IO.File]::WriteAllText($bench, 'module counter_tb; initial $finish; endmodule')
    Invoke-Case 'Rejects an early finish with exit code zero' 1 {
        param($result)
        Assert-Equal $result.initial.stage 'simulate' 'Stage'
        Assert-Equal $result.initial.exitCode 0 'Simulator exit code'
        Assert-Equal ($result.initial.diagnostic -match 'RTL_CHECK_PASS') $true 'Missing success marker'
    }

    [IO.File]::WriteAllText($bench, 'module counter_tb; initial begin $error("test failed"); $display("RTL_CHECK_PASS"); $finish; end endmodule')
    Invoke-Case 'Rejects an assertion error even with a success marker' 1 {
        param($result)
        Assert-Equal ($result.initial.diagnostic -match 'test failed') $true 'Assertion diagnostic'
    }

    [IO.File]::WriteAllText($bench, @'
module counter_tb;
    initial begin
        $error("first failure cycle=7 expected=9 actual=8");
        repeat (30) $display("trace sample");
        $finish;
    end
endmodule
'@)
    Invoke-Case 'Preserves the first error in a noisy simulation log' 1 {
        param($result)
        Assert-Equal ($result.initial.diagnostic -match 'first failure cycle=7 expected=9 actual=8') $true 'First mismatch'
        Assert-Equal ($result.initial.firstError.file -match 'counter_tb\.sv$') $true 'Testbench source'
        Assert-Equal $result.initial.firstError.line 3 'Assertion line'
    }

    [IO.File]::WriteAllText($bench, 'module counter_tb; reg clk = 0; always #1 clk = ~clk; endmodule')
    Invoke-Case 'Bounds a nonterminating simulation' 1 {
        param($result)
        Assert-Equal $result.initial.stage 'simulate' 'Stage'
        Assert-Equal $result.initial.timedOut $true 'Timeout'
    } -Options @('-TimeoutSeconds', '1')

    [IO.File]::WriteAllText($bench, $originalBench)
    Invoke-Case 'Rejects the testbench as a repair target' 2 {
        param($result)
        Assert-Equal $result.applied $false 'Source write'
        Assert-Equal ([IO.File]::ReadAllText($bench)) $originalBench 'Testbench preserved'
    } -Mode repair -Options @('-RepairFile', 'counter_tb.sv', '-Apply')

    [IO.File]::WriteAllText($manifest, '{"top":"counter","sources":["counter.sv"]}')
    Invoke-Case 'Supports compile-only projects' 0 {
        param($result)
        Assert-Equal $result.initial.stage 'compile' 'Stage'
    }

    [IO.File]::WriteAllText($manifest, $originalManifest)
    $asyncReset = $fixedSource.Replace('posedge clk)', 'posedge clk or negedge rst_n)')
    [IO.File]::WriteAllText($source, $asyncReset)
    Invoke-Case 'Enforces independent validation after the primary test passes' 1 {
        param($result)
        Assert-Equal $result.initial.status 'passed' 'Primary test status'
        Assert-Equal $result.validation.status 'failed' 'Validation status'
        Assert-Equal $result.stopReason 'validation_failed' 'Stop reason'
        Assert-Equal ($result.validation.diagnostic -match 'reset changed count before the clock') $true 'Validation evidence'
        Assert-Equal $result.attempts.Count 0 'Model calls'
        Assert-Equal $result.applied $false 'Source write'
        Assert-Equal ([IO.File]::ReadAllText($source)) $asyncReset 'Source preserved'
    } -Mode repair -Options @('-RepairFile', 'counter.sv', '-Apply')

    [IO.File]::WriteAllText($source, $fixedSource)
    $validationConfig = ConvertFrom-Json -InputObject $originalManifest -AsHashtable
    $validationConfig.validation.supportFiles = @('validation-data.txt')
    [IO.File]::WriteAllText((Join-Path $project 'validation-data.txt'), 'validation data')
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject $validationConfig -Depth 5))
    Invoke-Case 'Accepts both primary and independent test suites' 0 {
        param($result)
        Assert-Equal $result.validation.status 'passed' 'Validation status'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $result.runDirectory 'validation/work/validation-data.txt')) $true 'Validation data staged'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $result.runDirectory '00-initial/work/validation-data.txt')) $false 'Validation data excluded from primary work'
    }

    $validationConfig.validation = @{ top = 'counter_tb'; testbenches = @('counter_tb.sv') }
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json -InputObject $validationConfig -Depth 5))
    Invoke-Case 'Rejects a validation testbench listed among primary inputs' 2 {
        param($result)
        Assert-Equal ($result.error -match 'validation.testbenches') $true 'Configuration error'
    }

    $include = Join-Path $project 'shared headers'
    $null = [IO.Directory]::CreateDirectory($include)
    [IO.File]::WriteAllText((Join-Path $include 'width.vh'), '`define WIDTH 8')
    [IO.File]::WriteAllText((Join-Path $project 'data.hex'), "2a`n")
    [IO.File]::WriteAllText($source, @'
`include "width.vh"
module counter(output [`WIDTH-1:0] value);
    lookup rom (value);
endmodule
'@)
    [IO.File]::WriteAllText((Join-Path $project 'memory model.sv'), @'
module lookup(output [7:0] value);
    reg [7:0] storage [0:0];
    initial $readmemh("data.hex", storage);
    assign value = storage[0];
endmodule
'@)
    [IO.File]::WriteAllText($bench, @'
module counter_tb;
    wire [7:0] value;
    counter dut (value);
    initial begin
        #1;
        if (value !== 8'h2a + `OFFSET) $fatal(1, "wrong ROM value");
        $display("ROM PASSED");
        $finish;
    end
endmodule
'@)
    [IO.File]::WriteAllText($manifest, @'
{
  "top": "counter_tb",
  "sources": ["counter.sv", "memory model.sv"],
  "testbenches": ["counter_tb.sv"],
  "includeDirs": ["shared headers"],
  "supportFiles": ["shared headers/width.vh", "data.hex"],
  "defines": ["OFFSET=0"],
  "passMarker": "ROM PASSED"
}
'@)
    Invoke-Case 'Stages multiple sources, headers and ROM data' 0 {
        param($result)
        Assert-Equal $result.initial.stage 'simulate' 'Stage'
    }

    Write-Host "$script:tests smoke tests passed."
}
finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) -and
        [IO.Path]::GetFileName($resolved) -match '^rtl-check-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
