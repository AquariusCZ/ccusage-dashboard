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
  assert.deepEqual(visibleState.periods, ["30days"]);
  assert.equal(visibleState.bootError, null);
  assert.equal(visibleState.overflow, 0);
  assert.deepEqual(runtimeErrors, [], `Browser runtime errors: ${runtimeErrors.join(" | ")}`);
  assert.ok(
    visibleMilliseconds < budgetMilliseconds,
    `Real process-to-app.show took ${visibleMilliseconds} ms, above the ${budgetMilliseconds} ms budget. ${generatorOutput.join("")}`
  );
  console.log(`BrowserSmoke.mjs: REAL STARTUP PASS (process-to-app.show ${visibleMilliseconds} ms)`);
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

  const partialSnapshot = structuredClone(finalSnapshot);
  partialSnapshot.runId = "previous-browser-smoke";
  partialSnapshot.revision = 99;
  partialSnapshot.complete = false;
  partialSnapshot.periods = [defaultPeriod];
  partialSnapshot.reports = { [defaultPeriod]: partialSnapshot.reports[defaultPeriod] };
  partialSnapshot.limits.claudeQuota = { ok: false, reason: "loading" };
  partialSnapshot.limits.codexQuota = { ok: false, reason: "loading" };
  partialSnapshot.limits.codex = null;

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
  detailSnapshot.limits.codex = null;

  const expandedSnapshot = structuredClone(finalSnapshot);
  expandedSnapshot.revision = 3;
  expandedSnapshot.complete = false;
  expandedSnapshot.limits.claudeQuota = { ok: false, reason: "loading" };
  expandedSnapshot.limits.codexQuota = { ok: false, reason: "loading" };
  expandedSnapshot.limits.codex = null;
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
      bootError: window.__BOOT_ERROR__ || null,
      overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
    };
  })()`);
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
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
  })`);
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

  const staleIncompleteSnapshot = structuredClone(finalSnapshot);
  staleIncompleteSnapshot.runId = "stale-incomplete-browser-smoke";
  staleIncompleteSnapshot.revision = 1;
  staleIncompleteSnapshot.complete = false;
  staleIncompleteSnapshot.generationError = null;
  writeSnapshot(staleIncompleteSnapshot);
  const staleFailureUrl = pathToFileURL(path.join(work, "report.html"));
  staleFailureUrl.searchParams.set("failure", "stale-incomplete");
  await client.send("Page.navigate", { url: staleFailureUrl.href });
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'stale-incomplete-browser-smoke' && document.querySelector('#stamp')?.textContent.includes('更新中')"),
    "an existing incomplete snapshot before its terminal failure signal"
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
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.equal(staleFailureState.appShown, true);
  assert.equal(staleFailureState.loaderHidden, true);
  assert.ok(staleFailureState.stamp.includes("\u6570\u636e\u751f\u6210\u5931\u8d25\uff0c\u8bf7\u91cd\u65b0\u542f\u52a8"));
  assert.equal(staleFailureState.failure?.stage, "final_publish");
  assert.equal(staleFailureState.failure?.runId, "stale-incomplete-browser-smoke");
  assert.equal(staleFailureState.bootError, null);
  assert.equal(coordinationRequests(), staleFailureRequests, "Polling continued after a terminal failure over existing data.");

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
  for (const directory of [work, profile, realStartupTemp]) {
    if (!directory) continue;
    try { fs.rmSync(directory, { recursive: true, force: true }); } catch {}
  }
}
