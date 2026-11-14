import assert from "node:assert/strict";
import { get } from "node:http";
import { mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  CommandProtocolError,
  LauncherService,
  createDemoDriver,
  liveCapabilities,
  parseCommand,
  startLauncherServer
} from "../src/index.js";

const commandPath = new URL("../commands/open-settings.json", import.meta.url);
const multistepCommandPath = new URL("../commands/open-settings-about.json", import.meta.url);
const captureCommandPath = new URL("../commands/capture-about-top-bottom.json", import.meta.url);

async function service(): Promise<LauncherService> {
  const command = parseCommand(await readFile(commandPath, "utf8"), "json");
  return new LauncherService({
    commands: [command],
    driverFactory: async () => createDemoDriver(),
    mode: "demo",
    capabilities: liveCapabilities
  });
}

test("launcher lists and runs the safe Open Settings command", async () => {
  const launcher = await service();

  assert.deepEqual(launcher.status().commands.map((command) => command.name), ["Open Settings"]);
  const check = await launcher.dryRun("com.yggdrasil.iphone.open-settings");
  const receipt = await launcher.run("com.yggdrasil.iphone.open-settings");

  assert.equal(check.actionsExecuted, 0);
  assert.equal(check.supported, true);
  assert.equal(receipt.status, "succeeded");
  assert.equal(receipt.steps[0]?.verification?.passed, true);
});

test("launcher preflights the Settings, General, About multi-step command", async () => {
  const command = parseCommand(await readFile(multistepCommandPath, "utf8"), "json");
  const launcher = new LauncherService({
    commands: [command],
    driverFactory: async () => createDemoDriver(),
    mode: "demo",
    capabilities: liveCapabilities
  });

  const check = await launcher.dryRun(command.id);
  assert.equal(check.supported, true);
  assert.equal(check.steps.length, 2);
  assert.deepEqual(check.requiredCapabilities.actions, ["openApp", "tap"]);
  assert.deepEqual(check.requiredCapabilities.observations, ["app", "screenText", "target"]);
});

test("launcher preflights the About top and bottom evidence command", async () => {
  const command = parseCommand(await readFile(captureCommandPath, "utf8"), "json");
  const launcher = new LauncherService({
    commands: [command],
    driverFactory: async () => createDemoDriver(),
    mode: "demo",
    capabilities: liveCapabilities
  });

  const check = await launcher.dryRun(command.id);
  assert.equal(check.supported, true);
  assert.equal(check.steps.length, 7);
  assert.deepEqual(check.requiredCapabilities.actions, ["openApp", "swipe"]);
  assert.deepEqual(check.requiredCapabilities.observations, ["app", "screenText", "screenshot"]);
});

