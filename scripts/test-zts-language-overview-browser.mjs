#!/usr/bin/env node

import { accessSync, constants, existsSync } from "node:fs";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const delay = (milliseconds) => new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function executableOnPath(name) {
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    if (!directory) continue;
    const candidate = join(directory, name);
    try {
      accessSyncExecutable(candidate);
      return candidate;
    } catch (_) {
      // Try the next PATH entry.
    }
  }
  return null;
}

function accessSyncExecutable(path) {
  accessSync(path, constants.X_OK);
}

function chromeCandidates() {
  const configured = process.env.CHROME_BIN ? [process.env.CHROME_BIN] : [];
  const platformCandidates = process.platform === "darwin"
    ? [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
      ]
    : process.platform === "win32"
      ? [
          join(process.env.PROGRAMFILES ?? "", "Google/Chrome/Application/chrome.exe"),
          join(process.env["PROGRAMFILES(X86)"] ?? "", "Google/Chrome/Application/chrome.exe"),
        ]
      : ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser"];
  const pathCandidates = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
    .map(executableOnPath)
    .filter(Boolean);
  return [...configured, ...platformCandidates, ...pathCandidates].filter(Boolean);
}

async function findChrome() {
  const candidates = [...new Set(chromeCandidates())];
  for (const candidate of candidates) {
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch (_) {
      // Continue until an executable candidate is found.
    }
  }
  throw new Error(
    `Chrome or Chromium is required. Set CHROME_BIN to an executable path. Tried: ${candidates.join(", ") || "none"}`,
  );
}

class CdpClient {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    this.socket = null;
  }

  async connect() {
    assert(typeof WebSocket === "function", "Node with built-in WebSocket support is required");
    const socket = new WebSocket(this.url);
    this.socket = socket;
    await new Promise((resolveOpen, rejectOpen) => {
      socket.addEventListener("open", resolveOpen, { once: true });
      socket.addEventListener("error", () => rejectOpen(new Error(`could not connect to ${this.url}`)), { once: true });
    });
    socket.addEventListener("message", (event) => this.handleMessage(String(event.data)));
    socket.addEventListener("close", () => {
      for (const { reject } of this.pending.values()) reject(new Error("Chrome DevTools connection closed"));
      this.pending.clear();
    });
  }

  handleMessage(text) {
    const message = JSON.parse(text);
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message}`));
      else pending.resolve(message.result ?? {});
      return;
    }
    for (const listener of this.listeners.get(message.method) ?? []) {
      listener(message.params ?? {}, message.sessionId);
    }
  }

  call(method, params = {}, sessionId = undefined) {
    assert(this.socket?.readyState === WebSocket.OPEN, "Chrome DevTools connection is not open");
    const id = this.nextId++;
    const message = { id, method, params };
    if (sessionId) message.sessionId = sessionId;
    this.socket.send(JSON.stringify(message));
    return new Promise((resolveCall, rejectCall) => {
      this.pending.set(id, { resolve: resolveCall, reject: rejectCall, method });
    });
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
  }

  close() {
    this.socket?.close();
  }
}

class BrowserPage {
  constructor(client, targetId, sessionId) {
    this.client = client;
    this.targetId = targetId;
    this.sessionId = sessionId;
    this.errors = [];
  }

  async initialize(width, height, preloadSource) {
    this.client.on("Runtime.exceptionThrown", (params, sessionId) => {
      if (sessionId !== this.sessionId) return;
      this.errors.push(params.exceptionDetails?.exception?.description ?? params.exceptionDetails?.text ?? "runtime exception");
    });
    this.client.on("Log.entryAdded", (params, sessionId) => {
      if (sessionId !== this.sessionId || params.entry?.level !== "error") return;
      this.errors.push(params.entry.text ?? "browser log error");
    });
    await Promise.all([
      this.call("Page.enable"),
      this.call("Runtime.enable"),
      this.call("Log.enable"),
      this.call("Emulation.setDeviceMetricsOverride", {
        width,
        height,
        deviceScaleFactor: 1,
        mobile: width < 600,
      }),
    ]);
    if (preloadSource) {
      await this.call("Page.addScriptToEvaluateOnNewDocument", { source: preloadSource });
    }
  }

  call(method, params = {}) {
    return this.client.call(method, params, this.sessionId);
  }

  async navigate(url) {
    const result = await this.call("Page.navigate", { url });
    assert(!result.errorText, `could not open overview: ${result.errorText}`);
    await this.poll("document.readyState === 'complete'", "overview document did not finish loading", 5000);
  }

  async evaluate(expression) {
    const response = await this.call("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (response.exceptionDetails) {
      const description = response.exceptionDetails.exception?.description ?? response.exceptionDetails.text;
      throw new Error(`browser evaluation failed: ${description}`);
    }
    return response.result.value;
  }

  async poll(expression, failureMessage, timeoutMilliseconds = 3000) {
    const deadline = Date.now() + timeoutMilliseconds;
    let lastValue;
    while (Date.now() < deadline) {
      lastValue = await this.evaluate(expression);
      if (lastValue) return lastValue;
      await delay(40);
    }
    throw new Error(`${failureMessage}; last value: ${JSON.stringify(lastValue)}`);
  }

  async close() {
    await this.client.call("Target.closeTarget", { targetId: this.targetId });
  }
}

async function createPage(client, width, height, preloadSource) {
  const { targetId } = await client.call("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await client.call("Target.attachToTarget", { targetId, flatten: true });
  const page = new BrowserPage(client, targetId, sessionId);
  await page.initialize(width, height, preloadSource);
  return page;
}

async function waitForDevTools(profileDirectory, browserProcess, browserErrors) {
  const activePortPath = join(profileDirectory, "DevToolsActivePort");
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (browserProcess.exitCode !== null) {
      throw new Error(`Chrome exited before DevTools was ready: ${browserErrors()}`);
    }
    try {
      const [port, endpoint] = (await readFile(activePortPath, "utf8")).trim().split("\n");
      if (port && endpoint) return `ws://127.0.0.1:${port}${endpoint}`;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await delay(50);
  }
  throw new Error(`Chrome did not expose DevTools within 10 seconds: ${browserErrors()}`);
}

