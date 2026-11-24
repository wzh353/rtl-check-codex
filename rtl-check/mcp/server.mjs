import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { lstat, realpath, stat, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const checker = fileURLToPath(new URL("../rtl-check.ps1", import.meta.url));
const defaultWorkspace = fileURLToPath(new URL("../../", import.meta.url));
const { values } = parseArgs({
  options: { workspace: { type: "string" }, pwsh: { type: "string" } },
});
const workspace = await realpath(resolve(values.workspace ?? defaultWorkspace));
if (!(await stat(workspace)).isDirectory()) throw new Error("The MCP workspace must be a directory.");
const pwsh = values.pwsh ? resolve(values.pwsh) : "pwsh";

const pathValue = z.string().refine((value) => /\S/.test(value) && !value.includes("\0"), "Expected a file path");
const timeout = z.number().int().min(1).max(3600);
const sha256 = z.string().regex(/^[0-9A-Fa-f]{64}$/);
const commonInputs = {
  configPath: pathValue.describe("Project configuration JSON. Relative paths start at the configured workspace."),
  outDir: pathValue.optional().describe("Output directory in the workspace. Defaults to .rtlcheck beside the configuration."),
  timeoutSeconds: timeout.optional().describe("EDA time limit passed to rtl-check. Default: 15 seconds."),
  expectedInputSha256: sha256.optional().describe("Require the same project input snapshot SHA-256 before running EDA."),
};
const repairInputs = {
  ...commonInputs,
  repairFile: pathValue.optional().describe("One RTL source path relative to the configuration directory. Defaults to repairFiles in the configuration."),
  apply: z.boolean().default(false).describe("Explicitly authorize writing verified RTL files back to the project."),
  previewReport: pathValue.optional().describe("Saved repair summary.json in the workspace. Requires apply: true. Rechecks and applies the exact saved candidate without calling Codex."),
  maxAttempts: z.number().int().min(1).max(10).optional().describe("Maximum Codex repair rounds. Default: 3."),
  codexTimeoutSeconds: timeout.optional().describe("Time limit for each Codex call. Default: 240 seconds."),
  model: z.string().regex(/^[^\s\0-][^\r\n\0]*$/).optional().describe("Optional Codex model override."),
};

const nullableText = z.string().nullable();
const checkSummary = z.object({
  status: z.string(),
  stage: z.string(),
  engine: nullableText,
  hardwareEngine: nullableText,
  timing: z.object({
    status: z.string(),
    reason: nullableText,
    worstSetupSlackNs: z.number().nullable(),
    worstHoldSlackNs: z.number().nullable(),
  }).nullable(),
  failedRegression: nullableText,
  firstError: z.object({
    inputFile: nullableText,
    line: z.number().int().nullable(),
    code: z.union([z.string(), z.number()]).nullable(),
    message: nullableText,
    compilerHint: z.object({ category: z.string(), inspection: z.string() }).nullable(),
  }).nullable(),
  diagnostic: nullableText,
  waveformPath: nullableText,
});
const resultSchema = z.object({
  mode: z.enum(["check", "repair", "apply"]),
  status: z.enum(["passed", "repaired", "failed", "unresolved", "error"]),
  exitCode: z.number().int().nullable(),
  configPath: nullableText,
  runDirectory: nullableText,
  reportPath: nullableText,
  stage: nullableText,
  initial: checkSummary.nullable(),
  validationStatus: nullableText,
  waveformAcceptance: z.object({
    status: z.string(),
    case: z.string(),
    diagnostic: nullableText,
    sampleCount: z.number().int().nonnegative(),
    rtlSha256: sha256.nullable(),
    testInputSha256: sha256.nullable(),
    timescale: nullableText,
    timeUnit: nullableText,
    randomSeeds: z.object({ status: z.string(), values: z.record(z.string(), z.string()) }).nullable(),
    vcdPath: nullableText,
    gtkwPath: nullableText,
    stimulusPath: nullableText,
    samplingLogPath: nullableText,
    openCommand: nullableText,
  }).nullable(),
  stopReason: nullableText,
  attempts: z.array(z.object({
    number: z.number().int(),
    status: z.string(),
    codexInvoked: z.boolean(),
    check: checkSummary.nullable(),
    explanation: nullableText,
    error: nullableText,
  })),
  modelCalls: z.number().int(),
  candidateFiles: z.array(z.object({ path: z.string(), candidatePath: z.string(), sha256: sha256.nullable() })),
  applied: z.boolean(),
  previewReport: nullableText,
  inputSha256: sha256.nullable(),
  elapsedMs: z.number().int(),
  error: nullableText,
});
const exitCodes = new Map([["passed", 0], ["repaired", 0], ["failed", 1], ["unresolved", 1], ["error", 2]]);
const progressPrefix = "RTL_CHECK_PROGRESS ";
const progressMessages = new Map([
  ["prepare", "Preparing the RTL project"],
  ["baseline", "Running the baseline RTL check"],
  ["replay", "Rechecking the saved RTL preview"],
  ["regression", "Running a public regression"],
  ["pango", "Running Pango PDS hardware checks"],
  ["vivado", "Running AMD Vivado hardware checks"],
  ["gowin", "Running Gowin EDA hardware checks"],
  ["gowin-timing", "Checking Gowin post-route timing"],
  ["radiant", "Running Lattice Radiant hardware checks"],
  ["diamond", "Running Lattice Diamond hardware checks"],
  ["libero", "Running Microchip Libero SoC hardware checks"],
  ["efinity", "Running Efinix Efinity synthesis"],
  ["synthesis", "Running Quartus analysis and synthesis"],
  ["fit", "Running Quartus placement and routing"],
  ["timing", "Running TimeQuest timing analysis"],
  ["validation", "Running independent validation"],
  ["waveform-acceptance", "Exporting the verified waveform"],
  ["model", "Asking Codex for a repair"],
  ["candidate", "Checking a repair candidate"],
  ["publish", "Publishing verified RTL files"],
  ["finished", "RTL operation finished"],
]);

// SDK 1.32.2 ignores falsy cancellation IDs. Translate these two valid IDs inside the SDK only.
class RtlStdioTransport extends StdioServerTransport {
  #sdkIds = new Map([[0, randomUUID()], ["", randomUUID()]]);
  #wireIds = new Map([...this.#sdkIds].map(([wire, sdk]) => [sdk, wire]));

  async start() {
    const receive = this.onmessage;
    this.onmessage = (message, extra) => {
      const requestId = this.#sdkIds.get(message.id);
      if ("method" in message && requestId !== undefined) {
        message = { ...message, id: requestId };
      } else if (message.method === "notifications/cancelled") {
        const cancellationId = this.#sdkIds.get(message.params?.requestId);
        if (cancellationId !== undefined) message = { ...message, params: { ...message.params, requestId: cancellationId } };
      }
      receive?.(message, extra);
    };
    await super.start();
  }

  send(message, options) {
    const wireId = this.#wireIds.get(message.id);
    return super.send(wireId !== undefined && !("method" in message) ? { ...message, id: wireId } : message, options);
  }
}

function requireWorkspacePath(path, label) {
  const location = relative(workspace, path);
  if (isAbsolute(location) || location === ".." || location.startsWith(".." + sep)) {
    throw new Error(label + " must be inside the MCP workspace.");
  }
  return path;
}

async function projectFile(path, label) {
  const requested = requireWorkspacePath(resolve(workspace, path), label);
  requireWorkspacePath(await realpath(dirname(requested)), label);
  const actual = requireWorkspacePath(await realpath(requested), label);
  if (!(await stat(actual)).isFile()) throw new Error(label + " must name a file.");
  return requested;
}

async function outputDirectory(path) {
  const requested = requireWorkspacePath(resolve(workspace, path), "outDir");
  let ancestor = requested;
  for (;;) {
    const info = await lstat(ancestor).catch((error) => {
      if (error.code === "ENOENT") return null;
      throw error;
    });
    if (info) {
      const actual = requireWorkspacePath(await realpath(ancestor), "outDir");
      if (!(await stat(actual)).isDirectory()) throw new Error("outDir must name a directory.");
      return resolve(actual, relative(ancestor, requested));
    }
    // The existing workspace root was resolved during startup.
    if (ancestor === workspace) throw new Error("The MCP workspace is no longer available.");
    ancestor = dirname(ancestor);
  }
}

async function runChecker(args, signal, onProgress) {
  signal.throwIfAborted();
  const cancellationFile = join(tmpdir(), "rtl-mcp-cancel-" + randomUUID());
  const child = spawn(pwsh, args, {
    cwd: workspace,
    env: { ...process.env, RTL_CHECK_CANCEL_FILE: cancellationFile, RTL_CHECK_MCP_PROGRESS: onProgress ? "1" : "" },
    shell: false,
    windowsHide: true,
    detached: process.platform !== "win32",
    stdio: ["ignore", "pipe", "pipe"],
  });
  let cancellationRequested = false;
  const cancel = () => {
    // The worker stops the current child and keeps its report and cleanup path.
    try {
      writeFileSync(cancellationFile, "", { flag: "wx" });
      cancellationRequested = true;
    } catch (error) {
      console.error("Could not signal RTL cancellation: " + error.message);
    }
  };
  signal.addEventListener("abort", cancel, { once: true });
  const output = [];
  let bytes = 0;
  let stderr = "";
  const limit = 32 * 1024 * 1024;
  child.stdout.on("data", (chunk) => {
    bytes += chunk.length;
    if (bytes <= limit) output.push(chunk);
  });
  const lines = createInterface({ input: child.stderr, crlfDelay: Infinity });
  lines.on("line", (line) => {
    const phase = line.startsWith(progressPrefix) ? line.slice(progressPrefix.length) : null;
    if (onProgress && progressMessages.has(phase)) onProgress(phase);
    else stderr = (stderr + line + "\n").slice(-4096);
  });
  try {
    const exitCode = await new Promise((done, reject) => {
      child.once("error", (error) => reject(new Error("Could not start PowerShell: " + error.message)));
      child.once("close", done);
    });
    if (bytes > limit) {
      throw Object.assign(new Error("The RTL checker report exceeds 32 MiB. See the local output directory."), { exitCode });
    }
    let report;
    try {
      report = JSON.parse(Buffer.concat(output).toString("utf8").trim());
    } catch {
      if (stderr.trim()) console.error(stderr.trim());
      throw Object.assign(new Error("The RTL checker did not return JSON. See the server log."), { exitCode });
    }
    if (report?.schemaVersion !== 1 || !exitCodes.has(report.status) || exitCodes.get(report.status) !== exitCode) {
      throw Object.assign(new Error("The RTL checker report did not match its exit code."), { exitCode });
    }
    return { exitCode, report };
  } finally {
    lines.close();
    signal.removeEventListener("abort", cancel);
    if (cancellationRequested) {
      await unlink(cancellationFile).catch((error) => {
        if (error.code !== "ENOENT") console.error("Could not remove the RTL cancellation marker: " + error.message);
      });
    }
  }
}

function progressReporter({ _meta, signal, sendNotification }) {
  const progressToken = _meta?.progressToken;
  if (progressToken === undefined) return undefined;
  let progress = 0;
  return (phase) => {
    if (signal.aborted) return;
    sendNotification({
      method: "notifications/progress",
      params: { progressToken, progress: ++progress, message: progressMessages.get(phase) },
    }).catch((error) => {
      if (!signal.aborted) console.error("Could not send RTL progress: " + error.message);
    });
  };
}

function excerpt(text, limit = 1600) {
  if (typeof text !== "string") return null;
  return text.length > limit ? text.slice(0, limit) + " …" : text;
}

function summarizeCheck(check) {
  if (!check) return null;
  const error = check.firstError;
  const timing = check.timing;
  return {
    status: check.status,
    stage: check.stage,
    engine: check.engine ?? null,
    hardwareEngine: check.synthesis?.engine ?? null,
    timing: timing ? {
      status: timing.status,
      reason: timing.reason ?? null,
      worstSetupSlackNs: timing.worstSetupSlackNs ?? null,
      worstHoldSlackNs: timing.worstHoldSlackNs ?? null,
    } : null,
    failedRegression: check.failedRegression ?? null,
    firstError: error ? {
      inputFile: error.inputFile ?? null,
      line: error.line ?? null,
      code: error.code ?? null,
      message: excerpt(error.message),
      compilerHint: error.compilerHint ?? null,
    } : null,
    diagnostic: excerpt(check.diagnostic),
    waveformPath: check.waveform?.path ?? null,
  };
}

async function savedReport(runDirectory) {
  if (!runDirectory) return null;
  const reportPath = join(runDirectory, "summary.json");
  const info = await stat(reportPath).catch(() => null);
  return info?.isFile() ? reportPath : null;
}

function publicError(report, fallback) {
  if (!report?.error) return excerpt(fallback);
  if (report.validation?.status === "error") return "Independent validation could not complete. See the local report.";
  if (/^(Input snapshot digest mismatch|Candidate digest mismatch|Project inputs have changed|The RTL operation was cancelled)\b/.test(report.error)) {
    return excerpt(report.error);
  }
  return "The RTL checker reported a configuration, tool, or writeback error. Review the local report or CLI output.";
}

async function resultFor(mode, started, { report, exitCode, error, configPath } = {}) {
  const attempts = (report?.attempts ?? []).map((attempt) => ({
    number: attempt.number,
    status: attempt.status,
    codexInvoked: Boolean(attempt.codexInvoked || attempt.codex),
    check: summarizeCheck(attempt.check),
    explanation: excerpt(attempt.explanation),
    error: excerpt(attempt.error),
  }));
  const validationStatus = report?.validation?.status ?? null;
  const initial = summarizeCheck(report?.initial);
  const wave = report?.waveformAcceptance;
  const stage = validationStatus && validationStatus !== "passed"
    ? "validation"
    : attempts.findLast((attempt) => attempt.check)?.check.stage ?? initial?.stage ?? null;
  const reportPath = await savedReport(report?.runDirectory);
  const verifiedPreview = mode === "repair" && report?.status === "repaired" && !report.applied;
  const result = {
    mode,
    status: report?.status ?? "error",
    exitCode: exitCode ?? null,
    configPath: report?.configPath ?? configPath ?? null,
    runDirectory: report?.runDirectory ?? null,
    reportPath,
    stage,
    initial,
    validationStatus,
    waveformAcceptance: wave ? {
      status: wave.status,
      case: wave.case,
      diagnostic: excerpt(wave.diagnostic),
      sampleCount: wave.sampleCount,
      rtlSha256: wave.rtlSha256 ?? null,
      testInputSha256: wave.testInputSha256 ?? null,
      timescale: wave.timescale ?? null,
      timeUnit: wave.timeUnit ?? null,
      randomSeeds: wave.randomSeeds ?? null,
      vcdPath: wave.vcdPath ?? null,
      gtkwPath: wave.gtkwPath ?? null,
      stimulusPath: wave.stimulusPath ?? null,
      samplingLogPath: wave.samplingLogPath ?? null,
      openCommand: wave.openCommand ?? null,
    } : null,
    stopReason: report?.stopReason ?? null,
    attempts,
    modelCalls: attempts.filter((attempt) => attempt.codexInvoked).length,
    candidateFiles: (report?.candidateFiles ?? []).map((file) => ({
      path: file.path,
      candidatePath: file.candidatePath,
      sha256: file.sha256 ?? null,
    })),
    applied: report?.applied ?? false,
    previewReport: report?.previewReport ?? (verifiedPreview ? reportPath : null),
    inputSha256: report?.inputSha256 ?? null,
    elapsedMs: Math.round(performance.now() - started),
    error: publicError(report, error),
  };
  return {
    isError: result.status === "error",
    content: [{ type: "text", text: JSON.stringify(result) }],
    structuredContent: result,
  };
}

async function runTool(tool, inputs, extra) {
  const started = performance.now();
  const mode = inputs.previewReport ? "apply" : tool;
  const onProgress = progressReporter(extra);
  let configPath;
  let nativeExitCode;
  try {
    if (inputs.previewReport && !inputs.apply) throw new Error("previewReport requires apply: true.");
    if (inputs.previewReport && [inputs.maxAttempts, inputs.codexTimeoutSeconds, inputs.model].some((value) => value !== undefined)) {
      throw new Error("Omit model options when applying an existing preview.");
    }
    configPath = await projectFile(inputs.configPath, "configPath");
    const outDir = await outputDirectory(inputs.outDir ?? join(dirname(configPath), ".rtlcheck"));
    const args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", checker, mode, "-Config", configPath, "-OutDir", outDir, "-Json"];
    for (const [key, flag] of [["timeoutSeconds", "-TimeoutSeconds"], ["expectedInputSha256", "-ExpectedInputSha256"]]) {
      if (inputs[key] !== undefined) args.push(flag, String(inputs[key]));
    }
    if (inputs.repairFile) {
      const file = inputs.repairFile;
      args.push("-RepairFile", file.startsWith("-") ? "./" + file : file);
    }
    if (mode === "apply") {
      args.push("-PreviewReport", await projectFile(inputs.previewReport, "previewReport"));
    } else if (mode === "repair") {
      for (const [key, flag] of [["maxAttempts", "-MaxAttempts"], ["codexTimeoutSeconds", "-CodexTimeoutSeconds"], ["model", "-Model"]]) {
        if (inputs[key] !== undefined) args.push(flag, String(inputs[key]));
      }
      if (inputs.apply) args.push("-Apply");
    }
    const { exitCode, report } = await runChecker(args, extra.signal, onProgress);
    nativeExitCode = exitCode;
    if (report.mode !== mode) throw new Error("The RTL checker returned a report for a different mode.");
    return await resultFor(mode, started, { report, exitCode });
  } catch (error) {
    return await resultFor(mode, started, { error: error.message, configPath, exitCode: error.exitCode ?? nativeExitCode });
  } finally {
    onProgress?.("finished");
  }
}

const server = new McpServer({ name: "rtl-check", version: "1.0.0" });
server.registerTool("check", {
  title: "Check RTL",
  description: "Run the project's local RTL checks and return a compact result and report path. Does not modify RTL source files.",
  inputSchema: z.strictObject(commonInputs),
  outputSchema: resultSchema,
  annotations: { destructiveHint: false },
}, (inputs, extra) => runTool("check", inputs, extra));

server.registerTool("repair", {
  title: "Repair RTL",
  description: "Run the existing Codex repair and independent acceptance workflow. Preview is the default. Set apply to true only with explicit authorization to write RTL. To publish a saved preview without a new model call, include its previewReport.",
  inputSchema: z.strictObject(repairInputs),
  outputSchema: resultSchema,
  annotations: { destructiveHint: true },
}, (inputs, extra) => runTool("repair", inputs, extra));

await server.connect(new RtlStdioTransport());
process.stdin.once("end", () => {
  server.close().catch((error) => console.error(error.message));
});
