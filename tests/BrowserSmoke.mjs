import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);
const work = fs.mkdtempSync(path.join(os.tmpdir(), "ai-usage-browser-smoke-"));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "ai-usage-edge-"));
const dataPath = path.join(work, "data.js");
const failurePath = path.join(work, "failure.js");
let browser = null;
let client = null;
let generator = null;
let realStartupTemp = null;

function findEdge() {
  if (process.env.EDGE_PATH && fs.existsSync(process.env.EDGE_PATH)) return process.env.EDGE_PATH;
  const roots = [process.env["PROGRAMFILES(X86)"], process.env.PROGRAMFILES].filter(Boolean);
  for (const base of roots) {
    const candidate = path.join(base, "Microsoft", "Edge", "Application", "msedge.exe");
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error("Microsoft Edge was not found.");
}

function waitFor(check, description, timeoutMs = 15000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const poll = async () => {
      try {
        const value = await check();
        if (value) return resolve(value);
      } catch {}
      if (Date.now() - started >= timeoutMs) return reject(new Error(`Timed out waiting for ${description}.`));
      setTimeout(poll, 100);
    };
    poll();
  });
}

function readSnapshot(source) {
  const match = source.match(/^window\.__DATA__\s*=\s*(.*);\s*if\s*\(/s);
  if (!match) throw new Error("Demo data.js does not match the snapshot wrapper.");
  return JSON.parse(match[1]);
}

function writeSnapshot(value) {
  const temporary = `${dataPath}.tmp`;
  fs.writeFileSync(
    temporary,
    `window.__DATA__ = ${JSON.stringify(value)}; if (window.__render__) window.__render__();`,
    "utf8"
  );
  fs.renameSync(temporary, dataPath);
}

function writeFailurePayload(failure) {
  const temporary = `${failurePath}.tmp`;
  fs.writeFileSync(
    temporary,
    `window.__GENERATION_FAILURE__ = ${JSON.stringify(failure)}; if (window.__fail__) window.__fail__();`,
    "utf8"
  );
  fs.renameSync(temporary, failurePath);
}

function writeFailure(stage, runId, reason = "initial_generation_failed") {
  writeFailurePayload({ reason, stage, runId, generatedAt: new Date().toISOString() });
}

function connectCdp(webSocketUrl, runtimeErrors, networkRequests) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(webSocketUrl);
    const pending = new Map();
    let nextId = 0;
    let opened = false;
    const failPending = (error) => {
      for (const waiter of pending.values()) {
        clearTimeout(waiter.timer);
        waiter.decline(error);
      }
      pending.clear();
    };
    socket.onerror = () => {
      const error = new Error("Edge DevTools connection failed.");
      if (!opened) reject(error);
      failPending(error);
    };
    socket.onclose = () => failPending(new Error("Edge DevTools connection closed."));
    socket.onopen = () => {
      opened = true;
      resolve({
        send(method, params = {}) {
          if (socket.readyState !== WebSocket.OPEN) {
            return Promise.reject(new Error(`Edge DevTools is closed before ${method}.`));
          }
          const id = ++nextId;
          socket.send(JSON.stringify({ id, method, params }));
          return new Promise((accept, decline) => {
            const timer = setTimeout(() => {
              pending.delete(id);
              decline(new Error(`Edge DevTools timed out during ${method}.`));
            }, 10000);
            pending.set(id, { accept, decline, timer });
          });
        },
        close() { socket.close(); }
      });
    };
    socket.onmessage = (event) => {
      const message = JSON.parse(String(event.data));
      if (message.id && pending.has(message.id)) {
        const waiter = pending.get(message.id);
        pending.delete(message.id);
        clearTimeout(waiter.timer);
        if (message.error) waiter.decline(new Error(`${message.error.code}: ${message.error.message}`));
        else waiter.accept(message.result);
        return;
      }
      if (message.method === "Runtime.exceptionThrown") {
        const detail = message.params.exceptionDetails;
        runtimeErrors.push(detail.exception?.description || detail.text || "Runtime exception");
      }
      if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
        runtimeErrors.push("console.error");
      }
      if (message.method === "Network.requestWillBeSent") {
        networkRequests.push(message.params.request.url);
      }
    };
  });
}

async function evaluate(expression) {
  const result = await client.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || "Evaluation failed.");
  return result.result.value;
}

function pngSize(base64) {
  const buffer = Buffer.from(base64, "base64");
  assert.ok(buffer.length > 10000, "Browser screenshot is unexpectedly small.");
  assert.equal(buffer.toString("ascii", 1, 4), "PNG", "Browser screenshot is not PNG.");
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20), bytes: buffer.length };
}

