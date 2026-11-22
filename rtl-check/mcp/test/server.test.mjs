import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { setTimeout as pause } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { LATEST_PROTOCOL_VERSION } from "@modelcontextprotocol/sdk/types.js";

const server = fileURLToPath(new URL("../server.mjs", import.meta.url));
const fixture = fileURLToPath(new URL("../../examples/counter", import.meta.url));

async function waitFor(read, label) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const result = await read().catch((error) => {
      if (error.code === "ENOENT") return null;
      throw error;
    });
    if (result) return result;
    await pause(50);
  }
  throw new Error("Timed out waiting for " + label);
}

test("local RTL MCP over stdio", async (t) => {
  const temp = await realpath(tmpdir());
  const workspace = await mkdtemp(join(temp, "rtl-mcp-test-"));
  const client = new Client({ name: "rtl-mcp-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [server, "--workspace", workspace],
    env: process.env,
    stderr: "pipe",
  });
  t.after(async () => {
    await client.close();
    const resolved = await realpath(workspace);
    assert.equal(dirname(resolved), temp);
    assert.match(basename(resolved), /^rtl-mcp-test-[a-zA-Z0-9]+$/);
    await rm(resolved, { recursive: true, maxRetries: 10, retryDelay: 150 });
  });

  const broken = "故障 project";
  const healthy = "healthy project";
  const holdout = "holdout project";
  const configuration = (project) => project + "/rtlcheck.json";
  for (const name of [broken, healthy, holdout]) {
    await cp(fixture, join(workspace, name), { recursive: true });
  }
  const original = await readFile(join(workspace, broken, "counter.sv"), "utf8");
  const correct = original.replace("count + 8'd2", "count + 8'd1");
  assert.notEqual(original, correct);
  await writeFile(join(workspace, healthy, "counter.sv"), correct);
  await writeFile(
    join(workspace, holdout, "counter.sv"),
    correct.replace("posedge clk)", "posedge clk or negedge rst_n)"),
  );
  const call = (name, args) => client.callTool({ name, arguments: args });
  await client.connect(transport);

  await t.test("discovers both tools with structured result schemas", async () => {
    const { tools } = await client.listTools();
    assert.deepEqual(tools.map((tool) => tool.name).sort(), ["check", "repair"]);
    for (const tool of tools) {
      assert.ok(tool.inputSchema.required.includes("configPath"));
      assert.equal(tool.outputSchema.type, "object");
      assert.ok(tool.outputSchema.properties.reportPath);
    }
    assert.equal(tools.find((tool) => tool.name === "repair").inputSchema.properties.apply.default, false);
  });

  await t.test("checks passing and broken projects in isolated runs", async () => {
    const [pass, fail] = await Promise.all([
      call("check", { configPath: configuration(healthy), outDir: "report dir/check" }),
      call("check", { configPath: configuration(broken) }),
    ]);
    assert.equal(Boolean(pass.isError), false);
    assert.equal(Boolean(fail.isError), false);
    assert.equal(pass.structuredContent.status, "passed");
    assert.equal(pass.structuredContent.validationStatus, "passed");
    assert.equal(pass.structuredContent.exitCode, 0);
    assert.equal(fail.structuredContent.status, "failed");
    assert.equal(fail.structuredContent.exitCode, 1);
    assert.equal(fail.structuredContent.initial.stage, "simulate");
    assert.equal(fail.structuredContent.initial.firstError.inputFile, "counter_tb.sv");
    assert.match(fail.structuredContent.initial.firstError.message, /expected=1 actual=2/);
    assert.equal(fail.structuredContent.configPath, await realpath(join(workspace, configuration(broken))));
    for (const result of [pass, fail]) {
      const data = result.structuredContent;
      assert.deepEqual(JSON.parse(result.content[0].text), data);
      assert.ok((await stat(data.reportPath)).isFile());
      const report = JSON.parse(await readFile(data.reportPath, "utf8"));
      assert.equal(report.status, data.status);
      assert.equal(report.configPath, data.configPath);
      assert.equal(data.modelCalls, 0);
    }
    assert.notEqual(pass.structuredContent.runDirectory, fail.structuredContent.runDirectory);
    assert.equal(await readFile(join(workspace, broken, "counter.sv"), "utf8"), original);
  });

  await t.test("routes repair through the original baseline workflow", async () => {
    const result = await call("repair", { configPath: configuration(healthy), repairFile: "counter.sv" });
    assert.equal(Boolean(result.isError), false);
    const data = result.structuredContent;
    assert.equal(data.mode, "repair");
    assert.equal(data.status, "passed");
    assert.equal(data.applied, false);
    assert.equal(data.modelCalls, 0);
    assert.deepEqual(data.candidateFiles, []);
    assert.match(data.inputSha256, /^[a-fA-F0-9]{64}$/);
  });

  await t.test("reports ordered progress without sharing validation details", async () => {
    const notifications = [];
    const result = await client.callTool({
      name: "check",
      arguments: { configPath: configuration(holdout) },
    }, undefined, { onprogress: (progress) => notifications.push(progress) });
    assert.equal(result.structuredContent.validationStatus, "failed");
    assert.deepEqual(notifications.map(({ progress }) => progress), notifications.map((_, index) => index + 1));
    assert.ok(notifications.some(({ message }) => /independent validation/i.test(message)));
    assert.ok(notifications.some(({ message }) => /baseline/i.test(message)));
    assert.doesNotMatch(JSON.stringify(notifications), /independent reset check:|counter_validation_tb\.sv/);
  });

  await t.test("pins repair to the inputs from a preceding check", async () => {
    const configPath = configuration(healthy);
    const checked = (await call("check", { configPath })).structuredContent;
    assert.match(checked.inputSha256, /^[a-fA-F0-9]{64}$/);
    const sourcePath = join(workspace, healthy, "counter.sv");
    await writeFile(sourcePath, correct + "\n// Edited after check\n");
    try {
      const stale = await call("repair", { configPath, repairFile: "counter.sv", expectedInputSha256: checked.inputSha256 });
      assert.equal(stale.isError, true);
      assert.equal(stale.structuredContent.initial, null);
      assert.equal(stale.structuredContent.modelCalls, 0);
      assert.match(stale.structuredContent.error, /Input snapshot digest mismatch/);
    } finally {
      await writeFile(sourcePath, correct);
    }
  });

  await t.test("reports an independent validation failure without its private diagnostic", async () => {
    const result = await call("repair", { configPath: configuration(holdout), repairFile: "counter.sv" });
    assert.equal(Boolean(result.isError), false);
    assert.equal(result.structuredContent.status, "failed");
    assert.equal(result.structuredContent.validationStatus, "failed");
    assert.equal(result.structuredContent.stopReason, "validation_failed");
    assert.equal(result.structuredContent.modelCalls, 0);
    assert.doesNotMatch(JSON.stringify(result), /independent reset check:|counter_validation_tb\.sv/);
    assert.match(await readFile(result.structuredContent.reportPath, "utf8"), /independent reset check:/);
  });

  await t.test("keeps private file diagnostics out of preparation errors", async () => {
    const configPath = configuration(holdout);
    const fullPath = join(workspace, configPath);
    const originalConfig = await readFile(fullPath);
    const config = JSON.parse(originalConfig);
    config.validation.testbenches = ["private-missing-validation.sv"];
    await writeFile(fullPath, JSON.stringify(config));
    try {
      const result = await call("check", { configPath });
      assert.equal(result.isError, true);
      assert.equal(result.structuredContent.status, "error");
      assert.equal(result.structuredContent.exitCode, 2);
      assert.doesNotMatch(JSON.stringify(result), /private-missing-validation/);
      assert.ok(result.structuredContent.reportPath);
      assert.match(await readFile(result.structuredContent.reportPath, "utf8"), /private-missing-validation/);
    } finally {
      await writeFile(fullPath, originalConfig);
    }
  });

  await t.test("preserves the requested path for a linked configuration", async () => {
    let linkedConfig;
    if (process.platform === "win32") {
      const linkedProject = join(workspace, "linked project");
      await symlink(join(workspace, broken), linkedProject, "junction");
      linkedConfig = join(linkedProject, "rtlcheck.json");
    } else {
      linkedConfig = join(workspace, broken, "linked-config.json");
      await symlink(join(workspace, configuration(healthy)), linkedConfig, "file");
    }
    const result = await call("check", { configPath: linkedConfig });
    assert.equal(result.structuredContent.status, "failed");
    assert.equal(result.structuredContent.configPath, linkedConfig);
    assert.match(result.structuredContent.initial.firstError.message, /expected=1 actual=2/);
  });

  await t.test("distinguishes a checker error from a failed design", async () => {
    const result = await call("check", {
      configPath: configuration(healthy),
      expectedInputSha256: "0".repeat(64),
    });
    assert.equal(result.isError, true);
    assert.equal(result.structuredContent.status, "error");
    assert.equal(result.structuredContent.exitCode, 2);
    assert.match(result.structuredContent.error, /Input snapshot digest mismatch/);
    assert.equal(result.structuredContent.initial, null);
  });

  await t.test("rejects outside paths and conflicting repair options before launch", async () => {
    for (const [name, args, reason] of [
      ["check", { configPath: "../external.json" }, /workspace/],
      ["check", { configPath: configuration(healthy), outDir: "../outside" }, /workspace/],
      ["repair", { configPath: configuration(healthy), previewReport: "preview.json" }, /apply/],
      ["repair", { configPath: configuration(healthy), previewReport: "preview.json", apply: true, maxAttempts: 1 }, /model options/],
    ]) {
      const result = await call(name, args);
      assert.equal(result.isError, true);
      assert.match(result.content[0].text, reason);
      assert.equal(result.structuredContent.exitCode, null);
    }
    const invalid = await call("check", { configPath: configuration(healthy), apply: true });
    assert.equal(invalid.isError, true);
  });

  await t.test("cancels active checks and writeback while preserving their reports", async (cancellationTest) => {
    const project = join(workspace, "cancel project");
    await cp(fixture, project, { recursive: true });
    await writeFile(join(project, "counter_tb.sv"), [
      "module counter_tb;",
      "integer marker;",
      "initial begin",
      '  marker = $fopen("mcp-running.marker", "w");',
      '  $fdisplay(marker, "running");',
      "  $fclose(marker);",
      "  forever #1;",
      "end",
      "endmodule",
    ].join("\n"));
    const configPath = join(project, "rtlcheck.json");
    const digest = await call("check", { configPath, expectedInputSha256: "0".repeat(64) });
    assert.equal(digest.structuredContent.exitCode, 2);
    const preview = join(workspace, "preview used to exercise cancellation");
    const candidatePath = join(preview, "01-repair", "candidate", "counter.sv");
    const candidateFiles = [{ path: "counter.sv", candidatePath, sha256: createHash("sha256").update(correct).digest("hex") }];
    await mkdir(dirname(candidatePath), { recursive: true });
    await writeFile(candidatePath, correct);
    const previewReport = join(preview, "summary.json");
    await writeFile(previewReport, JSON.stringify({
      mode: "repair",
      status: "repaired",
      applied: false,
      configPath,
      inputSha256: digest.structuredContent.inputSha256,
      repairFiles: ["counter.sv"],
      attempts: [{ number: 1, status: "passed", check: { status: "passed" }, candidateFiles }],
      candidateFiles,
    }));
    const simulationStarted = async (outDir) => {
      const entry = await waitFor(async () => (await readdir(outDir))[0], "the active run directory");
      const run = join(outDir, entry);
      const marker = join(run, "00-initial", "work", "mcp-running.marker");
      await waitFor(async () => (await readFile(marker, "utf8")).includes("running"), "the native simulation to start");
      return run;
    };
    const completedRun = (run) => waitFor(async () => {
      const report = await readFile(join(run, "summary.json"), "utf8");
      return report.endsWith("\n") ? JSON.parse(report) : null;
    }, "the cancelled operation to finish");
    for (const [name, options] of [
      ["check", {}],
      ["repair", { repairFile: "counter.sv", previewReport, apply: true }],
    ]) {
      const outDir = join(workspace, name + " cancel result");
      const controller = new AbortController();
      const response = client.callTool({
        name,
        arguments: { configPath, outDir, timeoutSeconds: 5, ...options },
      }, undefined, { signal: controller.signal }).then(
        (result) => ({ result }),
        (error) => ({ error }),
      );
      let run;
      let cancelledAt;
      try {
        run = await simulationStarted(outDir);
      } finally {
        cancelledAt = performance.now();
        controller.abort();
      }
      assert.ok((await response).error);
      const completed = await completedRun(run);
      const elapsedAfterCancel = Math.round(performance.now() - cancelledAt);
      cancellationTest.diagnostic(name + " wrote its cancellation report after " + elapsedAfterCancel + " ms");
      assert.ok(elapsedAfterCancel < 3200, "Stopping the active simulation took " + elapsedAfterCancel + " ms");
      assert.equal(completed.status, "error");
      assert.match(completed.error, /cancelled before publication/);
      assert.equal(completed.stopReason, "cancelled");
      assert.equal(completed.applied, false);
      assert.equal(await readFile(join(project, "counter.sv"), "utf8"), original);
    }
    await client.ping();

    await cancellationTest.test("cancels wire request IDs 0 and empty string", async () => {
      const wire = new StdioClientTransport({ command: process.execPath, args: [server, "--workspace", workspace], env: process.env, stderr: "pipe" });
      const messages = [];
      wire.onmessage = (message) => messages.push(message);
      await wire.start();
      try {
        const send = (message) => wire.send({ jsonrpc: "2.0", ...message });
        await send({
          id: 20,
          method: "initialize",
          params: { protocolVersion: LATEST_PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "wire-id-test", version: "1.0.0" } },
        });
        await waitFor(async () => messages.find((message) => message.id === 20 && message.result), "MCP initialize response");
        await send({ method: "notifications/initialized" });
        for (const [id, label] of [[0, "numeric zero"], ["", "empty string"]]) {
          const outDir = join(workspace, label + " cancellation report");
          await send({ id, method: "tools/call", params: { name: "check", arguments: { configPath, outDir, timeoutSeconds: 5 } } });
          const run = await simulationStarted(outDir);
          await send({ method: "notifications/cancelled", params: { requestId: id, reason: "MCP interoperability test" } });
          const report = await completedRun(run);
          assert.equal(report.stopReason, "cancelled", label + " request was not cancelled");
        }
        await send({ id: 21, method: "ping" });
        await waitFor(async () => messages.find((message) => message.id === 21 && message.result), "MCP ping response");
        assert.ok(messages.every(({ id }) => id !== 0 && id !== ""));
      } finally {
        await wire.close();
      }
    });
  });
});