test("localhost launcher protects state-changing routes with a session token", async () => {
  const running = await startLauncherServer({ port: 0, service: await service() });
  try {
    const page = await fetch(running.url);
    const html = await page.text();
    assert.equal(page.status, 200);
    assert.match(page.headers.get("content-security-policy") ?? "", /default-src 'self'/);
    assert.match(html, /What would you like/);

    const bootstrapResponse = await fetch(`${running.url}/api/bootstrap`);
    const bootstrap = await bootstrapResponse.json() as { token: string; mode: string; commands: unknown[] };
    assert.equal(bootstrap.mode, "demo");
    assert.equal(bootstrap.commands.length, 1);

    const unauthorized = await fetch(`${running.url}/api/run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ commandId: "com.yggdrasil.iphone.open-settings" })
    });
    assert.equal(unauthorized.status, 403);

    const authorized = await fetch(`${running.url}/api/run`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-launcher-token": bootstrap.token },
      body: JSON.stringify({ commandId: "com.yggdrasil.iphone.open-settings" })
    });
    const receipt = await authorized.json() as { status: string };
    assert.equal(authorized.status, 200);
    assert.equal(receipt.status, "succeeded");
  } finally {
    await running.close();
  }
});

test("launcher accepts only explicitly allowed tailnet proxy hosts", async () => {
  const running = await startLauncherServer({
    port: 0,
    service: await service(),
    allowedHosts: ["phone.example.ts.net."]
  });
  try {
    const allowed = await getWithHost(`${running.url}/api/bootstrap`, "phone.example.ts.net");
    const rejected = await getWithHost(`${running.url}/api/bootstrap`, "attacker.example");

    assert.equal(allowed.status, 200);
    assert.equal(rejected.status, 403);
    assert.deepEqual(JSON.parse(rejected.body), {
      error: { code: "LOCAL_ONLY", message: "Launcher is local or tailnet-only" }
    });
  } finally {
    await running.close();
  }
});

function getWithHost(url: string, host: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const request = get(url, { headers: { host } }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode ?? 0,
        body: Buffer.concat(chunks).toString("utf8")
      }));
    });
    request.once("error", reject);
  });
}

test("launcher blocks nested committing actions before connecting to the phone", async () => {
  const child = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.send",
    name: "Send",
    safety: { risk: "external" },
    steps: [{ id: "send", action: "typeText", text: "commit" }]
  }), "json");
  const parent = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.parent",
    name: "Parent",
    safety: { risk: "reversible" },
    steps: [{ id: "call", action: "call", commandId: "test.send" }]
  }), "json");
  let driverCreated = false;
  const launcher = new LauncherService({
    commands: [parent, child],
    capabilities: liveCapabilities,
    driverFactory: async () => {
      driverCreated = true;
      return createDemoDriver();
    }
  });

  await assert.rejects(
    launcher.run("test.parent"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "CONFIRMATION_UNAVAILABLE"
  );
  assert.equal(driverCreated, false);
});

async function authoringService(): Promise<{ launcher: LauncherService; directory: string }> {
  const directory = await mkdtemp(join(tmpdir(), "iphone-launcher-authoring-"));
  const command = parseCommand(await readFile(commandPath, "utf8"), "json");
  return {
    directory,
    launcher: new LauncherService({
      commands: [command],
      driverFactory: async () => createDemoDriver(),
      mode: "demo",
      capabilities: liveCapabilities,
      commandsDirectory: directory
    })
  };
}

test("authoring previews plain-language steps without touching the phone", async () => {
  const { launcher } = await authoringService();

  const proposal = await launcher.author("open Notes and check for Notes");

  assert.equal(proposal.actionsExecuted, 0);
  assert.equal(proposal.supported, true);
  assert.equal(proposal.saveable, true);
  assert.equal(proposal.command.id, "com.yggdrasil.iphone.open-notes");
  assert.equal(proposal.command.risk, "reversible");
  assert.deepEqual(proposal.steps.map((step) => step.action), ["openApp"]);
  assert.match(proposal.steps[0]?.plain ?? "", /^Open Notes on your iPhone, then check that the screen shows/);
});

test("saving an authored routine writes it and makes it runnable", async () => {
  const { launcher, directory } = await authoringService();

  const saved = await launcher.save("open Notes and check for Notes");
  const files = await readdir(directory);
  const receipt = await launcher.run(saved.id);

  assert.equal(saved.name, "Open Notes");
  assert.equal(saved.enabled, true);
  assert.deepEqual(files, ["open-notes.json"]);
  assert.deepEqual(
    launcher.status().commands.map((command) => command.name).sort(),
    ["Open Notes", "Open Settings"]
  );
  assert.equal(receipt.status, "succeeded");
});

test("editing an authored routine revalidates, replaces its file, and keeps it runnable", async () => {
  const { launcher, directory } = await authoringService();
  const saved = await launcher.save("open Notes and check for Notes");

  const proposal = await launcher.author("open Notes", saved.id);
  const updated = await launcher.update(saved.id, "open Notes");
  const persisted = parseCommand(await readFile(join(directory, "open-notes.json"), "utf8"), "json");
  const receipt = await launcher.run(updated.id);

  assert.equal(proposal.saveable, true);
  assert.equal(updated.sourceText, "open Notes");
  assert.equal(updated.manageable, true);
  assert.equal(persisted.description, "Authored from: open Notes");
  assert.equal(receipt.status, "succeeded");
});

test("editing cannot change a command's identity", async () => {
  const { launcher, directory } = await authoringService();
  const saved = await launcher.save("open Notes and check for Notes");

  const proposal = await launcher.author("open Reminders", saved.id);

  assert.equal(proposal.saveable, false);
  assert.match(proposal.blockedReason ?? "", /cannot change which saved command/);
  await assert.rejects(
    launcher.update(saved.id, "open Reminders"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "UNSUPPORTED_CAPABILITY"
  );
  assert.deepEqual(await readdir(directory), ["open-notes.json"]);
});

test("deleting an authored routine removes its file and registry entry", async () => {
  const { launcher, directory } = await authoringService();
  const saved = await launcher.save("open Notes and check for Notes");

  await launcher.delete(saved.id);

  assert.deepEqual(await readdir(directory), []);
  assert.deepEqual(launcher.status().commands.map((command) => command.name), ["Open Settings"]);
  await assert.rejects(
    launcher.run(saved.id),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "COMMAND_NOT_FOUND"
  );
});

test("built-in commands remain protected from editing and deletion", async () => {
  const { launcher } = await authoringService();
  const builtIn = launcher.status().commands.find((command) => command.name === "Open Settings");

  assert.equal(builtIn?.manageable, false);
  assert.equal(builtIn?.sourceText, undefined);
  await assert.rejects(
    launcher.update("com.yggdrasil.iphone.open-settings", "open Settings"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "UNSUPPORTED_CAPABILITY"
  );
  await assert.rejects(
    launcher.delete("com.yggdrasil.iphone.open-settings"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "UNSUPPORTED_CAPABILITY"
  );
});

test("allows saving a swipe routine when the launcher advertises verified gesture support", async () => {
  const { launcher, directory } = await authoringService();

  const proposal = await launcher.author("swipe up");

  assert.equal(proposal.supported, true);
  assert.equal(proposal.saveable, true);
  const saved = await launcher.save("swipe up");
  const persisted = parseCommand(await readFile(join(directory, "swipe-up.json"), "utf8"), "json");
  assert.equal(saved.name, "Swipe up");
  assert.equal(persisted.steps[0]?.action, "swipe");
  assert.deepEqual(await readdir(directory), ["swipe-up.json"]);
});

test("refuses to save over a command the launcher already has", async () => {
  const { launcher, directory } = await authoringService();

  const proposal = await launcher.author("open Settings");

  assert.equal(proposal.saveable, false);
  assert.match(proposal.blockedReason ?? "", /already uses the name/);
  await assert.rejects(
    launcher.save("open Settings"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "UNSUPPORTED_CAPABILITY"
  );
  assert.deepEqual(await readdir(directory), []);
});

test("refuses to overwrite an unknown file already sitting in the command folder", async () => {
  const { launcher, directory } = await authoringService();
  await writeFile(join(directory, "open-notes.json"), "{}", "utf8");

  await assert.rejects(launcher.save("open Notes and check for Notes"));
  assert.equal(await readFile(join(directory, "open-notes.json"), "utf8"), "{}");
});

test("authoring rejects ambiguous requests rather than guessing", async () => {
  const { launcher } = await authoringService();

  await assert.rejects(
    launcher.author("send a text to Mom"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "PARSE_ERROR"
  );
});

test("authoring routes require the session token and stay off without a save directory", async () => {
  const running = await startLauncherServer({ port: 0, service: await service() });
  try {
    const bootstrap = await (await fetch(`${running.url}/api/bootstrap`)).json() as {
      token: string;
      authoring: boolean;
    };
    assert.equal(bootstrap.authoring, false);

    const unauthorized = await fetch(`${running.url}/api/author`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: "open Notes and check for Notes" })
    });
    assert.equal(unauthorized.status, 403);

    const authorized = await fetch(`${running.url}/api/author`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-launcher-token": bootstrap.token },
      body: JSON.stringify({ text: "open Notes and check for Notes" })
    });
    const proposal = await authorized.json() as { saveable: boolean; blockedReason: string };
    assert.equal(authorized.status, 200);
    assert.equal(proposal.saveable, false);
    assert.match(proposal.blockedReason, /not configured to save/);

    const save = await fetch(`${running.url}/api/save`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-launcher-token": bootstrap.token },
      body: JSON.stringify({ text: "open Notes and check for Notes" })
    });
    assert.equal(save.status, 500);
  } finally {
    await running.close();
  }
});

test("management routes require the token and return the refreshed command list", async () => {
  const { launcher } = await authoringService();
  const running = await startLauncherServer({ port: 0, service: launcher });
  try {
    const bootstrap = await (await fetch(`${running.url}/api/bootstrap`)).json() as { token: string };
    const headers = { "content-type": "application/json", "x-launcher-token": bootstrap.token };
    const savedResponse = await fetch(`${running.url}/api/save`, {
      method: "POST",
      headers,
      body: JSON.stringify({ text: "open Notes and check for Notes" })
    });
    const saved = await savedResponse.json() as { saved: { id: string } };

    const unauthorized = await fetch(`${running.url}/api/delete`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ commandId: saved.saved.id })
    });
    assert.equal(unauthorized.status, 403);

    const updatedResponse = await fetch(`${running.url}/api/update`, {
      method: "POST",
      headers,
      body: JSON.stringify({ commandId: saved.saved.id, text: "open Notes" })
    });
    const updated = await updatedResponse.json() as {
      updated: { sourceText: string };
      commands: Array<{ name: string }>;
    };
    assert.equal(updatedResponse.status, 200);
    assert.equal(updated.updated.sourceText, "open Notes");
    assert.equal(updated.commands.length, 2);

    const deletedResponse = await fetch(`${running.url}/api/delete`, {
      method: "POST",
      headers,
      body: JSON.stringify({ commandId: saved.saved.id })
    });
    const deleted = await deletedResponse.json() as {
      deletedCommandId: string;
      commands: Array<{ name: string }>;
    };
    assert.equal(deletedResponse.status, 200);
    assert.equal(deleted.deletedCommandId, saved.saved.id);
    assert.deepEqual(deleted.commands.map((command) => command.name), ["Open Settings"]);
  } finally {
    await running.close();
  }
});
