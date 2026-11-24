# RTL 检查与 Codex 自动修复

从项目根目录运行以下命令。工具使用 PowerShell 7.2+，默认调用 Icarus Verilog 的 `iverilog` 和 `vvp`，也可选择 ModelSim。自动修复还需要已登录的 Codex CLI，可用 `codex login status` 检查。

## 检查并修复样例

样例是一个同步 8 位计数器，故意将每次加一写成了加二。主测试台检查复位、使能、保持和溢出回绕。独立验收还确认复位只在时钟上升沿生效。

```powershell
$tool = './rtl-check/rtl-check.ps1'
$config = './rtl-check/examples/counter/rtlcheck.json'

# 编译并运行自检，打印首个失败周期及期望值、实际值。
pwsh -NoProfile -File $tool check -Config $config

# 让 Codex 提出修改并跑回归，保留可供审查的候选文件。
pwsh -NoProfile -File $tool repair -Config $config -RepairFile counter.sv

# 回归通过后，将候选文件写回指定 RTL。
pwsh -NoProfile -File $tool repair -Config $config -RepairFile counter.sv -Apply
```

样例第一次检查应报 `cycle=3 rst_n=1 en=1 expected=1 actual=2`。复制样例目录后执行带 `-Apply` 的命令，可以保留原始故障样例。

## 通过 MCP 调用

MCP 服务使用本地 stdio，暴露 `check` 和 `repair` 两项工具。两项都复用下文的项目 JSON、PowerShell 检查和本机 EDA 工具。修复仍使用本机已登录的 Codex CLI。服务需要 Node.js 20 或更新版本。

在目标工程目录启动 MCP 服务。将工具目录和工程路径填入下方命令。其他支持 stdio 的客户端也可用同一个 Node.js 服务入口。

