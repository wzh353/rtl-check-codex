---
name: rtl-check-repair
description: Use when checking or repairing Verilog/SystemVerilog, measuring which RTL mutations a testbench detects, running FPGA synthesis or timing checks, or exporting a GTKWave acceptance trace. 用于本地 RTL 仿真、测试台漏检分析、Codex 修复与波形验收。
---

# RTL 检查与 Codex 修复

以本次运行的报告和测试证据为准。用户提供的 RTL、约束、测试台和板卡配置决定验收范围。

## 选工具和配置

- 使用与目标工程同一工作区的 `rtl-check/rtl-check.ps1`，或使用用户指定的版本。独立工程缺少工具时，用本 Skill 目录内的 `scripts/rtl-check/rtl-check.ps1`。
- 使用用户指定的项目配置。项目路径以配置目录为基准。只有确实需要创建配置时，才从真实 RTL 顶层、测试台和约束确定字段。取不到必要信息时，标明缺的输入。
- 从终端运行用 PowerShell 7.2+。默认仿真用 Icarus 的 `iverilog` / `vvp`。配置选择 ModelSim 或厂商工具时，使用符合该配置的已安装工具。MCP 已连接且能访问同一工程时，可用对应的 `check` / `repair` 工具。
- [项目指南](references/project-guide.md) 包含配置、样例和工具安装位置字段。内置示例从 Skill 的 `scripts/` 目录运行。检查其他工程时，从工程位置运行并分别传入工具及配置的绝对路径。

## 根据请求运行

| 请求 | 入口 |
| --- | --- |
| 查看已有报告或解释波形 | 读取指定的报告和产物 |
| 检查编译、功能、综合或时序 | `check` |
| 检查测试台能抓住哪些 RTL 故障 | `rtl-evaluate.ps1 -Mode testbench -Manifest`，对照正确设计和注入改动的副本 |
| 生成并验证修复候选 | `repair`，保留预览 |
| 写回指定的已验证候选 | `apply -PreviewReport`，复用预览的配置和修复范围 |
| 同一次执行中修复并写回 | 用户要求写回时使用 `repair -Apply` |

以下命令中的 `$tool`、`$config` 和 `$preview` 使用已经定位的路径。

```powershell
pwsh -NoProfile -File $tool check -Config $config -Json
pwsh -NoProfile -File $tool repair -Config $config -Json
pwsh -NoProfile -File $tool apply -Config $config -PreviewReport $preview -Json
```

- 指定产物目录时追加 `-OutDir`，使用用户给出的绝对路径或从工程位置解析相对路径。报告路径由本次返回的 `runDirectory` 确定。
- 配置有 `repairFiles` 时沿用其范围。用户指定单个目标或配置未声明修复范围时，使用 `-RepairFile` 指定获准的 RTL 源文件。正式测试台、独立验收和约束保留为修复输入。
- 从一次检查继续修复时，将它的 `inputSha256` 传给 `-ExpectedInputSha256`。对指定预览写回时，核对新报告的 `applied`、`previewReport` 和 `attempts`。CLI 中空 `attempts` 表明没有模型调用，MCP 对应 `modelCalls: 0`。输入变化后，对指定预览的写回以工具的拒绝结果为准。
- 退出码 `0` 对应通过或修复成功，`1` 对应设计失败或修复未解决，`2` 对应配置、工具或执行错误。没有可用的仿真或综合证据时，先定位配置或工具错误。只有编译结果的用例只能确认编译。
- 读取本次 `summary.json`。报告修复结果时使用通过的候选检查及 `validation.status`；`initial` 记录修复前的基线。回复给出结论、首个有效诊断或验收证据，以及报告路径。
- Icarus 报告 `firstError.compilerHint` 时，结合同一条原始错误、源文件和行号核对提示。测量测试台时读取 `cases[].detection`，报告哪个用例检出改动。`survived` 表示现有测试均通过，判断是否漏检需要能区分两个设计的输入或等价性证据。详见项目指南的「测量测试台能检出的故障」。

## 波形验收

只有 `waveformAcceptance.status` 为 `ready` 且 `vcdPath`、`gtkwPath` 和 `stimulusPath` 指向仍存在的文件时才交付它们。查看 `openCommand` 获取 GTKWave 打开命令。主流程结果和导出状态分别核对，回放错误查看 `waveformAcceptance.diagnostic` 及该次日志。

解释波形时，使用 `stimulus.md` 和同次采样日志里的驱动时刻、实际采样时刻和测试台位置。预期值按断言或参考模型的来源理解，保留 `X/Z` 和「未指定」。

诊断失败波形时，从首个失败的断言和采样时刻出发，在 `waveform` 的同次失败回放里，对照输出、驱动它的输入或寄存器，以及采样前的时钟边沿。

为项目新增波形验收配置时，读项目指南的「可选的 GTKWave 波形验收」。独立验收后的导出选择一个 Icarus 公开用例，并使用额外观察模块记录原测试台的检查事件。

## 按需查阅

- 厂商综合、板级和时序配置读项目指南的「选择 FPGA 开发工具」及对应厂商段落。区分布线完成、原生时序报告和时序限值通过。
- 批量检查和基准读「批量评测」或「用正确对照验证修复闭环」。使用 `rtl-batch.ps1` 或 `rtl-evaluate.ps1` 及现有清单。
- 配置新的 MCP 连接读「通过 MCP 调用」。将服务的 `--workspace` 指向目标工程所在的工作区。

