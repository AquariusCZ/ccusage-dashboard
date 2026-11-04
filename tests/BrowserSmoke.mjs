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
// A temp profile would otherwise sign in to the Edge account of the Windows user and sync its
// extensions; one of those opened a welcome tab about 28 s in, which sent the page under test to
// the background, throttled its polling to once a second and stopped its animation frames.
const EDGE_ISOLATION = ["--disable-sync", "--disable-extensions"];
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
    "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", ...EDGE_ISOLATION,
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
  // The page is its own first frame; the first snapshot is the first real data it shows.
  const visibleState = await waitFor(
    () => evaluate(`(function () {
      if (!window.__DATA__) return null;
      return {
        period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
        complete: window.__DATA__.complete,
        periods: window.__DATA__.periods,
        bootError: window.__BOOT_ERROR__ || null,
        overflow: document.documentElement.scrollWidth - document.documentElement.offsetWidth
      };
    })()`),
    "the real dashboard's first snapshot",
    30000
  );
  const visibleMilliseconds = Date.now() - startedAt;
  const budgetMilliseconds = Number(process.env.AI_USAGE_STARTUP_BUDGET_MS || 25000);
  assert.equal(visibleState.period, "30days");
  assert.equal(visibleState.complete, false);
  assert.equal(visibleState.bootError, null);
  assert.equal(visibleState.overflow, 0);
  // The page opens on quota alone; the default period's usage follows once the boards
  // have handed over to the hero, which must stay a short beat after the readable revision.
  let readableAt = null;
  const usageState = await waitFor(
    () => evaluate(`(function () {
      if (!window.__DATA__ || !(window.__DATA__.periods || []).length) return null;
      return {
        periods: window.__DATA__.periods,
        revealed: !document.querySelector('#app').classList.contains('usage-pending')
      };
    })()`).then((state) => {
      if (state && readableAt === null) readableAt = Date.now();
      return state && state.revealed ? state : null;
    }),
    "the first usage revision",
    30000
  );
  const usageMilliseconds = Date.now() - startedAt;
  const handOverMilliseconds = Date.now() - readableAt;
  assert.ok(handOverMilliseconds < 1500, `Usage was revealed ${handOverMilliseconds} ms after its readable revision`);
  assert.equal(usageState.periods[0], "30days");
  assert.deepEqual(runtimeErrors, [], `Browser runtime errors: ${runtimeErrors.join(" | ")}`);
  assert.ok(
    usageMilliseconds < budgetMilliseconds,
    `Real process-to-usage took ${usageMilliseconds} ms, above the ${budgetMilliseconds} ms budget. ${generatorOutput.join("")}`
  );
  console.log(`BrowserSmoke.mjs: REAL STARTUP PASS (process-to-first-snapshot ${visibleMilliseconds} ms, process-to-usage ${usageMilliseconds} ms)`);
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
    "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", ...EDGE_ISOLATION,
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
  await client.send("Page.addScriptToEvaluateOnNewDocument", { source: `
    // Rows and cards that are closing stay in the DOM until they are gone; they are aria-hidden
    // and inert, so what the page shows is everything else.
    window.__shownText = function (selector) {
      var node = document.querySelector(selector);
      if (!node) return "";
      node = node.cloneNode(true);
      node.querySelectorAll("[data-leaving]").forEach(function (gone) { gone.remove(); });
      return node.textContent;
    };
    // The state of the page at the moment it first becomes visible.
    new MutationObserver(function (records, observer) {
      if (!document.documentElement || document.documentElement.hasAttribute("data-boot")) return;
      observer.disconnect();
      var seg = document.getElementById("periodSeg");
      var pressed = seg && seg.querySelector('button[aria-pressed="true"]');
      window.__firstFrame = {
        ark: document.fonts.check('12px "Ark Pixel 12px"'),
        fusion: document.fonts.check('12px "Fusion Pixel 12px"'),
        pill: !!pressed && seg.dataset.indicator === "1" && seg.style.getPropertyValue("--seg-w") === pressed.offsetWidth + "px"
      };
    }).observe(document, { subtree: true, attributes: true, attributeFilter: ["data-boot"] });
  ` });
  const reportUrl = pathToFileURL(path.join(work, "report.html"));
  reportUrl.searchParams.set("period", "all");
  reportUrl.searchParams.set("provider", "codex");
  await client.send("Page.navigate", { url: reportUrl.href });

  await waitFor(() => evaluate("getComputedStyle(document.querySelector('#app')).opacity === '1'"), "the page's first frame", 3000);
  // The page is its own first frame: shell, planned periods and the usage boards render
  // before any snapshot, and there is no full-screen loader to hide them. It shows complete:
  // text never lands after its box, and the pill is already under the pressed button.
  assert.deepEqual(await evaluate("window.__firstFrame"), { ark: true, fusion: true, pill: true }, "The first visible frame was not complete");
  const waitingState = await evaluate(`({
    shellVisible: getComputedStyle(document.querySelector('#app')).opacity === '1' &&
      getComputedStyle(document.querySelector('.topbar')).display !== 'none',
    pending: document.querySelector('#app').classList.contains('usage-pending'),
    waitVisible: getComputedStyle(document.querySelector('.usage-wait')).display !== 'none',
    boards: Array.from(document.querySelectorAll('#boards .board')).map((b) => b.dataset.p).join(','),
    planned: Array.from(document.querySelectorAll('#periodSeg [data-period]')).map((b) => b.dataset.period + (b.disabled ? '' : '!')).join(','),
    status: document.querySelector('#bootMessage').textContent,
    loader: Boolean(document.querySelector('#loader')),
    protocol: location.protocol,
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.equal(waitingState.shellVisible, true, "The page must be visible before its first snapshot");
  assert.equal(waitingState.pending, true);
  assert.equal(waitingState.waitVisible, true);
  assert.equal(waitingState.boards, "claude,codex", "A first launch shows the two collector boards every run has");
  assert.equal(waitingState.planned, "all,week,30days", "The launch period leads the planned, still disabled periods");
  assert.equal(waitingState.status, "读取额度与本地记录");
  assert.equal(waitingState.loader, false);
  assert.equal(waitingState.protocol, "file:");
  assert.equal(waitingState.bootError, null);

  writeSnapshot(quotaOnlySnapshot);
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.revision === 98 && document.querySelector('#app').classList.contains('usage-pending') && document.querySelectorAll('#boards .board').length === 3"),
    "the quota-only first revision before the reveal"
  );
  const quotaOnlyState = await evaluate(`({
    pending: document.querySelector('#app').classList.contains('usage-pending'),
    waitVisible: getComputedStyle(document.querySelector('.usage-wait')).display !== 'none',
    heroHidden: getComputedStyle(document.querySelector('.hero')).display === 'none',
    detailsHidden: getComputedStyle(document.querySelector('#details')).display === 'none',
    quotaCards: document.querySelectorAll('#quota .quota:not([data-leaving])').length,
    placeholders: document.querySelectorAll('#quota .is-placeholder').length,
    codexPlan: window.__shownText('#quota').includes('Pro'),
    boards: Array.from(document.querySelectorAll('#boards .board')).map((b) => b.dataset.p).join(','),
    remembered: JSON.parse(localStorage.getItem('ai-usage-ledger-prefs') || '{}').lastProviders,
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.offsetWidth
  })`);
  assert.equal(quotaOnlyState.pending, true);
  assert.equal(quotaOnlyState.waitVisible, true);
  assert.equal(quotaOnlyState.heroHidden, true);
  assert.equal(quotaOnlyState.detailsHidden, true);
  assert.equal(quotaOnlyState.quotaCards, 1, "Only the Codex card belongs to the codex filter.");
  assert.equal(quotaOnlyState.placeholders, 0, "The first answer replaces every placeholder");
  assert.equal(quotaOnlyState.codexPlan, true);
  assert.equal(quotaOnlyState.boards, "claude,codex,deepseek", "Boards follow the provider cards' order");
  assert.equal(quotaOnlyState.remembered, undefined, "A revision before the first report must not rewrite the remembered providers");
  assert.equal(quotaOnlyState.bootError, null);
  assert.equal(quotaOnlyState.overflow, 0);

  writeSnapshot(partialSnapshot);

  // Usage is revealed once the boards have finished and handed over to the hero.
  await waitFor(
    () => evaluate("window.__DATA__ && window.__DATA__.runId === 'previous-browser-smoke' && window.__DATA__.revision === 99 && !document.querySelector('#app').classList.contains('usage-pending')"),
    "the first progressive revision"
  );
  const partialState = await evaluate(`(function () {
    return {
      complete: window.__DATA__.complete,
      period: document.querySelector('[data-period][aria-pressed="true"]')?.dataset.period,
      provider: document.querySelector('[data-filter][aria-pressed="true"]')?.dataset.filter,
      updating: document.querySelector('#stamp').textContent.includes('\u66f4\u65b0\u4e2d'),
      quotaLoading: window.__shownText('#quota').includes('\u6b63\u5728\u83b7\u53d6\u989d\u5ea6'),
      usagePending: document.querySelector('#app').classList.contains('usage-pending'),
      heroShown: getComputedStyle(document.querySelector('.hero')).display !== 'none',
      waitHidden: getComputedStyle(document.querySelector('.usage-wait')).display === 'none',
      unironed: document.querySelectorAll('#boards .board:not(.ironed)').length,
      remembered: JSON.parse(localStorage.getItem('ai-usage-ledger-prefs') || '{}').lastProviders,
      bootError: window.__BOOT_ERROR__ || null,
      overflow: document.documentElement.scrollWidth - document.documentElement.offsetWidth
    };
  })()`);
  assert.deepEqual(partialState.remembered, ["claude", "codex", "deepseek"], "The providers a report carries are remembered for the next first frame");
  assert.equal(partialState.usagePending, false);
  assert.equal(partialState.heroShown, true);
  assert.equal(partialState.waitHidden, true, "The usage wait card must be gone once usage is revealed");
  assert.equal(partialState.unironed, 0, "Usage was revealed before every board was finished and ironed");
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
    () => evaluate("window.__DATA__ && window.__DATA__.revision === 2 && !document.querySelector('[data-period=\"week\"]').disabled && document.querySelector('[data-period=\"all\"]').disabled"),
    "the detail-focus usage revision"
  );
  const detailState = await evaluate(`({
    detailOpen: document.querySelector('#details details:nth-of-type(2)').open,
    detailFocused: document.activeElement === document.querySelector('#details details:nth-of-type(2) summary'),
    periods: document.querySelectorAll('[data-period]').length,
    weekReady: !document.querySelector('[data-period="week"]').disabled,
    allPending: document.querySelector('[data-period="all"]').disabled
  })`);
  assert.equal(detailState.detailOpen, true);
  assert.equal(detailState.detailFocused, true);
  assert.equal(detailState.periods, 3);
  assert.equal(detailState.weekReady, true);
  assert.equal(detailState.allPending, true);

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
    usageShown: !document.querySelector('#app').classList.contains('usage-pending'),
    tableShown: !document.querySelector('#trendTable').classList.contains('hide'),
    themePinned: Boolean(document.documentElement.dataset.cs),
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.offsetWidth
  })`);
  assert.equal(interactiveState.periods, 3);
  assert.equal(interactiveState.period, "all");
  assert.equal(interactiveState.periodFocused, defaultPeriod);
  assert.equal(interactiveState.provider, "codex");
  assert.equal(interactiveState.updating, true);
  assert.equal(interactiveState.usageShown, true);
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
    quotaLoaded: !window.__shownText('#quota').includes('\u6b63\u5728\u83b7\u53d6\u989d\u5ea6'),
    codexWindows: window.__shownText('#quota').includes('5 \u5c0f\u65f6\u989d\u5ea6') &&
      window.__shownText('#quota').includes('\u5468\u989d\u5ea6'),
    bootError: window.__BOOT_ERROR__ || null,
    overflow: document.documentElement.scrollWidth - document.documentElement.offsetWidth
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

  // What is under the quota row follows the row's own height: a filter change never throws it
  // past where it started and where it ends, and a card that goes and comes back straight
  // away leaves nothing behind. Measured from the top of the page: further down, the browser's
  // scroll anchoring cancels the movement and this could not see a bounce at all.
  const filterMotion = await evaluate(`(async function () {
    var original = document.querySelector('[data-filter][aria-pressed="true"]').dataset.filter;
    var hero = document.querySelector('.hero');
    var click = function (name) { document.querySelector('[data-filter="' + name + '"]').click(); };
    var pause = function (ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); };
    var scrolled = scrollY;
    scrollTo(0, 0);
    await pause(50);
    var watch = function (name) {
      return new Promise(function (resolve) {
        var start = hero.getBoundingClientRect().top, seen = [], began = performance.now();
        click(name);
        (function frame() {
          seen.push(hero.getBoundingClientRect().top);
          if (performance.now() - began < 450) requestAnimationFrame(frame);
          else resolve({ to: name, start: start, end: seen[seen.length - 1], min: Math.min.apply(null, seen), max: Math.max.apply(null, seen) });
        })();
      });
    };
    var hops = [];
    for (var name of ['all', 'claude', 'codex', 'claude', 'deepseek', 'all']) hops.push(await watch(name));
    click('claude');
    await pause(40);
    click('all');
    await pause(450);
    var cards = Array.from(document.querySelectorAll('#quota > .quota'));
    var state = {
      keys: cards.map(function (c) { return c.dataset.q; }).join(','),
      leaving: document.querySelectorAll('#quota [data-leaving]').length,
      visible: cards.every(function (c) { return getComputedStyle(c).opacity === '1' && getComputedStyle(c).position === 'static' && !c.inert; })
    };
    click(original);
    await pause(450);
    scrollTo(0, scrolled);
    return { hops: hops, state: state };
  })()`);
  filterMotion.hops.forEach((hop) => {
    const low = Math.min(hop.start, hop.end) - 1;
    const high = Math.max(hop.start, hop.end) + 1;
    assert.ok(hop.min >= low && hop.max <= high, `The content under the quota row bounced: ${JSON.stringify(hop)}`);
  });
  assert.deepEqual(filterMotion.state, { keys: "claude,codex", leaving: 0, visible: true }, "A card that came straight back left residue");

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
  assert.equal(await evaluate("document.documentElement.scrollWidth - document.documentElement.offsetWidth"), 0);
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
    var pricedCard = window.__shownText('#quota .quota:not([data-leaving])');
    window.__DATA__ = ${JSON.stringify(recordedSnapshot)};
    window.__render__();
    var text = window.__shownText('#quota');
    var claudeCard = window.__shownText('#quota .quota:not([data-leaving])');
    return {
      desktopSource: text.includes('Claude \u684c\u9762\u7248'),
      loginHint: text.includes('claude auth login'),
      unpricedWindow: claudeCard.includes('\u672a\u5b9a\u4ef7') && !claudeCard.includes('$0.00'),
      pricedWindow: pricedCard.includes('$12.50') && !pricedCard.includes('\u672a\u5b9a\u4ef7'),
      claudeMeters: document.querySelectorAll('#quota .quota[data-q="claude"] .q-slot:not([data-leaving]) .meter-row:not(.is-reset)').length,
      codexReset: text.includes('\u5df2\u91cd\u7f6e'),
      codexStale: text.includes('\u672c\u5730\u8bb0\u5f55'),
      overflow: document.documentElement.scrollWidth - document.documentElement.offsetWidth
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

  // A count still running must not write its figure into a row that has since rolled over,
  // and a rolled-over window has no remainder for the card's head to claim.
  const countBase = structuredClone(recordedSnapshot);
  const countAt = (revision, utilization, resetsAt) => {
    const snapshot = structuredClone(countBase);
    snapshot.revision = revision;
    snapshot.limits.claudeQuota.fiveHour = { utilization, resetsAt };
    return snapshot;
  };
  const countFuture = new Date(Date.now() + 2 * 3600000).toISOString();
  const countPast = new Date(Date.now() - 60000).toISOString();
  const countState = await evaluate(`(async function () {
    var show = function (snapshot) { window.__DATA__ = snapshot; window.__render__(); };
    var pause = function (ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); };
    show(${JSON.stringify(countAt(2, 20, countFuture))});
    await pause(500);
    show(${JSON.stringify(countAt(3, 95, countFuture))});
    await pause(40);
    show(${JSON.stringify(countAt(4, 95, countPast))});
    await pause(900);
    var card = document.querySelector('#quota .quota[data-q="claude"]');
    return { reset: card.querySelector('.meter-reset').textContent, note: card.querySelector('.quota-note').textContent };
  })()`);
  assert.deepEqual(countState, { reset: "\u5df2\u91cd\u7f6e", note: "" }, JSON.stringify(countState));

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
      var cells = Array.prototype.slice.call(document.querySelectorAll('#quota .quota[data-q="claude"] .q-slot:not([data-leaving]) .prov-stats div'));
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
    state.overflow = document.documentElement.scrollWidth - document.documentElement.offsetWidth;
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

  // A Free plan has no metered window, so its quota card must not be part of the page;
  // a metered plan must still render it. This is the single decision the card exists for.
  const freePlanState = await evaluate(`(function () {
    var free = JSON.parse(JSON.stringify(${JSON.stringify(finalSnapshot)}));
    free.runId = 'free-plan-browser-smoke';
    free.revision = 90;
    free.complete = true;
    free.limits.codexQuota = { ok: false, reason: 'official_account' };
    free.limits.codex = {
      ok: true, planType: 'free', source: 'app_server', stale: false,
      observedAt: new Date().toISOString(),
      primary: { used_percent: 0, window_minutes: 43200, resets_at: Math.floor(Date.now() / 1000) + 86400 },
      secondary: null
    };
    window.__DATA__ = free;
    window.__render__();
    var card = function (key) { return document.querySelector('#quota .quota[data-q="' + key + '"]:not([data-leaving])'); };
    var seen = null;
    try { seen = JSON.parse(localStorage.getItem('ai-usage-ledger-prefs') || '{}').lastQuota; } catch (e) {}
    var state = { codex: Boolean(card('codex')), claude: Boolean(card('claude')), seen: seen };
    // A local record shown only until the live answer lands: an old session's windows must not
    // bring the card back for a moment, and the record is labelled without a row of its own.
    var refreshing = JSON.parse(JSON.stringify(free));
    refreshing.revision = 91;
    refreshing.complete = false;
    refreshing.limits.claudeQuota = {
      ok: true, reason: null, source: 'cache', stale: true, staleReason: 'loading', cachedAt: new Date(Date.now() - 600000).toISOString(),
      fiveHour: { utilization: 22, resetsAt: new Date(Date.now() + 3600000).toISOString() },
      sevenDay: { utilization: 7, resetsAt: new Date(Date.now() + 86400000).toISOString() }, limits: []
    };
    refreshing.limits.codex = {
      ok: true, reason: null, source: 'session', stale: true, staleReason: 'loading', planType: null,
      observedAt: new Date(Date.now() - 9 * 86400000).toISOString(),
      primary: { used_percent: 86, window_minutes: 10080, resets_at: new Date(Date.now() - 2 * 86400000).toISOString() }, secondary: null
    };
    window.__DATA__ = refreshing;
    window.__render__();
    state.refreshingCodex = Boolean(card('codex'));
    state.refreshingRow = Boolean(card('claude').querySelector('.q-slot:not([data-leaving]) .stale'));
    state.refreshingNote = card('claude').querySelector('.quota-note').textContent.indexOf('\u5237\u65b0\u4e2d') === 0;
    return state;
  })()`);
  assert.equal(freePlanState.codex, false, "A Free plan must not render a Codex quota card");
  assert.equal(freePlanState.claude, true, "The Claude card stays");
  assert.deepEqual(freePlanState.seen, { codex: false }, "The Free answer is remembered for the next launch");
  assert.equal(freePlanState.refreshingCodex, false, "A local record on its way to being replaced brought the Codex card back");
  assert.equal(freePlanState.refreshingRow, false, "A refreshing record took a row of its own");
  assert.equal(freePlanState.refreshingNote, true, "A refreshing record was not labelled");

  const navigateFresh = async (name, params = {}) => {
    const url = pathToFileURL(path.join(work, "report.html"));
    url.searchParams.set("scenario", name);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    await client.send("Page.navigate", { url: url.href });
  };
  const revealed = (runId) => `window.__DATA__?.runId === '${runId}' && !document.querySelector('#app').classList.contains('usage-pending')`;
  // A phone docks the wait card to the viewport bottom, which would hide any slot movement.
  await client.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });

  // The quota row keeps the box it had last launch, so the usage slot does not move when
  // the first answer replaces the placeholder - including a desktop-app record that adds
  // its stale line and sign-in hint.
  const stableQuota = structuredClone(quotaOnlySnapshot);
  stableQuota.runId = "stable-browser-smoke";
  stableQuota.revision = 1;
  stableQuota.limits.claudeQuota = {
    ok: true, reason: null, source: "claude_desktop", stale: true, staleReason: "no_credentials",
    cachedAt: new Date(Date.now() - 20 * 60000).toISOString(),
    fiveHour: { utilization: 22, resetsAt: null }, sevenDay: { utilization: 7, resetsAt: null }, limits: []
  };
  writeSnapshot(stableQuota);
  await navigateFresh("stable-first", { provider: "claude" });
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'stable-browser-smoke' && !document.querySelector('#quota .is-placeholder')"),
    "the launch that records the quota box"
  );
  await new Promise((resolve) => setTimeout(resolve, 400));
  fs.unlinkSync(dataPath);
  await navigateFresh("stable-second", { provider: "claude" });
  await waitFor(
    () => evaluate("Boolean(document.querySelector('#quota .is-placeholder')) && document.fonts.status === 'loaded'"),
    "the next launch's remembered placeholder"
  );
  await new Promise((resolve) => setTimeout(resolve, 200));
  const slotBefore = await evaluate("Math.round(document.querySelector('.usage-wait').getBoundingClientRect().top)");
  const trackSlot = () => evaluate(`(function () {
    var track = window.__slotTrack = [];
    (function frame() { track.push(document.querySelector('.usage-wait').getBoundingClientRect().top); requestAnimationFrame(frame); })();
  })()`);
  const slotTravel = () => evaluate("Math.max.apply(null, window.__slotTrack) - Math.min.apply(null, window.__slotTrack)");
  await trackSlot();
  writeSnapshot(stableQuota);
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'stable-browser-smoke' && !document.querySelector('#quota .is-placeholder')"),
    "the next launch's first quota answer"
  );
  await new Promise((resolve) => setTimeout(resolve, 300));
  const slotAfter = await evaluate("Math.round(document.querySelector('.usage-wait').getBoundingClientRect().top)");
  assert.equal(slotAfter, slotBefore, "The usage slot moved when the remembered quota answer replaced its placeholder");
  assert.ok(await slotTravel() <= 1, "The usage slot moved on its way through the remembered quota answer");

  // A record shown only until the answer lands holds the same box, even when that answer then
  // keeps the record: a read that keeps failing must not shrink and regrow the card each launch.
  fs.unlinkSync(dataPath);
  await navigateFresh("stable-refreshing", { provider: "claude" });
  await waitFor(
    () => evaluate("Boolean(document.querySelector('#quota .is-placeholder')) && document.fonts.status === 'loaded'"),
    "the remembered placeholder before a refreshing record"
  );
  await new Promise((resolve) => setTimeout(resolve, 200));
  await trackSlot();
  const refreshingQuota = structuredClone(stableQuota);
  refreshingQuota.runId = "stable-refreshing-browser-smoke";
  refreshingQuota.limits.claudeQuota = { ...stableQuota.limits.claudeQuota, staleReason: "loading" };
  writeSnapshot(refreshingQuota);
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'stable-refreshing-browser-smoke' && document.querySelector('#quota .quota[data-q=\"claude\"]').classList.contains('is-refreshing')"),
    "the refreshing record"
  );
  await new Promise((resolve) => setTimeout(resolve, 300));
  const keptQuota = structuredClone(stableQuota);
  keptQuota.runId = "stable-refreshing-browser-smoke";
  keptQuota.revision = 2;
  writeSnapshot(keptQuota);
  await waitFor(() => evaluate("window.__DATA__?.revision === 2 && !document.querySelector('#quota .is-refreshing')"), "the record that stays");
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.ok(await slotTravel() <= 1, "A refreshing record that stays moved the usage slot");

  // A store written by an older build or another local page must not break the page.
  await evaluate("localStorage.setItem('ai-usage-ledger-prefs', JSON.stringify({ quotaShape: 7, quota: 'x', view: [], lastQuota: 'y', lastProviders: 'z' }))");
  const tamperedSnapshot = structuredClone(partialSnapshot);
  tamperedSnapshot.runId = "tampered-browser-smoke";
  writeSnapshot(tamperedSnapshot);
  await navigateFresh("tampered-prefs");
  await waitFor(() => evaluate(revealed("tampered-browser-smoke")), "a reveal over a tampered preference store");
  assert.equal(await evaluate("window.__BOOT_ERROR__ || null"), null, "A tampered preference store broke the page");

  // A script error reports itself, but readable usage is still revealed.
  fs.unlinkSync(dataPath);
  await navigateFresh("script-error");
  await waitFor(() => evaluate("Boolean(document.querySelector('#boards .board'))"), "the boards before a script error");
  await evaluate("setTimeout(function () { throw new Error('browser-smoke transient'); }, 0)");
  await new Promise((resolve) => setTimeout(resolve, 300));
  const scriptErrorSnapshot = structuredClone(partialSnapshot);
  scriptErrorSnapshot.runId = "script-error-browser-smoke";
  writeSnapshot(scriptErrorSnapshot);
  await waitFor(() => evaluate(revealed("script-error-browser-smoke")), "a reveal after a script error");
  assert.ok(String(await evaluate("window.__BOOT_ERROR__ && window.__BOOT_ERROR__.message")).includes("browser-smoke transient"));

  // A failure inside the first frame's own measuring must not leave the page hidden for good:
  // the page script is past defining window.__show__ when this starts to throw.
  const breakMeasure = await client.send("Page.addScriptToEvaluateOnNewDocument", {
    source: "(function () { var real = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetLeft'); Object.defineProperty(HTMLElement.prototype, 'offsetLeft', { configurable: true, get: function () { if (window.__show__) throw new Error('browser-smoke gate'); return real.get.call(this); } }); })();"
  });
  await navigateFresh("gate-fault");
  await waitFor(
    () => evaluate("!document.documentElement.hasAttribute('data-boot') && getComputedStyle(document.querySelector('#app')).opacity === '1'"),
    "the page despite a failure in its first frame", 3000
  );
  assert.ok(String(await evaluate("window.__BOOT_ERROR__ && window.__BOOT_ERROR__.message")).includes("browser-smoke gate"));
  await client.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: breakMeasure.identifier });

  // A new run that has no usage yet sends the page back to waiting, from fresh boards.
  const runA = structuredClone(partialSnapshot);
  runA.runId = "run-a-browser-smoke";
  writeSnapshot(runA);
  await navigateFresh("run-change");
  await waitFor(() => evaluate(revealed("run-a-browser-smoke")), "the first run's reveal");
  const runB = structuredClone(quotaOnlySnapshot);
  runB.runId = "run-b-browser-smoke";
  runB.revision = 1;
  runB.progress = { done: 1, total: 3, stage: "period", period: defaultPeriod };
  // Its early list lacks DeepSeek; the fresh boards still start from what the last run
  // produced instead of dropping a board for an early list.
  runB.providers = ["claude", "codex"];
  writeSnapshot(runB);
  await waitFor(
    () => evaluate("window.__DATA__?.runId === 'run-b-browser-smoke' && document.querySelector('#app').classList.contains('usage-pending')"),
    "the next run's wait"
  );
  await new Promise((resolve) => setTimeout(resolve, 500));
  const runChangeState = await evaluate(`({
    waitVisible: getComputedStyle(document.querySelector('.usage-wait')).display !== 'none',
    ironed: document.querySelectorAll('#boards .board.ironed').length,
    boards: Array.from(document.querySelectorAll('#boards .board')).map((b) => b.dataset.p).join(','),
    claude: document.querySelector('#boards .board[data-p="claude"]')?.dataset.state
  })`);
  assert.equal(runChangeState.waitVisible, true);
  assert.equal(runChangeState.boards, "claude,codex,deepseek", "A new run's boards did not start from the remembered providers");
  assert.equal(runChangeState.ironed, 1, "Only the startup board of the next run is finished");
  assert.equal(runChangeState.claude, "run");

  // A run's quota-only revisions used to list only CodeBurn's pair even when the run had
  // DeepSeek rows; its first report then added DeepSeek. While usage waits the boards only
  // gain one, so the DeepSeek board is built at most once and never withdrawn; its filter
  // follows the boards until the reveal and the reports after it. Only a revision with a
  // report touches the remembered providers, and only the final one may drop one.
  const pair = ["claude", "codex"], withDeepSeek = ["claude", "codex", "deepseek"];
  const providerRun = (runId, early, late) => {
    const shape = (snapshot, providers) => {
      snapshot.runId = runId;
      snapshot.providers = providers;
      if (!providers.includes("deepseek")) {
        for (const slot of Object.values(snapshot.reports)) delete slot.deepseek;
      }
      return snapshot;
    };
    const step = (base, revision, done, providers) => shape(Object.assign(structuredClone(base), {
      revision, complete: false, progress: { done, total: 3, stage: "period", period: defaultPeriod }
    }), providers);
    return [
      step(quotaOnlySnapshot, 1, 1, early),
      step(quotaOnlySnapshot, 2, 2, early),
      step(partialSnapshot, 3, 3, late),
      shape(Object.assign(structuredClone(finalSnapshot), { revision: 4 }), late)
    ];
  };
  const playProviderRun = async (name, seed, snapshots, afterRevision = async () => {}) => {
    const seedScript = seed
      ? `localStorage.setItem('ai-usage-ledger-prefs', ${JSON.stringify(JSON.stringify(seed))});`
      : "localStorage.removeItem('ai-usage-ledger-prefs');";
    const watcher = await client.send("Page.addScriptToEvaluateOnNewDocument", {
      source: `(function () {
        try { ${seedScript} } catch (e) {}
        var watch = window.__providerWatch = { added: 0, removed: 0, boards: [], picker: [], label: [], remembered: [] };
        var setItem = Storage.prototype.setItem;
        Storage.prototype.setItem = function (key, value) {
          if (key === 'ai-usage-ledger-prefs') {
            try { watch.remembered.push(JSON.parse(value).lastProviders || null); } catch (e) {}
          }
          return setItem.apply(this, arguments);
        };
        function deepSeekBoard(node) { return node.nodeType === 1 && node.matches('.board[data-p="deepseek"]'); }
        function note(list, value) {
          var last = list[list.length - 1];
          if (!last || last.value !== value) list.push({ value: value, revision: window.__DATA__ ? window.__DATA__.revision : 0 });
        }
        new MutationObserver(function (records) {
          records.forEach(function (record) {
            record.addedNodes.forEach(function (node) { if (deepSeekBoard(node)) watch.added += 1; });
            record.removedNodes.forEach(function (node) { if (deepSeekBoard(node)) watch.removed += 1; });
          });
          // States are read once the page has drawn its first frame (the boards exist).
          if (!document.querySelector('#boards .board')) return;
          note(watch.boards, Array.prototype.map.call(document.querySelectorAll('#boards .board'), function (b) { return b.dataset.p; }).join(','));
          note(watch.picker, document.querySelector('[data-filter="deepseek"]').hidden);
          note(watch.label, document.getElementById('waitLabel').textContent);
        }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['hidden'] });
      })();`
    });
    try {
      if (fs.existsSync(dataPath)) fs.unlinkSync(dataPath);
      await navigateFresh(name);
      await waitFor(() => evaluate("document.querySelectorAll('#boards .board').length > 0"), `the ${name} first frame`);
      for (const snapshot of snapshots) {
        writeSnapshot(snapshot);
        await waitFor(
          () => evaluate(`window.__DATA__?.runId === '${snapshot.runId}' && window.__DATA__.revision === ${snapshot.revision}`),
          `the ${name} revision ${snapshot.revision}`
        );
        await afterRevision(snapshot);
        // A real quota-only revision stays on screen for about a second.
        if (!snapshot.periods.length) await new Promise((resolve) => setTimeout(resolve, 400));
        else await waitFor(() => evaluate(revealed(snapshot.runId)), `the ${name} reveal`);
      }
      return await evaluate(`({
        watch: window.__providerWatch,
        picker: !document.querySelector('[data-filter="deepseek"]').hidden,
        pickerDisplay: getComputedStyle(document.querySelector('[data-filter="deepseek"]')).display,
        card: Boolean(document.querySelector('#split .prov[data-p="deepseek"]')),
        board: Boolean(document.querySelector('#boards .board[data-p="deepseek"]')),
        pressed: document.querySelector('[data-filter][aria-pressed="true"]')?.dataset.filter,
        focused: document.activeElement?.dataset?.filter || null,
        urlProvider: new URL(location.href).searchParams.get('provider'),
        quotaCards: document.querySelectorAll('#quota .quota:not([data-leaving])').length,
        bootError: window.__BOOT_ERROR__ || null
      })`);
    } finally {
      await client.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: watcher.identifier });
    }
  };
  // Every write of the shared preference store carries an allowed list, and the last one
  // is what the next launch starts from.
  const remembers = (state, allowed, last) => {
    const writes = state.watch.remembered.map((value) => JSON.stringify(value));
    return writes.length > 0 && writes[writes.length - 1] === JSON.stringify(last) &&
      writes.every((value) => allowed.some((list) => value === JSON.stringify(list)));
  };

  // A machine without DeepSeek keeps the two-provider page it has always had.
  const pairOnly = await playProviderRun("provider-pair", { lastProviders: pair }, providerRun("provider-pair-browser-smoke", pair, pair));
  assert.equal(pairOnly.bootError, null);
  assert.deepEqual(pairOnly.watch.boards, [{ value: "claude,codex", revision: 0 }]);
  assert.equal(pairOnly.watch.added, 0);
  assert.deepEqual(pairOnly.watch.picker, [{ value: true, revision: 0 }]);
  assert.equal(pairOnly.watch.label.length, 1, JSON.stringify(pairOnly.watch.label));
  assert.equal(pairOnly.picker, false);
  assert.equal(pairOnly.pickerDisplay, "none", "A hidden filter button was still displayed");
  assert.equal(pairOnly.card, false);
  assert.ok(remembers(pairOnly, [pair], pair), JSON.stringify(pairOnly.watch.remembered));

  // A first launch learns DeepSeek from the first report: one new board, one new filter.
  const firstLaunch = await playProviderRun("provider-first", null, providerRun("provider-first-browser-smoke", pair, withDeepSeek));
  assert.equal(firstLaunch.bootError, null);
  assert.deepEqual(firstLaunch.watch.boards,
    [{ value: "claude,codex", revision: 0 }, { value: "claude,codex,deepseek", revision: 3 }], JSON.stringify(firstLaunch.watch));
  assert.equal(firstLaunch.watch.added, 1, "The DeepSeek board was built more than once");
  assert.equal(firstLaunch.watch.removed, 0, "The DeepSeek board was withdrawn mid-run");
  assert.deepEqual(firstLaunch.watch.picker,
    [{ value: true, revision: 0 }, { value: false, revision: 3 }], "The DeepSeek filter did not appear exactly once with its report");
  assert.deepEqual(firstLaunch.watch.label.map((entry) => entry.revision), [0, 3], JSON.stringify(firstLaunch.watch.label));
  assert.equal(firstLaunch.picker, true, "The DeepSeek filter is missing once its report is shown");
  assert.equal(firstLaunch.card, true);
  assert.ok(remembers(firstLaunch, [null, withDeepSeek], withDeepSeek), JSON.stringify(firstLaunch.watch.remembered));

  // A returning reader keeps the DeepSeek board and filter from the first frame on.
  const returning = await playProviderRun("provider-returning", { lastProviders: withDeepSeek }, providerRun("provider-returning-browser-smoke", pair, withDeepSeek));
  assert.equal(returning.bootError, null);
  assert.deepEqual(returning.watch.boards, [{ value: "claude,codex,deepseek", revision: 0 }], `The boards changed while usage waited: ${JSON.stringify(returning.watch.boards)}`);
  assert.equal(returning.watch.added, 1, "The DeepSeek board was built more than once");
  assert.equal(returning.watch.removed, 0, "The DeepSeek board was withdrawn mid-run");
  assert.equal(returning.board, true);
  assert.deepEqual(returning.watch.picker, [{ value: false, revision: 0 }], `The DeepSeek filter was hidden mid-run: ${JSON.stringify(returning.watch.picker)}`);
  assert.equal(returning.watch.label.length, 1, `The wait label changed while usage waited: ${JSON.stringify(returning.watch.label)}`);
  assert.equal(returning.picker, true);
  assert.equal(returning.card, true);
  assert.ok(remembers(returning, [withDeepSeek], withDeepSeek), `A revision before the first report rewrote the remembered providers: ${JSON.stringify(returning.watch.remembered)}`);

  // A remembered DeepSeek this run no longer has (its rows were deleted) keeps its board
  // until the reveal and leaves with the wait card. A DeepSeek filter chosen while waiting
  // falls back to all at the reveal: pressed button, focus, URL and quota row follow, and
  // the final revision remembers the exact list.
  const withdrawn = await playProviderRun("provider-withdrawn", { lastProviders: withDeepSeek },
    providerRun("provider-withdrawn-browser-smoke", pair, pair), async (snapshot) => {
      if (snapshot.revision !== 1) return;
      await evaluate("(function () { var b = document.querySelector('[data-filter=\"deepseek\"]'); b.focus(); b.click(); })()");
    });
  assert.equal(withdrawn.bootError, null);
  assert.deepEqual(withdrawn.watch.boards, [{ value: "claude,codex,deepseek", revision: 0 }], JSON.stringify(withdrawn.watch.boards));
  assert.equal(withdrawn.watch.removed, 0, "A remembered board was withdrawn while usage waited");
  assert.deepEqual(withdrawn.watch.picker, [{ value: false, revision: 0 }, { value: true, revision: 3 }], JSON.stringify(withdrawn.watch.picker));
  assert.equal(withdrawn.card, false);
  assert.equal(withdrawn.pressed, "all", "The withdrawn DeepSeek filter did not fall back to all");
  assert.equal(withdrawn.focused, "all", "Focus was lost with the hidden DeepSeek filter");
  assert.equal(withdrawn.urlProvider, null, "The URL kept the withdrawn DeepSeek filter");
  assert.ok(withdrawn.quotaCards >= 1, "The quota row was not redrawn for the fallback filter");
  assert.ok(remembers(withdrawn, [withDeepSeek, pair], pair), JSON.stringify(withdrawn.watch.remembered));

  // With reduced motion the hand-over is a plain swap: no view transition, no wait.
  await client.send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-color-scheme", value: "light" }, { name: "prefers-reduced-motion", value: "reduce" }]
  });
  const countTransitions = await client.send("Page.addScriptToEvaluateOnNewDocument", {
    source: "window.__vtCalls = 0; if (document.startViewTransition) { var vt = document.startViewTransition.bind(document); document.startViewTransition = function (cb) { window.__vtCalls += 1; return vt(cb); }; }"
  });
  const reducedSnapshot = structuredClone(partialSnapshot);
  reducedSnapshot.runId = "reduced-browser-smoke";
  writeSnapshot(reducedSnapshot);
  await navigateFresh("reduced-motion");
  await waitFor(() => evaluate(revealed("reduced-browser-smoke")), "a reduced-motion reveal");
  assert.equal(await evaluate("window.__vtCalls"), 0, "Reduced motion still ran a view transition");
  const reducedAnswer = await evaluate(`(function () {
    var next = JSON.parse(JSON.stringify(window.__DATA__));
    next.revision += 1;
    next.limits.claudeQuota = {
      ok: true, reason: null, source: 'oauth', limits: [],
      fiveHour: { utilization: 91, resetsAt: new Date(Date.now() + 3600000).toISOString() },
      sevenDay: { utilization: 7, resetsAt: new Date(Date.now() + 86400000).toISOString() }
    };
    window.__DATA__ = next;
    window.__render__();
    return {
      scripted: document.getAnimations().filter(function (a) { return a.constructor === Animation; }).length,
      figure: document.querySelector('#quota .quota[data-q="claude"] .meter-pct').textContent,
      leaving: document.querySelectorAll('#quota [data-leaving]').length
    };
  })()`);
  assert.deepEqual(reducedAnswer, { scripted: 0, figure: "91%", leaving: 0 }, "Reduced motion still animated a quota answer");
  await client.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: countTransitions.identifier });
  await client.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }] });

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
    await evaluate("window.__shownText('#quota .quota:not([data-leaving])').includes('计算中')"),
    true,
    "An incomplete run without blocks did not hold the window row."
  );
  writeFailure("default_usage", "different-browser-smoke", "partial_generation_failed");
  await waitFor(
    () => evaluate("window.__GENERATION_FAILURE__?.runId === 'different-browser-smoke'"),
    "the page reading a failure signal from another run"
  );
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
    usageShown: !document.querySelector('#app').classList.contains('usage-pending'),
    waitHidden: getComputedStyle(document.querySelector('.usage-wait')).display === 'none',
    stamp: document.querySelector('#stamp').textContent,
    failure: window.__GENERATION_FAILURE__ || null,
    bootError: window.__BOOT_ERROR__ || null,
    windowRow: window.__shownText('#quota .quota:not([data-leaving])').includes('窗口成本')
  })`);
  assert.equal(staleFailureState.windowRow, false, "A terminal failure left the window row placeholder.");
  assert.equal(staleFailureState.usageShown, true, "Readable usage stays shown after a later terminal failure");
  assert.equal(staleFailureState.waitHidden, true);
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
    wait: document.querySelector('#bootMessage').textContent,
    waitVisible: getComputedStyle(document.querySelector('.usage-wait')).display !== 'none',
    quotaCards: document.querySelectorAll('#quota .quota:not([data-leaving])').length,
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.ok(quotaFailureState.stamp.includes("数据生成失败"));
  assert.ok(quotaFailureState.wait.includes("读取失败"));
  assert.equal(quotaFailureState.waitVisible, true);
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
    "the startup page before its failure signal"
  );
  // The first frame is interactive: a filter change before any snapshot only re-draws
  // what is already known, and must not be treated as a broken page.
  const preSnapshotFilter = await evaluate(`(function () {
    document.querySelector('[data-filter="codex"]').click();
    var codexLabel = document.querySelector('#waitLabel').textContent;
    document.querySelector('[data-filter="all"]').click();
    return {
      codexLabel: codexLabel,
      allLabel: document.querySelector('#waitLabel').textContent,
      placeholders: document.querySelectorAll('#quota .is-placeholder').length,
      bootError: window.__BOOT_ERROR__ || null
    };
  })()`);
  assert.equal(preSnapshotFilter.bootError, null, "A filter click before the first snapshot broke the page");
  assert.ok(preSnapshotFilter.codexLabel.startsWith("Codex"));
  assert.ok(preSnapshotFilter.allLabel.includes("合计"));
  assert.ok(preSnapshotFilter.placeholders >= 1, "The remembered Claude quota card holds its place");
  writeFailurePayload({ reason: "initial_generation_failed", stage: "default_usage" });
  const malformedFailureRequests = coordinationRequests();
  await new Promise((resolve) => setTimeout(resolve, 1200));
  const malformedFailureState = await evaluate(`({
    message: document.querySelector('#bootMessage').textContent,
    failed: document.querySelector('.usage-wait').classList.contains('failed')
  })`);
  assert.equal(malformedFailureState.failed, false);
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
    waitVisible: getComputedStyle(document.querySelector('.usage-wait')).display !== 'none',
    failed: document.querySelector('.usage-wait').classList.contains('failed'),
    stamp: document.querySelector('#stamp').textContent,
    quotaNote: document.querySelector('#quota .is-placeholder .quota-note')?.textContent || '',
    message: document.querySelector('#bootMessage').textContent,
    failure: window.__GENERATION_FAILURE__ || null,
    bootError: window.__BOOT_ERROR__ || null
  })`);
  assert.equal(startupFailureState.waitVisible, true);
  assert.equal(startupFailureState.failed, true);
  assert.equal(startupFailureState.stamp, "数据生成失败");
  assert.equal(startupFailureState.quotaNote, "未读取", "Placeholders must stop saying they are reading");
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