首次连接时安装服务依赖。在目标工程所在目录运行下列命令，`$toolkitRoot` 指向工具目录。随后可为一次 Codex CLI 会话连接服务。 [Codex MCP 配置说明](https://developers.openai.com/codex/mcp)

```powershell
$toolkitRoot = (Resolve-Path ./rtl-check).Path # 工具在工程外时填写绝对路径
$projectRoot = (Get-Location).Path
$mcpDir = Join-Path $toolkitRoot 'mcp'
$npm = if ($IsWindows) { 'npm.cmd' } else { 'npm' }
& $npm ci --prefix $mcpDir
if ($LASTEXITCODE -ne 0) { throw 'MCP 依赖安装失败' }

$server = Join-Path $mcpDir 'server.mjs'
$mcpOptions = @(
    '-c', 'mcp_servers.rtl.command="node"',
    '-c', ('mcp_servers.rtl.args=' + (ConvertTo-Json -InputObject @($server, '--workspace', $projectRoot) -Compress)),
    '-c', 'mcp_servers.rtl.tool_timeout_sec=1800',
    '-c', 'mcp_servers.rtl.env_vars=["QUARTUS_ROOTDIR","MGLS_LICENSE_FILE","PANGO_LICENSE_FILE"]'
)
codex @mcpOptions
```

检查故障样例时调用 `check`。在其他工程中，把示例的 `configPath` 换成目标配置相对 `$projectRoot` 的路径。

```json
{"configPath":"rtl-check/examples/counter/rtlcheck.json"}
```

调用 `repair` 会生成并验收候选预览。样例只有一个要修的文件，参数里显式指定它。

```json
{"configPath":"rtl-check/examples/counter/rtlcheck.json","repairFile":"counter.sv"}
```

写回前，用副本测试并审查候选。把成功结果中的 `previewReport` 传给同一个工具，显式设 `apply: true`，并复用那次的 `configPath` 和修复范围。系统复检后写回同一份候选，该调用的模型调用数为零。也可以在一次 `repair` 调用中设 `apply: true`，让这次生成并验收的候选直接写回。

- 两项工具都接受 `outDir`、`timeoutSeconds` 和 `expectedInputSha256`。把 `check` 返回的 `inputSha256` 作为后续 `repair` 的 `expectedInputSha256`，输入变动时流程会在仿真和模型调用前停止。相对的配置、预览报告和输出路径以服务的工作区为基准，`repairFile` 相对配置目录。
- `repair` 可以设置 `maxAttempts`、`codexTimeoutSeconds` 和 `model`，这些参数用于生成新候选。支持 MCP 进度通知的客户端可查看准备、仿真回归、综合、独立验收和修复阶段。取消可停止正在运行的工具，并在输出目录保存终止报告。已进入文件替换的写回会完成事务。
- 结果包含 `status`、`stage`、`initial`、候选摘要、`modelCalls` 及本地 `reportPath`。`initial.engine` 是仿真器，`initial.hardwareEngine` 是已运行的硬件工具。执行时序检查后，`initial.timing` 提供结果、原因以及以 ns 计的最差 setup 和 hold 裕量。发现设计故障时返回标准结果 `status: "failed"`，工具执行错误时返回 `isError: true`。配置文件存在时，准备阶段的错误也有本地报告。独立验收只返回状态，完整细节留在本地报告。
- 已配置 GTKWave 波形验收时，`waveformAcceptance` 返回导出状态、输入摘要、采样数量、各产物路径和打开命令。

输入快照复制与多文件写回共用一把锁，避免一次检查读到两个版本的 RTL。复制完成后释放锁，各案例随后可并行运行 EDA。

## 接入自己的设计

把 `rtlcheck.json` 放在能覆盖所有输入的项目目录里。以下字段中的路径均相对配置文件所在目录。

```json
{
  "top": "fifo_tb",
  "sources": ["rtl/fifo.sv", "rtl/memory.sv"],
  "repairFiles": ["rtl/fifo.sv", "rtl/memory.sv"],
  "testbenches": ["sim/fifo_tb.sv"],
  "includeDirs": ["rtl/include"],
  "supportFiles": ["rtl/include/widths.svh", "sim/vectors.hex"],
  "defines": ["SIMULATION=1"],
  "specification": "fifo-spec.txt",
  "passMarker": "RTL_CHECK_PASS",
  "validation": {
    "top": "fifo_validation_tb",
    "testbenches": ["sim/fifo_validation_tb.sv"],
    "supportFiles": ["sim/validation_vectors.hex"],
    "passMarker": "VALIDATION_PASS"
  }
}
```

必填字段为 `top` 和 `sources`。

- **编译检查**省略 `testbenches`，将 `top` 设为设计顶层模块名。
- **功能检查**填写 `testbenches`，将 `top` 设为测试台模块名。工具保存编译和仿真日志。仿真通过要求测试流程正常结束、无断言错误，并且测试台打印完整的成功标记行。Icarus 编译开启 `-Wall`。
- **仿真输入**把 include 指令用到的头文件以及 `$readmemh` 等用到的数据文件写入 `supportFiles`。仿真的工作目录是配置目录结构的副本，文件的相对位置保持一致。
- **仿真专用源码**用 `simulationSources` 列出厂商行为模型等 `.v` 或 `.sv` 文件。所有仿真套件都会先编译这些文件。综合使用 `sources` 中的设计源码，Codex 的修改范围也从 `sources` 中选择。
- **自动修复**需要自检测试台。用 `repairFiles` 列出可修改的 UTF‑8 `.v` 或 `.sv` 源文件，执行 `repair -Config $config`。显式传入 `-RepairFile` 时，范围收窄为命令上指定的一个文件。`specification` 可给 Codex 补充接口与时序约定。
- **独立验收**用可选的 `validation` 指定最终验收测试台。它继承设计源文件和公共仿真设置，验收专用数据可放在 `validation.supportFiles`。验收测试台要与所有公开测试输入分开。

## 多套功能回归

在根配置加入 `regressions`，可以用多个测试顶层或同一测试台的不同配置，检查同一个 RTL 候选。

```json
"regressions": [
  {
    "id": "fifo-wrap",
    "top": "fifo_wrap_tb",
    "testbenches": ["sim/fifo_wrap_tb.sv"],
    "defines": ["TEST_DEPTH=16"]
  },
  {
    "id": "fifo-backpressure",
    "top": "fifo_backpressure_tb",
    "testbenches": ["sim/fifo_backpressure_tb.sv"],
    "supportFiles": ["sim/backpressure.hex"],
    "passMarker": "BACKPRESSURE_PASS"
  }
]
```

根配置先编译并运行主测试，再按顺序运行各套回归。所有回归通过后，才进入已配置的综合、板级和时序检查，最后进行独立验收。项目也可以用根配置做编译检查，再用回归测试台提供自检用例。

每套回归继承公共设计、仿真模型、头文件路径、宏和模拟器。可以追加自己的 `includeDirs` 和 `supportFiles`，用 `defines` 覆盖同名宏，并独立设置 `simulator`、`passMarker` 和 `waveform`。每套使用单独的运行目录，专用输入只随对应套件运行。所有套件与独立验收使用同一份候选源文件。

首个失败的回归会停止该轮检查。`failedRegression` 给出失败用例 ID，`regressionsPassed` 给出此前通过的用例数。Codex 会收到失败用例的诊断和相关测试台。候选若破坏较早通过的用例，后续修复会从此前保留的版本继续。

## 可选 ModelSim 仿真

主配置可指定 ModelSim，适合需要并发 SystemVerilog 断言的测试台。把示例中的 `binDirectory` 换成本机 `vsim`、`vlog` 与 `vlib` 所在的目录。已把 `vsim` 加入 `PATH` 时可省略该字段。

```json
"simulator": {
  "engine": "modelsim",
  "binDirectory": "C:/EDA/ModelSim/win64"
}
```

每次检查创建独立的编译库，并引用该安装的库映射。编译检查还会加载指定顶层，验证模块及实例能够展开。功能仿真同时核对 ModelSim 的断言诊断、退出状态、运行完成标记和测试台成功行。原生退出码为 0 时，`$fatal`、`$error` 和 `$stop` 仍能阻止通过。

公开回归和独立验收默认继承主测试的模拟器，各套可以用 `simulator` 选择自己的模拟器。结果中的 `engine` 记录该套测试使用的模拟器。ModelSim 使用原生的逐文件编译单元，工程共用宏可通过 `defines` 或显式包含的头文件提供。本机验证使用 ModelSim SE-64 10.7。

Windows 深层输出目录会使用临时短路径运行 ModelSim，避开旧版工具的工作库和中间文件路径限制。编译、仿真日志及 VCD 仍保留在原输出目录。

## 失败波形

在主配置、回归套件或 `validation` 里加 `waveform`，选择测试台层级下的信号。`maxEvents` 默认为 12，范围为 1 至 32。单套测试最多选择 16 个信号。

```json
{
  "waveform": {
    "signals": ["counter_tb.clk", "counter_tb.rst_n", "counter_tb.en", "counter_tb.dut.count"],
    "maxEvents": 12
  }
}
```

当 Icarus 或 ModelSim 报告带时间戳的仿真错误时，工具用同一份输入快照和候选修改回放，并生成 VCD。回放的错误内容、模块实例、时间戳和退出码都一致时，报告保留截至该时间戳的信号值及最近变化。ModelSim 的失败时间会换算为 VCD 刻度，逐位记录的总线会按声明顺序重组。同一刻度内的调度顺序以模拟器的原始诊断为准。

主测试的精简波形会提供给下一轮修复，独立验收的波形保留在本地。原始仿真决定功能结果。若回放异常、断言不同或达到 32 MiB 的抓取上限，查看 `waveform.status` 及回放日志。超过 128 位的信号摘要记录低 128 位，完整输出可在 VCD 中查看。

## 可选的 GTKWave 波形验收

从项目根目录运行计数器样例。它使用现有的公开测试台和独立验收测试台，并加上单独的只读观察模块。

```powershell
pwsh -NoProfile -File ./rtl-check/rtl-check.ps1 check -Config ./rtl-check/examples/evaluation/counter/waveform-acceptance.json
```

`waveformAcceptance` 默认选择主测试。设置 `regression` 可改为一个公开回归 ID。所选用例使用 Icarus 和非空的自检测试台。

```json
{
  "waveformAcceptance": {
    "observer": "counter_wave_observer.sv",
    "observerTop": "counter_wave_observer",
    "signals": ["counter_tb.clk", "counter_tb.rst_n", "counter_tb.en", "counter_tb.dut.count"],
    "expectedSource": "reference_model",
    "locations": {
      "step": { "file": "counter_tb.sv", "anchor": "if (count !== expected_count)" }
    }
  }
}
```

检查、修复预览或写回复检通过后，导出使用已验收的 RTL 快照、原测试台和原仿真参数。观察模块只在这次复跑中编译，记录的驱动和采样时刻使用 Icarus 的 `$simtime()`，刻度与 VCD 一致。`locations` 指向公开测试台中唯一匹配的断言行。计数器样例监听断言前更新的 `cycle`，用独立的 8 位参考模型计算预期值。

观察模块可按行输出以下记录。输入与实测字段用逗号分隔的 `信号名=二进制值`，信号名可用唯一的末级名称或完整层级。缺少预期值用 `-` 或省略对应项，`expectedSource` 可填 `reference_model` 或 `testbench`。

```text
RTL_WAVE_DRIVE|驱动刻度|输入值
RTL_WAVE_SAMPLE|驱动刻度|实际采样刻度|场景|断言ID|预期值|实测值
RTL_WAVE_SEED|种子名|实际种子
RTL_WAVE_SEED|none
```

使用随机种子时，记录测试台实际采用的值。确定性样例使用 `RTL_WAVE_SEED|none`。原测试台、独立验收和观察模块均作为只读输入。

`summary.json` 的 `waveformAcceptance` 记录最终 RTL 摘要、测试输入及参数摘要、观察模块摘要、VCD 时基、种子和导出状态。`ready` 表示原断言通过且产物证据齐全。按需运行 `openCommand`，GTKWave 会加载 VCD 和预选信号。用 `stimulus.md` 及同次回放的采样日志向 Codex 提供测试场景，表中保留 `X/Z` 和「未指定」。功能结果继续由原断言和独立验收决定。[GTKWave 打开方式](https://gtkwave.github.io/gtkwave/man/gtkwave.1.html)

## 选择 FPGA 开发工具

在项目 JSON 中设置 `synthesis.engine`。配置后，仿真和公开回归通过的版本还要接受所选工具的综合检查。可定位到 RTL 的综合错误会用于 Codex 修复。器件配置、许可证或无法确认结果等工具错误会结束当前检查。候选复检和写回沿用同一个工具，约束随源码一同固定在输入快照中。

下表中的器件用于展示配置格式。实际工程使用板卡对应的器件、封装和速度等级。

| FPGA 厂商 | 开发软件 | `synthesis.engine` | 器件配置示例 | 可选约束与实现 |
| --- | --- | --- | --- | --- |
| AMD / Xilinx | Vivado | `vivado` | `device: "xc7a35tcpg236-1"` | XDC，支持布局布线及裕量报告。 [Vivado Tcl](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/synth_design) |
| 高云 | Gowin EDA | `gowin` | `device: "GW1NR-LV9QN88PC6/I5"`，`deviceVariant: "GW1NR-9C"` | CST、SDC，支持布局布线和布线后时序核验。 |
| Lattice | Radiant | `radiant` | `device: "LIFCL-40-8BG400C"`，`performance: "8_High-Performance_1.0V"` | PDC、SDC、FDC，支持布局布线。 [Radiant Tcl](https://www.latticesemi.com/api/document/download?id=55284) |
| Lattice | Diamond | `diamond` | `device: "LCMXO2-1200HC-4TG100C"` | LPF、SDC、FDC，支持布局布线。 [Diamond Tcl](https://www.latticesemi.com/api/document/download?id=54428#page=2656) |
| Microchip | Libero SoC | `libero` | `family: "PolarFire"`，`device: "MPF100T"`，`package: "FCVG484"`，`speed: "-1"` | SDC，支持布局布线。 [Libero Tcl](https://www.microchip.com/content/dam/mchp/documents/FPGA/swdocs/libero/libero_soc_tcl_cmd_ref_ug_2025_1.pdf) |
| Efinix | Efinity | `efinity` | `family: "Titanium"`，`device: "Ti60F225"`，`timingModel: "C4"` | 综合映射，工程使用 2026.1 的 XML 格式。 [Efinity 命令行](https://www.efinixinc.com/docs/efinity-command-line-v1.1.pdf) |
| Altera / Intel FPGA | Quartus | `quartus`（默认） | `family: "Cyclone IV E"`，`device: "EP4CE6E22C8"` | 综合、布局布线、板级引脚、TimeQuest 时序。 |
| 盘古 | Pango PDS | `pango` | 见下方盘古配置。 | 综合、布局布线、板级引脚和布线后时序。 |

### 配置示例

把下面的 `synthesis` 配置加入项目 JSON，将程序路径和约束文件换成工程实际位置。

```json
{
  "synthesis": {
    "engine": "vivado",
    "top": "counter",
    "device": "xc7a35tcpg236-1",
    "executable": "C:/EDA/Vivado/bin/vivado.bat",
    "constraintFiles": ["counter.xdc"],
    "implementation": true
  }
}
```

- `synthesis.top` 是硬件顶层模块。`constraintFiles` 相对配置目录。`implementation: true` 追加布局布线。Vivado 的裕量详见 `timing-summary.rpt`。Gowin、Quartus 和 PDS 可设置布线后时序限值。
- `executable` 可指定程序的绝对路径。默认在 `PATH` 查找 `vivado`、`gw_sh`、`radiantc`、`diamondc`、`libero` 或 `efx_run`。Windows 的 Radiant 和 Diamond 可分别指定各自安装目录中的 `bin/nt64/pnmainc.exe`。Libero 可指定 `Designer/bin/libero.exe`。Lattice 的 Verilog 和 SystemVerilog 综合使用随软件安装的 Synplify Pro。
- 公共的 `sources`、`includeDirs` 和 `supportFiles` 用于生成独立硬件工程。仿真模型、测试台和独立验收测试台分别留在对应的仿真阶段。Gowin 和 Efinity 的硬件宏可在 RTL 引用的头文件中声明。其他新增工具可读取 `synthesis.defines`。
- Efinity 使用 `efx_run --flow map`。Windows 会加载安装目录中与启动程序配套的 `bin/setup.bat`。本地 JSON 的 `initial.synthesis.artifactDirectory` 保存生成的工程、日志相关产物和工具报告。

已将 Gowin 的器件与检查流程配置到 [计数器样例](../rtl-check/examples/evaluation/counter/gowin.json)。将 `gw_sh` 所在目录加入 `PATH`，然后从项目根目录运行以下命令。

```powershell
pwsh -NoProfile -File ./rtl-check/rtl-check.ps1 check -Config ./rtl-check/examples/evaluation/counter/gowin.json
```

本机使用 Gowin EDA 1.9.11.03 Education 验证了综合、布局布线和 RTL 错误定位。Vivado、Radiant、Diamond、Libero 和 Efinity 的接入流程用模拟启动器验证，原生工具执行仍需相应安装和许可。

### Gowin 布线后时序核验

在 `synthesis.constraintFiles` 中列出实际使用的 SDC，再用 `synthesis.timing.clocks` 声明要核验的时钟名和周期。计数器样例使用 `sys_clk`，周期为 20 ns。

```json
{
  "constraintFiles": ["gowin.sdc"],
  "timing": {
    "clocks": { "sys_clk": 20 },
    "minSetupSlackNs": 0,
    "minHoldSlackNs": 0
  }
}
```

`timing` 会开启布局布线和原生文本时序报告。检查器核对工具记录的 SDC、实际时钟周期和路径证据。列出的每个时钟都需要在 Gowin 报告的路径表中有 setup 和 hold 证据。裕量低于门槛或存在违反时序的端点会在 `timing` 阶段判失败。时钟配置不符或报告缺失会结束检查，并保留工具诊断。

完整报告的 `initial.timing` 包含原生 `.tr` 路径、实际时钟周期、违反端点数和最差路径。真实裕量不足时，最差路径会进入后续 Codex 修复上下文。[高云时序报告说明](https://www.gowinsemi.com/upload/database_doc/1/document/5bfcfcab42d1c.pdf)

## 可选 Quartus 综合

以下配置以 Cyclone IV E 的测试器件为例。将设计顶层、器件系列和型号换成项目实际目标。

```json
{
  "synthesis": {
    "top": "counter",
    "family": "Cyclone IV E",
    "device": "EP4CE6E22C8",
    "failOnWarnings": [13410]
  }
}
```

工具从 `PATH` 或 `QUARTUS_ROOTDIR` 查找 `quartus_map`。也可在 `synthesis.executable` 指定绝对路径或相对于配置目录的路径。工具用 `sources`、`includeDirs` 和 `synthesis.defines` 在独立目录生成 QSF，并运行 Quartus Analysis & Synthesis。顶层的 `defines` 用于仿真。报告保留 QSF、原始日志、告警和可解析的综合逻辑单元数。`failOnWarnings` 中列出的告警也作为失败处理，例如本机 Quartus II 报告某个输出引脚恒为常量时使用的 `13410`。

Windows 的深层输出目录会为 Quartus 创建临时短路径。综合、布局布线和时序分析共享该路径，报告和数据库保存在请求的运行目录。

配置后，主测试通过的版本还须通过综合，才会进入独立验收和写回。综合错误及阻断告警会作为修复反馈。

本机验证使用 Quartus II 13.0.1 Web Edition。自动生成的 QSF 接收 Verilog 和 SystemVerilog 源文件，以及通过配置提供的头文件搜索路径。

## 可选板级引脚核对

在 `synthesis` 中加入 `board`，引用板卡工程的 QSF 或引脚分配片段。QSF 里的器件系列和型号如有声明，必须与 `synthesis.family` 和 `synthesis.device` 一致。

```json
"board": {
  "qsf": "board/board.qsf",
  "requireAllPins": true
}
```

工具读取逐行声明的引脚位置、全局和按端口指定的 I/O 标准，以及支持的配置脚复用、未用引脚、测量边沿、温度和种子设置。带 Tcl 控制流的项目可先用 Quartus 导出引脚分配。设计源码、仿真模型和 SDC 继续由各自的配置字段指定。QSF 与其他输入共同做快照，原设计和候选使用同一份板级分配。

Fitter 通过后，工具把引脚总数与详细端口表交叉核对，再逐项核对物理位置、分配来源和实际 I/O 标准。默认要求每个物理端口都有明确的位置和 I/O 标准。支持某些引脚由 Fitter 分配的项目可以将 `requireAllPins` 设为 `false`，报告会显示已核对数量和覆盖状态。启用 `timing` 时，板级检查通过后才运行 TimeQuest。

查看 `fit.board` 中的通过状态、实际端口表和差异，`fit.pinReportPath` 指向 Quartus 原始引脚报告。`complete` 表示引脚位置与 I/O 标准的覆盖情况，`unusedQsfSettings` 列出导入范围之外的设置名。板级差异会交给 Codex，写回前会复核原始 QSF。实物电压、接线和电气行为需要在板上验收。

## 可选布局布线与 TimeQuest

在已有的 `synthesis` 对象内加入下方的 `timing` 配置。SDC 路径相对于配置文件所在目录，本例要求 TimeQuest 实际分析名为 `clk`、周期 20 ns 的时钟。

```json
"timing": {
  "sdcFiles": ["constraints/top.sdc"],
  "clocks": { "clk": 20 },
  "minSetupSlackNs": 0,
  "minHoldSlackNs": 0,
  "requireFullyConstrained": true,
  "maxLogicElements": 200
}
```

工具从 `quartus_map` 所在目录找到 `quartus_fit` 和 `quartus_sta`。综合通过后按顺序运行两者。每个声明的时钟都需要在报告中找到相符的名称、周期，以及各工作角的 setup 和 hold 结果。setup 和 hold 的最小裕量分别默认为 0 ns，TimeQuest 报告的其他时序检查也须有非负裕量。默认还要求未约束路径检查通过。有意只验证已约束路径时，可显式设置 `requireFullyConstrained` 为 `false`，报告仍会记录覆盖状态。`maxLogicElements` 可省略，启用后以 Fitter 实际报告的逻辑单元数判定。`failOnWarnings` 也适用于这两个阶段，例如可将 TimeQuest 跳过非 SDC 命令的 `332145` 告警设为阻断项。

报告中的 `fit` 保留资源用量和 Fitter 日志，`timing` 保留实际读取的 SDC、时钟、约束覆盖、各工作角的裕量、关键路径起止节点和原始 TimeQuest 报告。工具交叉核对时序摘要和详细报告，将输出统一为三位小数的纳秒。资源、时钟和裕量违例会提供给 Codex。SDC 与其他输入一起做快照，修复只能改配置指定的 RTL，写回前会复核约束文件。

这组检查使用生成的 QSF 和指定的器件。需要固定物理引脚及 I/O 标准时，配置 `synthesis.board`。文本报告解析已在 Quartus II 13.0.1 Web Edition 验证。

测试台在发现错误时调用 `$fatal(1, ...)`。所有断言通过后打印成功标记，再结束仿真。默认成功标记是 `RTL_CHECK_PASS`，已有的自检测试台可用 `passMarker` 配置它自己的完整成功行。

```systemverilog
if (actual !== expected)
    $fatal(1, "cycle=%0d expected=%0h actual=%0h", cycle, expected, actual);

// 全部检查完成后
$display("RTL_CHECK_PASS");
$finish;
```

## 可选盘古 PDS 检查

将 PDS 安装目录下的 `bin` 加入当前会话的 PATH，或在 `synthesis.executable` 中指定 `pds_shell` 的完整路径。用 `synthesis.engine` 选择 `pango`。此前的 Quartus 配置继续使用默认引擎。

```json
{
  "engine": "pango",
  "top": "mes50hp_blink",
  "family": "Logos",
  "device": "PGL50H",
  "package": "FBG484",
  "speedGrade": "-6",
  "fdc": "mes50hp.fdc",
  "board": { "requireAllPins": true },
  "timing": { "clocks": { "board_clk": 20 }, "minSetupSlackNs": 0, "minHoldSlackNs": 0 }
}
```

上面是 `synthesis` 对象。工具用设计源文件和固定约束副本生成 PDS 工程，使用 ADS 综合。配置 `board` 或 `timing` 后还会执行器件映射和布局布线，两者都需要 `fdc`。综合专用宏可在设计包含的头文件中定义，并将该头文件列入 `supportFiles`。可用 `synthesis.failOnWarnings` 指定要阻断的 PDS 告警编号，例如 `["ConstraintEditor-4019"]`。

- `board` 核对布局布线报告中的端口、引脚、I/O 标准和 VCCIO。FDC 中每个受查端口须用字面量的 `PAP_IO_LOC`、`PAP_IO_STANDARD` 和 `PAP_IO_VCCIO` 约束。默认要求每个实际端口都有相应约束。可以显式设 `requireAllPins: false`，让工具只比较已列出的端口。
- `timing` 从 PDS 的布线后时序报告核对时钟名称、周期、实际时钟负载和来源，以及快、慢角的 setup 和 hold 余量。周期和余量单位为 ns，两个余量门槛默认均为 0。验收范围是报告中受约束的时序路径。PDS 的原生告警继续保存在报告中。
- MES50HP 样例使用 50 MHz 时钟 `P20`、KEY1 `K18` 和 LED1 `B2`。本机验证使用 PDS 2022.2-SP6.4。使用手册对应板型的 FDC 接入其他设计。

```powershell
$pangoCases = './rtl-check/examples/evaluation/pango.json'
pwsh -NoProfile -File ./rtl-check/rtl-evaluate.ps1 -Manifest $pangoCases -Mode check
```

该验收同时运行正确样例和多出无约束端口的版本。故障版本预期通过仿真和原生布线，然后在板级检查失败。PDS 的同次运行共享数据库，超时上限为所请求的原生动作数乘以 `-TimeoutSeconds`。

## 修复如何执行

1. 工具复制配置所列输入，按顺序执行主测试、公开回归和已配置的硬件检查。
2. 若基线失败，工具将诊断与副本里的 RTL、规格、测试台文本交给只读模式的 `codex exec`。当 Icarus 给出项目源码中的文件和行号时，提示会补上该行附近的代码，包含行号位置。Codex 返回带文件路径的精确文本替换。
3. 工具在候选副本应用整组修改，用与基线相同的检查顺序复测，并将新的诊断用于下一轮。有任一编辑越出修复范围或匹配失败时，整组提案被拒绝。重复候选跳过 EDA 检查，Codex 明确返回空编辑列表时停止。
4. 所有主流程检查通过后，工具运行配置中指定的独立验收。其测试台与失败详情留在本地报告。验收失败时结束本次修复，供人工查看失败用例。
5. 所有已配置的测试通过后，报告给出这一组候选文件的位置。使用 `-Apply` 时，工具检查源文件、规格、约束和所有测试输入与基线一致，再写回修改过的源文件。捕获到中途写回失败时，工具尝试回滚已替换的文件，恢复失败会在报告里给出原文件备份路径。

`check`、`repair` 和 `apply` 都会在所有主流程检查通过后运行已配置的独立验收。

如果新候选退回到先前已经通过的阶段，工具会保留该候选与失败日志，并从上一版继续。例如原本已经进入综合，新候选却在仿真阶段失败。报告的 `baseRound` 表示本轮改的是哪一版，`0` 指原始基线。被淘汰的候选标为 `regressed`。

`-MaxAttempts` 默认为 3，`-TimeoutSeconds` 为每个 EDA 子进程的超时，默认 15 秒。`-CodexTimeoutSeconds` 默认 240 秒。可用 `-Model` 指定 Codex 模型。修复调用使用 Codex CLI 自带的默认配置与现有登录。当输入较大时，工具会给文本加截断标记并优先提供修复目标、规格和测试台。

多文件写回逐文件替换。遇到强制终止或系统重启，可用运行目录下的 `baseline/` 对照恢复。

## 写回已通过的预览

```powershell
pwsh -NoProfile -File ./rtl-check/rtl-check.ps1 apply -Config $config -PreviewReport $previewReport
```

`$config` 指向预览时使用的配置，`$previewReport` 指向预览运行目录中的 `summary.json`。预览时指定了 `-RepairFile` 的项目，写回时使用相同参数。工具检查候选文件和项目输入的 SHA-256 摘要，使用原来的检查配置复检候选，通过后写回。该过程的模型调用数为零。项目输入或候选内容变动会阻止写回。旧版报告可重新生成预览以补齐摘要。

## 输出和退出码

每次运行在配置目录下的 `.rtlcheck/` 中保存一个独立记录。可用 `-OutDir` 指定输出根目录。

- `summary.json` 记录基线、修复轮次和独立验收的结果及日志路径。`firstError` 保留工具首条可识别错误，以及可解析的文件和行号。`stopReason` 会注明独立验收失败、Codex 返回空编辑列表或已用尽尝试次数。
- `candidateFiles` 列出通过全部已配置测试的修改文件、候选路径和 SHA-256 摘要。单文件结果也可从 `candidatePath` 读取。`apply` 的报告用 `previewReport` 关联原预览，并在 `initial` 记录对候选的复检。
- `00-initial/` 中是基线编译与仿真的 stdout、stderr。`01-repair/` 等目录另含 Codex 日志、`proposal.json` 和候选文件。
- 各轮的 `regressions/` 保存已运行的公开回归日志。配置回归或独立验收时，修复轮次的 `context/` 保存提供给 Codex 的公开输入和配置副本。完整配置与验收专用设置供检查流程使用。
- `validation/` 保存独立验收的编译和仿真日志。
- 每阶段的 `waveform/` 和 `synthesis/` 保存已启用的回放、综合、布局布线及静态时序报告。
- `baseline/` 保存本次运行的输入副本，可用于重现或恢复原始 RTL。

`-Json` 将同一份 JSON 打印到 stdout，便于 Codex 或脚本消费。退出码 `0` 表示检查通过或候选通过回归，`1` 表示检查失败或修复用尽轮次，`2` 表示配置、工具调用或写回失败。JSON 的 `applied` 表示原文件是否写回。

使用厂商 IP 时，RTL 功能仿真需要所选模拟器可读的模型，综合需要目标工具可读的设计源文件。

## 批量评测

把案例写入一个清单。`config` 相对于清单所在目录，`id` 用于在报告中定位案例。已有单文件项目可在案例上填写 `repairFile`，也可在各项目配置的 `repairFiles` 中维护修复范围。

```json
{
  "cases": [
    {"id": "counter", "config": "counter/rtlcheck.json", "repairFile": "counter.sv"},
    {"id": "fifo", "config": "fifo/rtlcheck.json"}
  ]
}
```

```powershell
pwsh -NoProfile -File ./rtl-check/rtl-batch.ps1 -Manifest ./cases.json
pwsh -NoProfile -File ./rtl-check/rtl-batch.ps1 -Manifest ./cases.json -Parallelism 3
pwsh -NoProfile -File ./rtl-check/rtl-batch.ps1 -Manifest ./cases.json -Mode repair -MaxAttempts 3 -Json
```

默认模式只运行检查。`-Mode repair` 在每个案例的同一份输入快照上记录基线和修复结果，并保存通过测试的候选供审查。报告目录默认为清单旁的 `.rtlcheck-batch/`，也可通过 `-OutDir` 指定。

`check` 可用 `-Parallelism` 同时检查不同工程，范围为 1 至 8，默认为 1。各案例使用独立运行目录，结果按清单顺序汇总。`repair` 按清单顺序调用 Codex。

汇总报告统计基线有结论的案例数、基线通过数、最终通过数、成功修复数、修复轮次、模型调用次数和耗时。模型调用次数按工具尝试执行 Codex 的次数计。每个案例附带详细报告及日志路径，`baselineStage` 和 `baselineFailedRegression` 记录基线到达的阶段和失败的公开回归。所有已配置的检查共同决定是否通过。单个案例的工具错误计入 `errors`，其余案例继续执行。

所有案例通过时退出码为 `0`。有未通过的案例时为 `1`。清单、配置或工具错误优先返回 `2`。

## 用正确对照验证修复闭环

本地验收集保留每个案例的正确设计，并按清单生成故障副本。`portable.json` 使用 Icarus。`full.json` 还覆盖 ModelSim、Quartus 综合、引脚分配和 TimeQuest。完整验收集需要可用的 `vsim`、`quartus_map`、`quartus_fit` 和 `quartus_sta`。本机硬件用例使用 Cyclone IV E 和 Quartus II 13.0.1。

```powershell
$cases = './rtl-check/examples/evaluation/full.json'
pwsh -NoProfile -File ./rtl-check/rtl-evaluate.ps1 -Manifest $cases -Mode check -Parallelism 3 -OutDir ./tmp/rtl-eval
pwsh -NoProfile -File ./rtl-check/rtl-evaluate.ps1 -Manifest $cases -Mode repair -MaxAttempts 3 -OutDir ./tmp/rtl-eval
```

默认模式是 `check`，只校准。每个正确版本必须通过，注入的故障必须在指定阶段被检出。每个检查进程先校验输入快照的 SHA-256 摘要，再运行 EDA。任一对照或故障偏离预期，本次测量会在模型调用前停止。

`-Parallelism` 设置校准阶段的并行度。随后进入修复时，模型调用仍按案例逐个执行。

`repair` 先完成全部校准，再对相同的故障输入执行正常预览修复。只有通过原有检查并留下候选文件的用例才计为修复成功。独立验收单独发现的故障用于验证验收保护，预期结果是拒绝候选且模型调用数为零。报告分别统计修复成功数、验收保护通过数、修复轮次和模型调用尝试数。这组可读的本地样例用于测量指定工具链上的修复和验收效果。

每个案例的 `config` 指向清单目录内的正确项目。`mutations` 用 `path`、`before`、`after` 指定设计源码的精确替换。`failure.stage` 指定应拦截故障的阶段，还可用 `regression`、`reason`、`code` 或 `messageContains` 核对具体诊断。修复模式使用正确项目配置的 `repairFiles` 授权范围。结果保存到运行目录的 `summary.json`，其中关联了所有底层报告和快照。

## 测量测试台能检出的故障

`testbench` 模式在隔离副本里分别运行正确设计和改动后的设计，使用项目配置的原测试台、回归和独立验收。清单只需指定 `id`、`config` 和 `mutations`。工具按实际执行结果记录首个拦截环节，模型调用数为零。[计数器测量清单](../rtl-check/examples/evaluation/testbench-audit.json)

```powershell
pwsh -NoProfile -File ./rtl-check/rtl-evaluate.ps1 -Mode testbench -Manifest ./rtl-check/examples/evaluation/testbench-audit.json -Parallelism 3 -OutDir ./tmp/rtl-testbench
```

报告中 `detectionCounts` 按案例计数。每项的 `detection` 记录结果、测试套件、阶段和可定位的文件行号，`fault.reportPath` 指向底层仿真报告。

| 结果 | 实际观察 |
| --- | --- |
| `public_detected` | 主测试台或具名公开回归在仿真中报错，能定位到声明的测试台文件、行号和仿真时刻 |
| `validation_only` | 公开检查通过，独立验收测试台在仿真中报错 |
| `survived` | 改动通过了配置的全部检查，且至少一套自检仿真实际运行。需用区分性输入或等价性验证进一步判读 |
| `compile_rejected` / `hardware_rejected` | 编译或展开诊断、综合、布局布线或时序检查拦下了改动 |
| `inconclusive` | 对照失败、输入快照不符、超时、只有编译证据，或仿真失败无法定位到声明的测试台。`reason` 记录原因 |

退出码 `0` 和状态 `completed` 表示本次测量完成，其中可以包含 `survived`。存在无法判定的案例时退出码为 `1`，配置或工具出错时为 `2`。

计数器清单用两组测试检查同一处改动。它让 `count` 到达 `127` 后，即使 `en=0` 也会在下一拍继续加一。原有测试通过。增加一个公开回归，在 `127` 时撤销使能，正确设计会保持 `127`，改动版会输出 `128`。这个输入能证实原测试在该场景漏检。[额外的公开回归](../rtl-check/examples/evaluation/counter/counter_hold_tb.sv)

### 这些做法的来源

- **MCY** 在位计数器示例中结合测试台和等价性检查判别变异。这里采用其用改动挑战测试台的思路，按本地清单列出实际检测结果。项目未运行等价性证明时，报告保留 `survived`，不据此计算功能覆盖率。[MCY 位计数器配置](https://github.com/YosysHQ/mcy/blob/5a2cad0cbefceb7f23051c08348bd23128fd1046/examples/bitcnt/config.mcy)
- **VerilogEval** 对典型 Icarus 错误分类，**RTLFixer** 将编译日志和对应排查建议交给模型，再运行工具检查候选。这里用本地规则匹配首条编译诊断中的语法、模块、命名端口、名称绑定和头文件错误，在报告和修复上下文中保留原文并附上排查方向。JSON 和 MCP 的字段为 `firstError.compilerHint`。[VerilogEval 错误分类](https://github.com/NVlabs/verilog-eval/blob/c498220d0a52248f8e3fdffe279075215bde2da6/count_failures.py) · [RTLFixer 修复流程](https://github.com/NVlabs/RTLFixer/blob/24ceebd9176d59bf302e935a800fcb46a10c634c/src/task/oneshot_fix_compile.py)
- **VerilogCoder** 围绕不匹配输出选择信号和一段波形时间窗。Skill 借鉴这个排查顺序，从首次失败的断言回看上一拍的数据、使能和复位。当前工具使用配置里选定的信号及其 VCD 时间刻度。[VerilogCoder 波形分析](https://github.com/NVlabs/VerilogCoder/blob/8b13108869f276c7b644dd88beabcb401a5cfa92/hardware_agent/examples/VerilogCoder/vcd_waveform_analyzer.py)

## 运行本地回归

```powershell
pwsh -NoProfile -File ./rtl-check/tests/smoke.ps1
pwsh -NoProfile -File ./rtl-check/tests/repair.ps1
pwsh -NoProfile -File ./rtl-check/tests/regressions.ps1
pwsh -NoProfile -File ./rtl-check/tests/batch.ps1
pwsh -NoProfile -File ./rtl-check/tests/evaluation.ps1
pwsh -NoProfile -File ./rtl-check/tests/waveform.ps1
pwsh -NoProfile -File ./rtl-check/tests/waveform-acceptance.ps1
pwsh -NoProfile -File ./rtl-check/tests/modelsim.ps1
pwsh -NoProfile -File ./rtl-check/tests/synthesis.ps1
pwsh -NoProfile -File ./rtl-check/tests/timing.ps1
pwsh -NoProfile -File ./rtl-check/tests/board.ps1
pwsh -NoProfile -File ./rtl-check/tests/pango.ps1
pwsh -NoProfile -File ./rtl-check/tests/vendors.ps1
pwsh -NoProfile -File ./rtl-check/tests/gowin-timing.ps1
```

ModelSim 回归可用 `-ModelSimBin` 指定程序目录，混合模拟器用例也需要 Icarus。Quartus 回归需要本机支持 Cyclone IV E 的 `quartus_map`。板级和时序回归还需同目录的 `quartus_fit` 和 `quartus_sta`。未找到相应工具时会跳过对应回归，也可用 `-QuartusMap` 指定映射程序。

Pango 回归使用 PATH 中的 `pds_shell`，也可用 `-PdsShell` 指定路径。

厂商适配回归可用 `-GowinShell` 指定 `gw_sh`，追加真实综合、布局布线和错误定位检查。

Gowin 时序回归使用 `PATH` 中的 `gw_sh`，也可用 `-GowinShell` 指定。用例包含 20 ns 通过、0.5 ns 的 setup 失败、保持时间门槛及错误时钟。
