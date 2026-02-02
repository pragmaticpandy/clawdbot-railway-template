// Chromium startup helper for OpenClaw browser automation
// This starts chromium headless before the gateway so browser.attachOnly can connect to it.

import childProcess from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const CHROMIUM_PORT = 18800;
const CHROMIUM_PATH = process.env.CHROME_PATH || "/usr/bin/chromium";
const CHROMIUM_USER_DATA = "/data/.clawdbot/browser/openclaw/user-data";

let chromiumProc = null;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForChromiumReady(opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 10_000;
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`http://127.0.0.1:${CHROMIUM_PORT}/json/version`);
      if (res.ok) return true;
    } catch {
      // not ready yet
    }
    await sleep(250);
  }
  return false;
}

function cleanStaleLocks() {
  // Remove stale lock files that can prevent chromium from starting
  const locks = ["SingletonLock", "SingletonCookie", "SingletonSocket"];
  for (const lock of locks) {
    try {
      fs.rmSync(path.join(CHROMIUM_USER_DATA, lock), { force: true });
    } catch {
      // ignore
    }
  }
}

export async function startChromium() {
  if (chromiumProc) return { ok: true, alreadyRunning: true };

  // Check if chromium binary exists
  if (!fs.existsSync(CHROMIUM_PATH)) {
    console.log(`[chromium] Binary not found at ${CHROMIUM_PATH}, skipping browser startup`);
    return { ok: false, reason: "binary not found" };
  }

  // Ensure user data directory exists
  fs.mkdirSync(CHROMIUM_USER_DATA, { recursive: true });
  cleanStaleLocks();

  const args = [
    "--headless",
    "--no-sandbox",
    "--disable-gpu",
    `--remote-debugging-port=${CHROMIUM_PORT}`,
    "--disable-dev-shm-usage",
    `--user-data-dir=${CHROMIUM_USER_DATA}`,
    "about:blank",
  ];

  console.log(`[chromium] Starting headless on port ${CHROMIUM_PORT}...`);

  chromiumProc = childProcess.spawn(CHROMIUM_PATH, args, {
    stdio: ["ignore", "pipe", "pipe"],
    detached: false,
  });

  // Log chromium output (filtered to reduce noise)
  chromiumProc.stderr?.on("data", (d) => {
    const line = d.toString("utf8").trim();
    // Only log important messages, skip dbus noise
    if (line && !line.includes("dbus") && !line.includes("DBus")) {
      console.log(`[chromium] ${line}`);
    }
  });

  chromiumProc.on("error", (err) => {
    console.error(`[chromium] spawn error: ${String(err)}`);
    chromiumProc = null;
  });

  chromiumProc.on("exit", (code, signal) => {
    console.log(`[chromium] exited code=${code} signal=${signal}`);
    chromiumProc = null;
  });

  // Wait for DevTools to be ready
  const ready = await waitForChromiumReady({ timeoutMs: 10_000 });
  if (!ready) {
    console.error("[chromium] Failed to start (DevTools not responding)");
    if (chromiumProc) {
      try { chromiumProc.kill("SIGTERM"); } catch {}
      chromiumProc = null;
    }
    return { ok: false, reason: "timeout" };
  }

  console.log(`[chromium] Ready on port ${CHROMIUM_PORT}`);
  return { ok: true };
}

export async function stopChromium() {
  if (chromiumProc) {
    try {
      chromiumProc.kill("SIGTERM");
    } catch {
      // ignore
    }
    await sleep(500);
    chromiumProc = null;
  }
}

export function isChromiumRunning() {
  return chromiumProc !== null;
}
