# RTL 检查与 Codex 自动修复

本地运行 Verilog/SystemVerilog 编译、仿真和回归检查。Codex 可根据失败日志生成修复预览，通过回归和独立验收后可以写回。

需要 PowerShell 7.2+ 和 Icarus Verilog。使用自动修复时还需要已登录的 Codex CLI。ModelSim 可用作仿真器。硬件检查可接入 Vivado、Quartus、盘古 PDS、Gowin EDA、Lattice Radiant、Lattice Diamond、Libero SoC 和 Efinity。

## 在 Codex 里使用

下载 [RTL Check & Repair Skill 安装包](documents/rtl-check-repair.zip)，解压后将顶层文件夹 rtl-check-repair 放进 Codex 的用户 Skill 目录 ~/.agents/skills/。已有同名 Skill 时，更新原安装位置。打开 RTL 工程，在 Codex 输入框发送：

    $rtl-check-repair 用当前工程的 rtlcheck.json 跑编译和仿真。给我结果和报告路径。如果配置了波形验收，附上 GTKWave 打开命令和输入激励对照表。

这版包含测试台检出能力评测、Icarus 编译排查提示和 GTKWave 波形验收。安装包内附脚本、样例和使用指南。

## 从仓库运行

从仓库根目录检查计数器样例：

    pwsh -NoProfile -File ./rtl-check/rtl-check.ps1 check -Config ./rtl-check/examples/counter/rtlcheck.json

这个样例包含一个步长故障，可用来体验检查、修复预览和复检写回。验证波形导出时，可改用 rtl-check/examples/evaluation/counter/waveform-acceptance.json。

[配置、MCP 和测试说明](documents/RTL%20检查与%20Codex%20自动修复.md)