async function measureRealStartup(generatorPath) {
  const absoluteGenerator = path.resolve(generatorPath);
  assert.ok(fs.existsSync(absoluteGenerator), `Real generator was not found: ${absoluteGenerator}`);
  realStartupTemp = fs.mkdtempSync(path.join(os.tmpdir(), "ai-usage-real-startup-"));
  const runtimeRoot = path.join(realStartupTemp, "ClaudeUsage");
  const reportPath = path.join(runtimeRoot, "report.html");
  const launchTargetPath = path.join(realStartupTemp, "launch-target.txt");
  const runStatePath = path.join(runtimeRoot, "report-run.state");
  const runOwnerPath = path.join(runtimeRoot, "report-run.owner.json");
  const readLeasePath = path.join(runtimeRoot, "report-read.lease");
  const wrapperPath = path.join(work, "real-startup-wrapper.ps1");
  fs.writeFileSync(wrapperPath, [
    "param(",
    "  [Parameter(Mandatory = $true)][string]$GeneratorPath,",
    "  [Parameter(Mandatory = $true)][string]$LaunchTargetPath",
    ")",
    "function Start-Process {",
    "  param([Parameter(Position = 0)][string]$FilePath)",
    "  [IO.File]::WriteAllText($LaunchTargetPath, $FilePath, [Text.Encoding]::ASCII)",
    "}",
    "& $GeneratorPath -DeleteAfter 30"
  ].join("\r\n"), "ascii");

  const generatorOutput = [];
  const startedAt = Date.now();
  generator = spawn("powershell.exe", [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", wrapperPath,
    "-GeneratorPath", absoluteGenerator, "-LaunchTargetPath", launchTargetPath
  ], {
    cwd: root,
    env: { ...process.env, TEMP: realStartupTemp, TMP: realStartupTemp },
    stdio: ["ignore", "pipe", "pipe"]
  });
  generator.stdout.on("data", (chunk) => generatorOutput.push(String(chunk)));
  generator.stderr.on("data", (chunk) => generatorOutput.push(String(chunk)));

  const edge = findEdge();
  browser = spawn(edge, [
    "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
    `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"
  ], { stdio: "ignore" });
  const activePortPath = path.join(profile, "DevToolsActivePort");
  const debugPort = await waitFor(() => {
    if (!fs.existsSync(activePortPath)) return null;
    return Number(fs.readFileSync(activePortPath, "utf8").split(/\r?\n/)[0]) || null;
  }, "Edge DevTools port");
  const targets = await waitFor(async () => {
    const response = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
    const values = await response.json();
    return values.find((value) => value.type === "page" && value.webSocketDebuggerUrl) ? values : null;
  }, "Edge page target");
  const target = targets.find((value) => value.type === "page" && value.webSocketDebuggerUrl);
  const runtimeErrors = [];
  const networkRequests = [];
  client = await connectCdp(target.webSocketDebuggerUrl, runtimeErrors, networkRequests);
  await client.send("Runtime.enable");
  await client.send("Page.enable");
  await client.send("Network.enable");
  await client.send("Emulation.setDeviceMetricsOverride", {
    width: 1280, height: 900, deviceScaleFactor: 1, mobile: false
  });

  const launchTarget = await waitFor(() => {
    if (!fs.existsSync(launchTargetPath) || !fs.existsSync(reportPath)) return null;
    if (!fs.existsSync(runStatePath) || !fs.existsSync(runOwnerPath) || !fs.existsSync(readLeasePath)) return null;
    const owner = JSON.parse(fs.readFileSync(runOwnerPath, "utf8"));
    if (fs.readFileSync(runStatePath, "utf8").trim() !== "active" || owner.phase !== "active") return null;
    return fs.readFileSync(launchTargetPath, "ascii").trim();
  }, "the real generator launch target and active lease", 15000);
  const reportUrl = new URL(launchTarget);
  assert.equal(reportUrl.protocol, "file:");
  assert.equal(path.resolve(fileURLToPath(reportUrl)), reportPath);
  assert.equal(reportUrl.searchParams.get("period"), "30days");
  await client.send("Page.navigate", { url: reportUrl.href });
  const visibleState = await waitFor(
    () => evaluate(`(function () {
      if (!document.querySelector('#app')?.classList.contains('show') || !window.__DATA__) return null;
      return {
        period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
        complete: window.__DATA__.complete,
        periods: window.__DATA__.periods,
        bootError: window.__BOOT_ERROR__ || null,
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
      };
    })()`),
    "the real dashboard to become visible",
    30000
  );
  const visibleMilliseconds = Date.now() - startedAt;
  const budgetMilliseconds = Number(process.env.AI_USAGE_STARTUP_BUDGET_MS || 25000);
  assert.equal(visibleState.period, "30days");
  assert.equal(visibleState.complete, false);
  assert.equal(visibleState.bootError, null);
  assert.equal(visibleState.overflow, 0);
  // The page opens on quota alone; the default period's usage follows.
  const usageState = await waitFor(
    () => evaluate(`(function () {
      if (!window.__DATA__ || !(window.__DATA__.periods || []).length) return null;
      if (document.querySelector('#app').classList.contains('usage-pending')) return null;
      return { periods: window.__DATA__.periods };
    })()`),
    "the first usage revision",
    30000
  );
  const usageMilliseconds = Date.now() - startedAt;
  assert.deepEqual(usageState.periods, ["30days"]);
  assert.deepEqual(runtimeErrors, [], `Browser runtime errors: ${runtimeErrors.join(" | ")}`);
  assert.ok(
    usageMilliseconds < budgetMilliseconds,
    `Real process-to-usage took ${usageMilliseconds} ms, above the ${budgetMilliseconds} ms budget. ${generatorOutput.join("")}`
  );
  console.log(`BrowserSmoke.mjs: REAL STARTUP PASS (process-to-app.show ${visibleMilliseconds} ms, process-to-usage ${usageMilliseconds} ms)`);
}

async function main() {
  const demo = spawnSync("powershell.exe", [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    path.join(here, "New-DemoSnapshot.ps1"), "-OutputDirectory", work
  ], { cwd: root, encoding: "utf8" });
  if (demo.status !== 0) throw new Error(demo.stderr || demo.stdout || "Demo generation failed.");

  const finalSnapshot = readSnapshot(fs.readFileSync(dataPath, "utf8"));
  finalSnapshot.runId = "browser-smoke";
  finalSnapshot.revision = 4;
  finalSnapshot.complete = true;
  const defaultPeriod = finalSnapshot.period;

  // Quota is published before the first usage report.
  const quotaOnlySnapshot = structuredClone(finalSnapshot);
  quotaOnlySnapshot.runId = "previous-browser-smoke";
  quotaOnlySnapshot.revision = 98;
  quotaOnlySnapshot.complete = false;
  quotaOnlySnapshot.periods = [];
  quotaOnlySnapshot.reports = {};
  quotaOnlySnapshot.currency = { code: "USD", rate: 1, symbol: "$" };

  const partialSnapshot = structuredClone(finalSnapshot);
  partialSnapshot.runId = "previous-browser-smoke";
  partialSnapshot.revision = 99;
  partialSnapshot.complete = false;
  partialSnapshot.periods = [defaultPeriod];
  partialSnapshot.reports = { [defaultPeriod]: partialSnapshot.reports[defaultPeriod] };
  partialSnapshot.limits.claudeQuota = { ok: false, reason: "loading" };
  partialSnapshot.limits.codexQuota = { ok: false, reason: "loading" };
  partialSnapshot.limits.codex = { ok: false, reason: "loading" };

  const chartSnapshot = structuredClone(partialSnapshot);
  chartSnapshot.runId = "browser-smoke";
  chartSnapshot.revision = 1;
  chartSnapshot.reports[defaultPeriod].codex.overview.calls += 1;

  const detailSnapshot = structuredClone(finalSnapshot);
  detailSnapshot.revision = 2;
  detailSnapshot.complete = false;
  detailSnapshot.periods = [defaultPeriod, "week"];
  detailSnapshot.reports = {
    [defaultPeriod]: detailSnapshot.reports[defaultPeriod],
    week: detailSnapshot.reports.week
  };
  detailSnapshot.reports[defaultPeriod].codex.overview.calls += 2;
  detailSnapshot.limits.claudeQuota = { ok: false, reason: "loading" };
  detailSnapshot.limits.codexQuota = { ok: false, reason: "loading" };
  // Older snapshots carried no official quota object at all; the page must cope.
  detailSnapshot.limits.codex = null;

  const expandedSnapshot = structuredClone(finalSnapshot);
  expandedSnapshot.revision = 3;
  expandedSnapshot.complete = false;
  expandedSnapshot.limits.claudeQuota = { ok: false, reason: "loading" };
  expandedSnapshot.limits.codexQuota = { ok: false, reason: "loading" };
  expandedSnapshot.limits.codex = { ok: false, reason: "loading" };
  fs.unlinkSync(dataPath);

  const edge = findEdge();
  browser = spawn(edge, [
    "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
    `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"
  ], { stdio: "ignore" });

  const activePortPath = path.join(profile, "DevToolsActivePort");
  const debugPort = await waitFor(() => {
    if (!fs.existsSync(activePortPath)) return null;
    return Number(fs.readFileSync(activePortPath, "utf8").split(/\r?\n/)[0]) || null;
  }, "Edge DevTools port");
  const targets = await waitFor(async () => {
    const response = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
    const values = await response.json();
    return values.find((value) => value.type === "page" && value.webSocketDebuggerUrl) ? values : null;
  }, "Edge page target");
  const target = targets.find((value) => value.type === "page" && value.webSocketDebuggerUrl);
  const runtimeErrors = [];
  const networkRequests = [];
  client = await connectCdp(target.webSocketDebuggerUrl, runtimeErrors, networkRequests);
  await client.send("Runtime.enable");
  await client.send("Page.enable");
  await client.send("Network.enable");
  await client.send("Emulation.setDeviceMetricsOverride", {
    width: 1280, height: 900, deviceScaleFactor: 1, mobile: false
  });
  await client.send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-color-scheme", value: "light" }]
  });
  const reportUrl = pathToFileURL(path.join(work, "report.html"));
  reportUrl.searchParams.set("period", "all");
  reportUrl.searchParams.set("provider", "codex");
  await client.send("Page.navigate", { url: reportUrl.href });

  await new Promise((resolve) => setTimeout(resolve, 800));
  const waitingState = await evaluate(`({
    appShown: document.querySelector('#app').classList.contains('show'),
    loaderVisible: getComputedStyle(document.querySelector('#loader')).display !== 'none',
    protocol: location.protocol,
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.equal(waitingState.appShown, false);
  assert.equal(waitingState.loaderVisible, true);
  assert.equal(waitingState.protocol, "file:");
  assert.equal(waitingState.bootError, null);

  writeSnapshot(quotaOnlySnapshot);
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.revision === 98 && document.querySelector('#app').classList.contains('show')"),
    "the quota-only first revision"
  );
  const quotaOnlyState = await evaluate(`({
    pending: document.querySelector('#app').classList.contains('usage-pending'),
    waitVisible: getComputedStyle(document.querySelector('.usage-wait')).display !== 'none',
    heroHidden: getComputedStyle(document.querySelector('.hero')).display === 'none',
    detailsHidden: getComputedStyle(document.querySelector('#details')).display === 'none',
    quotaCards: document.querySelectorAll('#quota .quota').length,
    codexPlan: document.querySelector('#quota').textContent.includes('Pro'),
    loaderHidden: getComputedStyle(document.querySelector('#loader')).display === 'none' ||
      document.querySelector('#loader').classList.contains('done'),
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
  })`);
  assert.equal(quotaOnlyState.pending, true);
  assert.equal(quotaOnlyState.waitVisible, true);
  assert.equal(quotaOnlyState.heroHidden, true);
  assert.equal(quotaOnlyState.detailsHidden, true);
  assert.equal(quotaOnlyState.quotaCards, 1, "Only the Codex card belongs to the codex filter.");
  assert.equal(quotaOnlyState.codexPlan, true);
  assert.equal(quotaOnlyState.loaderHidden, true);
  assert.equal(quotaOnlyState.bootError, null);
  assert.equal(quotaOnlyState.overflow, 0);

  writeSnapshot(partialSnapshot);

  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.runId === 'previous-browser-smoke' && window.__DATA__.revision === 99 && document.querySelector('#app').classList.contains('show')"),
    "the first progressive revision"
  );
  const partialState = await evaluate(`(function () {
    return {
      complete: window.__DATA__.complete,
      period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
      provider: document.querySelector('[data-filter][aria-pressed="true"]')?.dataset.filter,
      updating: document.querySelector('#stamp').textContent.includes('\u66f4\u65b0\u4e2d'),
      quotaLoading: document.querySelector('#quota').textContent.includes('\u6b63\u5728\u83b7\u53d6\u989d\u5ea6'),
      usagePending: document.querySelector('#app').classList.contains('usage-pending'),
      heroShown: getComputedStyle(document.querySelector('.hero')).display !== 'none',
      bootError: window.__BOOT_ERROR__ || null,
      overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
    };
  })()`);
  assert.equal(partialState.usagePending, false);
  assert.equal(partialState.heroShown, true);
  assert.equal(partialState.complete, false);
  assert.equal(partialState.period, defaultPeriod);
  assert.equal(partialState.provider, "codex");
  assert.equal(partialState.updating, true);
  assert.equal(partialState.quotaLoading, true);
  assert.equal(partialState.bootError, null);
  assert.equal(partialState.overflow, 0);

  const duplicateProbe = await evaluate(`(function () {
    var source = document.querySelector('#source');
    source.textContent = 'REVISION_PROBE';
    window.__DATA__ = Object.assign({}, window.__DATA__, { revision: 99, source: { name: 'bad' } });
    window.__render__();
    return source.textContent;
  })()`);
  assert.equal(duplicateProbe, "REVISION_PROBE", "A duplicate revision triggered a redraw.");

  const beforeChartRevision = await evaluate(`(function () {
    document.querySelector('#trendTableBtn').click();
    document.querySelector('#themeBtn').click();
    var detail = document.querySelector('#details details:nth-of-type(2)');
    detail.open = true;
    var points = Array.from(document.querySelectorAll('#modelDonut [data-tip]'));
    points[Math.min(1, points.length - 1)].focus();
    return {
      detailOpen: detail.open,
      chartFocused: document.querySelector('#modelDonut').contains(document.activeElement),
      chartIndex: points.indexOf(document.activeElement)
    };
  })()`);
  assert.equal(beforeChartRevision.detailOpen, true);
  assert.equal(beforeChartRevision.chartFocused, true);
  assert.ok(beforeChartRevision.chartIndex >= 0);

  writeSnapshot(chartSnapshot);
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.runId === 'browser-smoke' && window.__DATA__.revision === 1"),
    "a lower revision from a new run"
  );
  const chartState = await evaluate(`(function () {
    var points = Array.from(document.querySelectorAll('#modelDonut [data-tip]'));
    return {
      runId: window.__DATA__.runId,
      revision: window.__DATA__.revision,
      chartFocused: document.querySelector('#modelDonut').contains(document.activeElement),
      chartIndex: points.indexOf(document.activeElement),
      detailOpen: document.querySelector('#details details:nth-of-type(2)').open,
      provider: document.querySelector('[data-filter][aria-pressed="true"]')?.dataset.filter,
      tableShown: !document.querySelector('#trendTable').classList.contains('hide'),
      themePinned: Boolean(document.documentElement.dataset.cs),
      sourceRecovered: document.querySelector('#source').textContent !== 'REVISION_PROBE',
      bootError: window.__BOOT_ERROR__ || null
    };
  })()`);
  assert.equal(chartState.runId, "browser-smoke");
  assert.equal(chartState.revision, 1);
  assert.equal(chartState.chartFocused, true, JSON.stringify(chartState));
  assert.equal(chartState.chartIndex, beforeChartRevision.chartIndex);
  assert.equal(chartState.detailOpen, true);
  assert.equal(chartState.provider, "codex");
  assert.equal(chartState.tableShown, true);
  assert.equal(chartState.themePinned, true);
  assert.equal(chartState.sourceRecovered, true);
  assert.equal(chartState.bootError, null);

  await evaluate("document.querySelector('#details details:nth-of-type(2) summary').focus()")
  writeSnapshot(detailSnapshot);
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.revision === 2 && document.querySelectorAll('[data-period]').length === 2"),
    "the detail-focus usage revision"
  );
  const detailState = await evaluate(`({
    detailOpen: document.querySelector('#details details:nth-of-type(2)').open,
    detailFocused: document.activeElement === document.querySelector('#details details:nth-of-type(2) summary'),
    periods: document.querySelectorAll('[data-period]').length
  })`);
  assert.equal(detailState.detailOpen, true);
  assert.equal(detailState.detailFocused, true);
  assert.equal(detailState.periods, 2);

  await evaluate(`document.querySelector('[data-period="${defaultPeriod}"]').focus()`);
  writeSnapshot(expandedSnapshot);
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.revision === 3 && document.querySelector('[data-period][aria-pressed=\"true\"]')?.dataset.period === 'all'"),
    "the expanded report revision and deferred URL period"
  );
  const interactiveState = await evaluate(`({
    periods: document.querySelectorAll('[data-period]').length,
    period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
    periodFocused: document.activeElement?.dataset.period,
    provider: document.querySelector('[data-filter][aria-pressed="true"]')?.dataset.filter,
    updating: document.querySelector('#stamp').textContent.includes('\u66f4\u65b0\u4e2d'),
    loaderHidden: getComputedStyle(document.querySelector('#loader')).display === 'none',
    tableShown: !document.querySelector('#trendTable').classList.contains('hide'),
    themePinned: Boolean(document.documentElement.dataset.cs),
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
  })`);
  assert.equal(interactiveState.periods, 3);
  assert.equal(interactiveState.period, "all");
  assert.equal(interactiveState.periodFocused, defaultPeriod);
  assert.equal(interactiveState.provider, "codex");
  assert.equal(interactiveState.updating, true);
  assert.equal(interactiveState.loaderHidden, true);
  assert.equal(interactiveState.tableShown, true);
  assert.equal(interactiveState.themePinned, true);
  assert.equal(interactiveState.bootError, null);
  assert.equal(interactiveState.overflow, 0);

  await evaluate(`document.querySelector('[data-period="week"]').click()`);
  await new Promise((resolve) => setTimeout(resolve, 250));
  const beforeQuotaRevision = await evaluate(`(function () {
    var detail = document.querySelector('#details details:nth-of-type(2)');
    detail.open = true;
    var point = document.querySelector('#modelDonut [data-tip]');
    point.focus();
    window.__detailProbe = detail;
    window.__chartProbe = point;
    return {
      period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
      chartFocused: document.activeElement === point,
      stampPeriod: document.querySelector('#stamp').textContent.includes('\u8fd1 7 \u5929')
    };
  })()`);
  assert.equal(beforeQuotaRevision.period, "week");
  assert.equal(beforeQuotaRevision.chartFocused, true);
  assert.equal(beforeQuotaRevision.stampPeriod, true);

  writeSnapshot(finalSnapshot);
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.revision === 4 && window.__DATA__.complete === true"),
    "the quota-only complete revision"
  );
  const finalState = await evaluate(`({
    period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
    chartFocused: document.activeElement === window.__chartProbe,
    chartPreserved: document.querySelector('#modelDonut').contains(window.__chartProbe),
    detailPreserved: document.querySelector('#details').contains(window.__detailProbe),
    updating: document.querySelector('#stamp').textContent.includes('\u66f4\u65b0\u4e2d'),
    tableShown: !document.querySelector('#trendTable').classList.contains('hide'),
    themePinned: Boolean(document.documentElement.dataset.cs),
    detailOpen: document.querySelector('#details details:nth-of-type(2)').open,
    completed: document.querySelector('#stamp').textContent.includes('\u66f4\u65b0\u5b8c\u6210'),
    quotaLoaded: !document.querySelector('#quota').textContent.includes('\u6b63\u5728\u83b7\u53d6\u989d\u5ea6'),
    codexWindows: document.querySelector('#quota').textContent.includes('5 \u5c0f\u65f6\u989d\u5ea6') &&
      document.querySelector('#quota').textContent.includes('\u5468\u989d\u5ea6'),
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
  })`);
  assert.equal(finalState.codexWindows, true, "The official Codex card did not label its plan windows.");
  assert.equal(finalState.period, "week");
  assert.equal(finalState.chartFocused, true);
  assert.equal(finalState.chartPreserved, true);
  assert.equal(finalState.detailPreserved, true);
  assert.equal(finalState.updating, false);
  assert.equal(finalState.tableShown, true);
  assert.equal(finalState.themePinned, true);
  assert.equal(finalState.detailOpen, true);
  assert.equal(finalState.completed, true);
  assert.equal(finalState.quotaLoaded, true);
  assert.equal(finalState.bootError, null);
  assert.equal(finalState.overflow, 0);

  const dataRequests = () => networkRequests.filter((url) => {
    try { return new URL(url).pathname.replace(/\\/g, "/").endsWith("/data.js"); }
    catch { return false; }
  }).length;
  const failureRequests = () => networkRequests.filter((url) => {
    try { return new URL(url).pathname.replace(/\\/g, "/").endsWith("/failure.js"); }
    catch { return false; }
  }).length;
  const coordinationRequests = () => dataRequests() + failureRequests();
  const requestsAtCompletion = dataRequests();
  assert.ok(requestsAtCompletion >= 4, "Progressive data.js loads were not observed.");
  await new Promise((resolve) => setTimeout(resolve, 1300));
  assert.equal(dataRequests(), requestsAtCompletion, "Polling continued after complete:true.");

  const desktopShot = pngSize((await client.send("Page.captureScreenshot", { format: "png" })).data);
  assert.deepEqual([desktopShot.width, desktopShot.height], [1280, 900]);
  await client.send("Emulation.setDeviceMetricsOverride", {
    width: 390, height: 844, deviceScaleFactor: 1, mobile: true
  });
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.equal(await evaluate("document.documentElement.scrollWidth - document.documentElement.clientWidth"), 0);
  const mobileShot = pngSize((await client.send("Page.captureScreenshot", { format: "png" })).data);
  assert.deepEqual([mobileShot.width, mobileShot.height], [390, 844]);
  assert.deepEqual(runtimeErrors, [], `Browser runtime errors: ${runtimeErrors.join(" | ")}`);

  if (process.env.AI_USAGE_DOCS_DIR) {
    const docsDirectory = path.resolve(process.env.AI_USAGE_DOCS_DIR);
    fs.mkdirSync(docsDirectory, { recursive: true });
    await evaluate(`(function () {
      document.querySelector('[data-filter="all"]').click();
      document.querySelector('[data-period="30days"]').click();
      document.querySelector('#trendChartBtn').click();
      if (document.documentElement.dataset.cs) document.querySelector('#themeBtn').click();
      scrollTo(0, 0);
    })()`);
    await client.send("Emulation.setDeviceMetricsOverride", {
      width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false
    });
    await new Promise((resolve) => setTimeout(resolve, 900));
    const dashboardData = (await client.send("Page.captureScreenshot", { format: "png" })).data;
    assert.deepEqual(Object.values(pngSize(dashboardData)).slice(0, 2), [1280, 1000]);
    fs.writeFileSync(path.join(docsDirectory, "dashboard.png"), Buffer.from(dashboardData, "base64"));

    await client.send("Emulation.setDeviceMetricsOverride", {
      width: 520, height: 1200, deviceScaleFactor: 1, mobile: true
    });
    await evaluate("scrollTo(0, 0)");
    await new Promise((resolve) => setTimeout(resolve, 900));
    const mobileData = (await client.send("Page.captureScreenshot", { format: "png" })).data;
    assert.deepEqual(Object.values(pngSize(mobileData)).slice(0, 2), [520, 1200]);
    fs.writeFileSync(path.join(docsDirectory, "mobile.png"), Buffer.from(mobileData, "base64"));
  }

  const degradedSnapshot = structuredClone(finalSnapshot);
  degradedSnapshot.runId = "degraded-browser-smoke";
  degradedSnapshot.revision = 1;
  degradedSnapshot.generationError = { reason: "partial_generation_failed", stage: "remaining_usage" };
  const degradedState = await evaluate(`(function () {
    window.__DATA__ = ${JSON.stringify(degradedSnapshot)};
    window.__render__();
    return document.querySelector('#stamp').textContent;
  })()`);
  assert.ok(degradedState.includes("\u90e8\u5206\u66f4\u65b0\u5931\u8d25\uff0c\u8bf7\u91cd\u65b0\u542f\u52a8"));

  // Recorded quota: a signed-out CLI shows the desktop app's sample with its source,
  // and a recorded Codex window that has since rolled over says so.
  const recordedSnapshot = structuredClone(finalSnapshot);
  recordedSnapshot.runId = "recorded-browser-smoke";
  recordedSnapshot.revision = 1;
  recordedSnapshot.limits.claudeQuota = {
    ok: true, reason: null, source: "claude_desktop", stale: true, staleReason: "no_credentials",
    cachedAt: new Date(Date.now() - 20 * 60000).toISOString(),
    fiveHour: { utilization: 22, resetsAt: null }, sevenDay: { utilization: 7, resetsAt: null }, limits: []
  };
  recordedSnapshot.limits.codex = {
    ok: true, reason: null, source: "session", observedAt: new Date(Date.now() - 9 * 86400000).toISOString(),
    planType: null, stale: true, staleReason: "request_timed_out",
    primary: { used_percent: 64, resets_at: new Date(Date.now() - 2 * 86400000).toISOString(), window_minutes: 10080 },
    secondary: null
  };
  // A window with tokens but no cost had no price available; it is not a free window.
  recordedSnapshot.limits.claudeBlocks.blocks = recordedSnapshot.limits.claudeBlocks.blocks.map((block) =>
    block.isActive
      ? { ...block, costUSD: 0, totalTokens: 340707781, burnRate: { costPerHour: 0 }, projection: { totalCost: 0 } }
      : block
  );
  const recordedState = await evaluate(`(function () {
    document.querySelector('[data-filter="all"]').click();
    var pricedCard = document.querySelector('#quota .quota:first-child').textContent;
    window.__DATA__ = ${JSON.stringify(recordedSnapshot)};
    window.__render__();
    var text = document.querySelector('#quota').textContent;
    var claudeCard = document.querySelector('#quota .quota:first-child').textContent;
    return {
      desktopSource: text.includes('Claude \u684c\u9762\u7248'),
      loginHint: text.includes('claude auth login'),
      unpricedWindow: claudeCard.includes('\u672a\u5b9a\u4ef7') && !claudeCard.includes('$0.00'),
      pricedWindow: pricedCard.includes('$12.50') && !pricedCard.includes('\u672a\u5b9a\u4ef7'),
      claudeMeters: document.querySelectorAll('#quota .quota:first-child .meter-row:not(.is-reset)').length,
      codexReset: text.includes('\u5df2\u91cd\u7f6e'),
      codexStale: text.includes('\u672c\u5730\u8bb0\u5f55'),
      overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
    };
  })()`);
  assert.equal(recordedState.desktopSource, true, JSON.stringify(recordedState));
  assert.equal(recordedState.loginHint, true);
  assert.equal(recordedState.unpricedWindow, true, "An unpriced window was shown as a zero cost.");
  assert.equal(recordedState.pricedWindow, true, "A priced window lost its cost.");
  assert.equal(recordedState.claudeMeters, 2);
  assert.equal(recordedState.codexReset, true);
  assert.equal(recordedState.codexStale, true);
  assert.equal(recordedState.overflow, 0);

  // ccusage can finish after the first usage revision: its window row holds its place
  // meanwhile, and the hour chart follows when the blocks land. A profile with unpriced
  // or partly priced windows is hidden rather than drawn with a false peak.
  const lateBlocks = structuredClone(finalSnapshot);
  lateBlocks.runId = "late-blocks-browser-smoke";
  const withoutBlocks = structuredClone(lateBlocks);
  withoutBlocks.revision = 1;
  withoutBlocks.complete = false;
  withoutBlocks.limits.claudeBlocks = null;
  // A run can end without blocks (ccusage missing or failed) and with unchanged limits.
  const endedWithoutBlocks = structuredClone(withoutBlocks);
  endedWithoutBlocks.revision = 2;
  endedWithoutBlocks.complete = true;
  const withBlocks = structuredClone(lateBlocks);
  withBlocks.revision = 3;
  const unpricedBlocks = structuredClone(lateBlocks);
  unpricedBlocks.revision = 4;
  // Only the active window loses its price; the others keep the profile above zero.
  unpricedBlocks.limits.claudeBlocks.blocks = unpricedBlocks.limits.claudeBlocks.blocks.map((block) =>
    block.isActive ? { ...block, costUSD: 0, totalTokens: 5000000 } : block
  );
  const partlyPricedBlocks = structuredClone(lateBlocks);
  partlyPricedBlocks.revision = 5;
  partlyPricedBlocks.limits.claudeBlocks.blocks = partlyPricedBlocks.limits.claudeBlocks.blocks.map((block) =>
    block.isActive ? { ...block, costIncomplete: true } : block
  );
  const hoursState = await evaluate(`(function () {
    var hidden = function () { return document.querySelector('#hoursWrap').classList.contains('hide'); };
    var windowCost = function () {
      var cells = Array.prototype.slice.call(document.querySelectorAll('#quota .quota:first-child .prov-stats div'));
      var cell = cells.filter(function (c) { return c.textContent.indexOf('窗口成本') === 0; })[0];
      return cell ? cell.querySelector('b').textContent : null;
    };
    var state = {};
    window.__DATA__ = ${JSON.stringify(withoutBlocks)};
    window.__render__();
    state.pending = { hidden: hidden(), cost: windowCost() };
    window.__DATA__ = ${JSON.stringify(endedWithoutBlocks)};
    window.__render__();
    state.ended = { hidden: hidden(), cost: windowCost() };
    window.__DATA__ = ${JSON.stringify(withBlocks)};
    window.__render__();
    state.priced = { hidden: hidden(), cost: windowCost() };
    window.__DATA__ = ${JSON.stringify(unpricedBlocks)};
    window.__render__();
    state.unpriced = { hidden: hidden(), cost: windowCost() };
    window.__DATA__ = ${JSON.stringify(partlyPricedBlocks)};
    window.__render__();
    state.partlyPriced = { hidden: hidden(), cost: windowCost() };
    state.overflow = document.documentElement.scrollWidth - document.documentElement.clientWidth;
    return state;
  })()`);
  assert.deepEqual(hoursState, {
    pending: { hidden: true, cost: "…计算中" },
    ended: { hidden: true, cost: null },
    priced: { hidden: false, cost: "$12.50" },
    unpriced: { hidden: true, cost: "未定价" },
    partlyPriced: { hidden: true, cost: "≥$12.50" },
    overflow: 0
  }, JSON.stringify(hoursState));

  const staleIncompleteSnapshot = structuredClone(finalSnapshot);
  staleIncompleteSnapshot.runId = "stale-incomplete-browser-smoke";
  staleIncompleteSnapshot.revision = 1;
  staleIncompleteSnapshot.complete = false;
  staleIncompleteSnapshot.generationError = null;
  // ccusage has not answered yet, so the window row is a placeholder until the failure.
  staleIncompleteSnapshot.limits.claudeBlocks = null;
  writeSnapshot(staleIncompleteSnapshot);
  const staleFailureUrl = pathToFileURL(path.join(work, "report.html"));
  staleFailureUrl.searchParams.set("failure", "stale-incomplete");
  await client.send("Page.navigate", { url: staleFailureUrl.href });
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'stale-incomplete-browser-smoke' && document.querySelector('#stamp')?.textContent.includes('更新中')"),
    "an existing incomplete snapshot before its terminal failure signal"
  );
  assert.equal(
    await evaluate("document.querySelector('#quota .quota:first-child').textContent.includes('计算中')"),
    true,
    "An incomplete run without blocks did not hold the window row."
  );
  writeFailure("default_usage", "different-browser-smoke", "partial_generation_failed");
  await new Promise((resolve) => setTimeout(resolve, 750));
  const mismatchedFailureState = await evaluate(`({
    stamp: document.querySelector('#stamp').textContent,
    failure: window.__GENERATION_FAILURE__ || null
  })`);
  assert.ok(mismatchedFailureState.stamp.includes("\u66f4\u65b0\u4e2d"));
  assert.equal(mismatchedFailureState.failure?.runId, "different-browser-smoke");
  assert.ok(fs.existsSync(dataPath), "A sidecar failure overwrote the usable data snapshot.");

  writeFailure("final_publish", "stale-incomplete-browser-smoke", "partial_generation_failed");
  await waitFor(
    () => evaluate("document.querySelector('#stamp')?.textContent.includes('数据生成失败')"),
    "the terminal failure signal over an existing incomplete snapshot"
  );
  const staleFailureRequests = coordinationRequests();
  await new Promise((resolve) => setTimeout(resolve, 1300));
  const staleFailureState = await evaluate(`({
    appShown: document.querySelector('#app').classList.contains('show'),
    loaderHidden: getComputedStyle(document.querySelector('#loader')).display === 'none',
    stamp: document.querySelector('#stamp').textContent,
    failure: window.__GENERATION_FAILURE__ || null,
    bootError: window.__BOOT_ERROR__ || null,
    windowRow: document.querySelector('#quota .quota:first-child').textContent.includes('窗口成本')
  })`);
  assert.equal(staleFailureState.windowRow, false, "A terminal failure left the window row placeholder.");
  assert.equal(staleFailureState.appShown, true);
  assert.equal(staleFailureState.loaderHidden, true);
  assert.ok(staleFailureState.stamp.includes("\u6570\u636e\u751f\u6210\u5931\u8d25\uff0c\u8bf7\u91cd\u65b0\u542f\u52a8"));
  assert.equal(staleFailureState.failure?.stage, "final_publish");
  assert.equal(staleFailureState.failure?.runId, "stale-incomplete-browser-smoke");
  assert.equal(staleFailureState.bootError, null);
  assert.equal(coordinationRequests(), staleFailureRequests, "Polling continued after a terminal failure over existing data.");

  // A startup failure after the quota-only revision: the quota stays, the usage card
  // says it failed, and polling stops.
  fs.unlinkSync(failurePath);
  const quotaFailureSnapshot = structuredClone(quotaOnlySnapshot);
  quotaFailureSnapshot.runId = "quota-failure-browser-smoke";
  quotaFailureSnapshot.revision = 1;
  writeSnapshot(quotaFailureSnapshot);
  const quotaFailureUrl = pathToFileURL(path.join(work, "report.html"));
  quotaFailureUrl.searchParams.set("failure", "quota-only");
  await client.send("Page.navigate", { url: quotaFailureUrl.href });
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'quota-failure-browser-smoke' && document.querySelector('#app')?.classList.contains('usage-pending')"),
    "a quota-only page before its startup failure"
  );
  writeFailure("default_usage", "quota-failure-browser-smoke");
  await waitFor(
    () => evaluate("document.querySelector('.usage-wait')?.classList.contains('failed')"),
    "the startup failure over a quota-only page"
  );
  const quotaFailureRequests = coordinationRequests();
  await new Promise((resolve) => setTimeout(resolve, 1300));
  const quotaFailureState = await evaluate(`({
    stamp: document.querySelector('#stamp').textContent,
    wait: document.querySelector('.usage-wait p').textContent,
    quotaCards: document.querySelectorAll('#quota .quota').length,
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.ok(quotaFailureState.stamp.includes("数据生成失败"));
  assert.ok(quotaFailureState.wait.includes("读取失败"));
  assert.ok(quotaFailureState.quotaCards >= 1);
  assert.equal(quotaFailureState.bootError, null);
  assert.equal(coordinationRequests(), quotaFailureRequests, "Polling continued after a startup failure over a quota-only page.");

  fs.unlinkSync(dataPath);
  fs.unlinkSync(failurePath);
  const failureUrl = pathToFileURL(path.join(work, "report.html"));
  failureUrl.searchParams.set("failure", "startup");
  await client.send("Page.navigate", { url: failureUrl.href });
  await waitFor(
    () => evaluate("document.querySelector('#bootMessage')?.textContent.includes('数据生成失败') === false"),
    "the startup loader before its failure signal"
  );
  writeFailurePayload({ reason: "initial_generation_failed", stage: "default_usage" });
  const malformedFailureRequests = coordinationRequests();
  await new Promise((resolve) => setTimeout(resolve, 1200));
  const malformedFailureState = await evaluate(`({
    message: document.querySelector('#bootMessage').textContent,
    appShown: document.querySelector('#app').classList.contains('show')
  })`);
  assert.equal(malformedFailureState.appShown, false);
  assert.notEqual(malformedFailureState.message, "数据生成失败，请重新启动");
  assert.ok(coordinationRequests() > malformedFailureRequests, "A malformed failure sidecar stopped polling.");
  writeFailure("default_usage", "startup-browser-smoke");
  await waitFor(
    () => evaluate("document.querySelector('#bootMessage')?.textContent === '数据生成失败，请重新启动'"),
    "the terminal startup failure signal"
  );
  const startupFailureRequests = coordinationRequests();
  await new Promise((resolve) => setTimeout(resolve, 1300));
  const startupFailureState = await evaluate(`({
    appShown: document.querySelector('#app').classList.contains('show'),
    loaderVisible: getComputedStyle(document.querySelector('#loader')).display !== 'none',
    message: document.querySelector('#bootMessage').textContent,
    failure: window.__GENERATION_FAILURE__ || null,
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.equal(startupFailureState.appShown, false);
  assert.equal(startupFailureState.loaderVisible, true);
  assert.equal(startupFailureState.message, "数据生成失败，请重新启动");
  assert.equal(startupFailureState.failure?.stage, "default_usage");
  assert.equal(startupFailureState.failure?.runId, "startup-browser-smoke");
  assert.equal(startupFailureState.bootError, null);
  assert.equal(coordinationRequests(), startupFailureRequests, "Polling continued after a terminal startup failure.");

  console.log(`BrowserSmoke.mjs: PASS (desktop ${desktopShot.bytes} B, mobile ${mobileShot.bytes} B)`);
}

try {
  if (process.argv[2] === "--real-generator") {
    if (!process.argv[3]) throw new Error("--real-generator requires a generator path.");
    await measureRealStartup(process.argv[3]);
  } else {
    await main();
  }
} finally {
  if (client) {
    try { await client.send("Browser.close"); } catch {}
    client.close();
  }
  if (browser && browser.exitCode === null) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    if (browser.exitCode === null) {
      spawnSync("taskkill.exe", ["/PID", String(browser.pid), "/T", "/F"], { stdio: "ignore" });
    }
  }
  if (generator && generator.exitCode === null) {
    spawnSync("taskkill.exe", ["/PID", String(generator.pid), "/T", "/F"], { stdio: "ignore" });
  }
  // Edge helpers can outlive the browser process and keep the profile open. Each carries
  // this run's unique --user-data-dir, so exactly those Edge processes are stopped.
  if (profile && profile.length >= 20) {
    spawnSync("powershell.exe", [
      "-NoProfile", "-NonInteractive", "-Command",
      "$profilePath = $env:AI_USAGE_EDGE_PROFILE; if (-not $profilePath -or $profilePath.Length -lt 20) { exit }; " +
        "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'msedge.exe' -and $_.CommandLine -and " +
        "$_.CommandLine.IndexOf($profilePath, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | " +
        "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
    ], { stdio: "ignore", timeout: 20000, env: { ...process.env, AI_USAGE_EDGE_PROFILE: profile } });
  }
  for (const directory of [work, profile, realStartupTemp]) {
    if (!directory) continue;
    // Edge's helper processes can hold profile files for a moment after the browser exits,
    // and a real-generator profile may cache a page built from real usage data.
    try { fs.rmSync(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); } catch {}
    if (fs.existsSync(directory)) console.warn(`BrowserSmoke.mjs: could not remove ${directory}`);
  }
}