async function waitForExit(processHandle, timeoutMilliseconds) {
  if (processHandle.exitCode !== null) return;
  await Promise.race([
    new Promise((resolveExit) => processHandle.once("exit", resolveExit)),
    delay(timeoutMilliseconds),
  ]);
}

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const overviewPath = join(repositoryRoot, "docs/zts-language-overview.html");
assert(existsSync(overviewPath), `missing ${overviewPath}`);

const chrome = await findChrome();
const profileDirectory = await mkdtemp(join(tmpdir(), "zts-overview-browser-"));
let browserProcess;
let client;
let chromeStderr = "";

try {
  const chromeArgs = [
    "--headless=new",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-gpu",
    "--disable-sync",
    "--metrics-recording-only",
    "--no-default-browser-check",
    "--no-first-run",
    "--remote-debugging-port=0",
    `--user-data-dir=${profileDirectory}`,
    "about:blank",
  ];
  if (typeof process.getuid === "function" && process.getuid() === 0) chromeArgs.unshift("--no-sandbox");
  browserProcess = spawn(chrome, chromeArgs, { stdio: ["ignore", "ignore", "pipe"] });
  browserProcess.stderr.setEncoding("utf8");
  browserProcess.stderr.on("data", (chunk) => {
    chromeStderr = `${chromeStderr}${chunk}`.slice(-8000);
  });

  const devToolsUrl = await waitForDevTools(profileDirectory, browserProcess, () => chromeStderr.trim());
  client = new CdpClient(devToolsUrl);
  await client.connect();

  const controlledApis = `
    (() => {
      const state = { storedTheme: "dark", writes: [], copyPending: [] };
      Object.defineProperty(window, "__ztsOverviewTest", { configurable: true, value: state });
      Object.defineProperty(window, "localStorage", {
        configurable: true,
        value: {
          getItem(key) { return key === "zts-overview-theme" ? state.storedTheme : null; },
          setItem(key, value) { state.writes.push([key, String(value)]); state.storedTheme = String(value); },
        },
      });
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: {
          writeText(text) {
            return new Promise((resolve, reject) => state.copyPending.push({ text, resolve, reject }));
          },
        },
      });
    })();
  `;

  const mainPage = await createPage(client, 1280, 800, controlledApis);
  await mainPage.navigate(`${pathToFileURL(overviewPath).href}?browser-test=controlled`);

  const initialTheme = await mainPage.evaluate(`(() => ({
    theme: document.documentElement.dataset.theme,
    pressed: document.getElementById("theme-toggle").getAttribute("aria-pressed"),
    label: document.getElementById("theme-label").textContent,
  }))()`);
  assert(initialTheme.theme === "dark", `saved dark theme did not initialize: ${JSON.stringify(initialTheme)}`);
  assert(initialTheme.pressed === "true" && initialTheme.label === "Light theme", "dark theme control is out of sync");

  const toggledTheme = await mainPage.evaluate(`(() => {
    document.getElementById("theme-toggle").click();
    return {
      theme: document.documentElement.dataset.theme,
      pressed: document.getElementById("theme-toggle").getAttribute("aria-pressed"),
      label: document.getElementById("theme-label").textContent,
      stored: window.__ztsOverviewTest.storedTheme,
    };
  })()`);
  assert(
    toggledTheme.theme === "light" && toggledTheme.pressed === "false" && toggledTheme.label === "Dark theme" && toggledTheme.stored === "light",
    `theme toggle did not persist and synchronize: ${JSON.stringify(toggledTheme)}`,
  );

  const pendingCopies = await mainPage.evaluate(`(() => {
    const button = document.querySelector('[data-copy-target="failure-example"]');
    button.click();
    button.click();
    return {
      count: window.__ztsOverviewTest.copyPending.length,
      sameText: window.__ztsOverviewTest.copyPending.every((entry) => entry.text === document.getElementById("failure-example").textContent),
    };
  })()`);
  assert(pendingCopies.count === 2 && pendingCopies.sameText, `copy requests were not captured: ${JSON.stringify(pendingCopies)}`);

  const latestCopyLabel = await mainPage.evaluate(`(async () => {
    window.__ztsOverviewTest.copyPending[1].resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
    return document.querySelector('[data-copy-target="failure-example"]').textContent;
  })()`);
  assert(latestCopyLabel === "Copied", `latest successful copy did not win: ${latestCopyLabel}`);

  const staleCopyLabel = await mainPage.evaluate(`(async () => {
    window.__ztsOverviewTest.copyPending[0].reject(new Error("older request failed"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    return document.querySelector('[data-copy-target="failure-example"]').textContent;
  })()`);
  assert(staleCopyLabel === "Copied", `stale copy completion overwrote latest feedback: ${staleCopyLabel}`);
  await mainPage.poll(
    `document.querySelector('[data-copy-target="failure-example"]').textContent === "Copy"`,
    "copy success feedback did not reset",
    2500,
  );

  await mainPage.evaluate(`(() => {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText() { return Promise.reject(new Error("denied")); } },
    });
    document.querySelector('[data-copy-target="type-example"]').click();
  })()`);
  await mainPage.poll(
    `document.querySelector('[data-copy-target="type-example"]').textContent === "Select text"`,
    "clipboard rejection feedback was not shown",
  );
  await mainPage.poll(
    `document.querySelector('[data-copy-target="type-example"]').textContent === "Copy"`,
    "copy rejection feedback did not reset",
    2500,
  );

  const hasIntersectionObserver = await mainPage.evaluate(`typeof IntersectionObserver === "function"`);
  assert(hasIntersectionObserver, "Chrome does not expose IntersectionObserver");
  await mainPage.evaluate(`document.getElementById("modules").scrollIntoView({ block: "center" })`);
  await mainPage.poll(
    `document.querySelector('.rail-nav a[href="#modules"]').getAttribute("aria-current") === "location"`,
    "IntersectionObserver did not activate the modules navigation link",
    4000,
  );

  await mainPage.call("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  const narrowLayout = await mainPage.evaluate(`(async () => {
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return {
      innerWidth: window.innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      bodyScrollWidth: document.body.scrollWidth,
    };
  })()`);
  assert(
    narrowLayout.innerWidth === 390 && narrowLayout.scrollWidth <= 390 && narrowLayout.bodyScrollWidth <= 390,
    `narrow viewport overflows: ${JSON.stringify(narrowLayout)}`,
  );
  assert(mainPage.errors.length === 0, `controlled browser page errors: ${mainPage.errors.join(" | ")}`);
  await mainPage.close();

  const unavailableApis = `
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      get() { throw new Error("storage unavailable"); },
    });
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined });
  `;
  const fallbackPage = await createPage(client, 390, 844, unavailableApis);
  await fallbackPage.navigate(`${pathToFileURL(overviewPath).href}?browser-test=unavailable`);

  const fallbackInitial = await fallbackPage.evaluate(`(() => ({
    theme: document.documentElement.dataset.theme,
    pressed: document.getElementById("theme-toggle").getAttribute("aria-pressed"),
    label: document.getElementById("theme-label").textContent,
  }))()`);
  assert(
    fallbackInitial.theme === "light" && fallbackInitial.pressed === "false" && fallbackInitial.label === "Dark theme",
    `unavailable storage did not fall back to a synchronized light theme: ${JSON.stringify(fallbackInitial)}`,
  );

  const fallbackToggled = await fallbackPage.evaluate(`(() => {
    document.getElementById("theme-toggle").click();
    return {
      theme: document.documentElement.dataset.theme,
      pressed: document.getElementById("theme-toggle").getAttribute("aria-pressed"),
      label: document.getElementById("theme-label").textContent,
    };
  })()`);
  assert(
    fallbackToggled.theme === "dark" && fallbackToggled.pressed === "true" && fallbackToggled.label === "Light theme",
    `theme toggle failed without storage: ${JSON.stringify(fallbackToggled)}`,
  );

  await fallbackPage.evaluate(`document.querySelector('[data-copy-target="failure-example"]').click()`);
  await fallbackPage.poll(
    `document.querySelector('[data-copy-target="failure-example"]').textContent === "Select text"`,
    "unavailable clipboard feedback was not shown",
  );
  await fallbackPage.poll(
    `document.querySelector('[data-copy-target="failure-example"]').textContent === "Copy"`,
    "unavailable clipboard feedback did not reset",
    2500,
  );
  assert(fallbackPage.errors.length === 0, `fallback browser page errors: ${fallbackPage.errors.join(" | ")}`);
  await fallbackPage.close();

  console.log("ZTS language overview browser OK (theme, navigation, copy races, API fallbacks, narrow layout)");
} finally {
  client?.close();
  if (browserProcess && browserProcess.exitCode === null) {
    browserProcess.kill("SIGTERM");
    await waitForExit(browserProcess, 2000);
    if (browserProcess.exitCode === null) browserProcess.kill("SIGKILL");
  }
  await rm(profileDirectory, { recursive: true, force: true });
}
