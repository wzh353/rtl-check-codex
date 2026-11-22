# RTL 检查与 Codex 自动修复

本地运行 Verilog/SystemVerilog 编译、仿真和回归检查。Codex 可根据失败日志生成修复预览，通过回归和独立验收后可以写回。

需要 PowerShell 7.2+ 和 Icarus Verilog。使用自动修复时还需要已登录的 Codex CLI。ModelSim 可用作仿真器。硬件检查可接入 Vivado、Quartus、盘古 PDS、Gowin EDA、Lattice Radiant、Lattice Diamond、Libero SoC 和 Efinity。

从仓库根目录检查计数器样例：

```powershell
pwsh -NoProfile -File ./rtl-check/rtl-check.ps1 check -Config ./rtl-check/examples/counter/rtlcheck.json
```

样例包含一个步长故障，可用来体验检查、修复预览和复检写回。

[使用说明、MCP 配置和测试命令](documents/RTL%20检查与%20Codex%20自动修复.md)
