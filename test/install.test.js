"use strict";
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const INSTALLER = path.resolve(__dirname, "..", "bin", "install.js");

function mkHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "statusline-install-"));
}

function run(home, ...args) {
  const r = spawnSync("node", [INSTALLER, ...args], {
    env: { ...process.env, HOME: home },
    encoding: "utf-8",
  });
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  return r;
}

function readSettings(home) {
  return JSON.parse(fs.readFileSync(path.join(home, ".claude", "settings.json"), "utf-8"));
}

function writeSettings(home, obj) {
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), JSON.stringify(obj));
}

const ours = (s) =>
  (s.hooks.UserPromptSubmit || []).flatMap((g) => g.hooks).filter((h) => h.command.includes("keepwarm-hook.sh"));

test("install creates all files and settings", () => {
  const home = mkHome();
  run(home);
  const c = path.join(home, ".claude");
  assert.ok(fs.existsSync(path.join(c, "statusline.sh")));
  assert.ok(fs.existsSync(path.join(c, "keepwarm-hook.sh")));
  assert.ok(fs.existsSync(path.join(c, "skills", "keepwarm", "SKILL.md")));
  assert.ok(fs.statSync(path.join(c, "keepwarm-hook.sh")).mode & 0o100, "hook executable");
  const s = readSettings(home);
  assert.deepStrictEqual(s.statusLine, {
    type: "command",
    command: 'bash "$HOME/.claude/statusline.sh"',
    refreshInterval: 30,
  });
  assert.deepStrictEqual(s.hooks.UserPromptSubmit, [
    { hooks: [{ type: "command", command: 'bash "$HOME/.claude/keepwarm-hook.sh"' }] },
  ]);
});

test("install is idempotent", () => {
  const home = mkHome();
  run(home);
  run(home);
  const s = readSettings(home);
  assert.strictEqual(ours(s).length, 1);
  assert.strictEqual(s.hooks.UserPromptSubmit.length, 1);
});

test("install preserves foreign hooks", () => {
  const home = mkHome();
  const foreignUps = { hooks: [{ type: "command", command: "echo other" }] };
  const foreignStop = { hooks: [{ type: "command", command: "echo stop" }] };
  writeSettings(home, { hooks: { UserPromptSubmit: [foreignUps], Stop: [foreignStop] } });
  run(home);
  const s = readSettings(home);
  assert.deepStrictEqual(s.hooks.UserPromptSubmit[0], foreignUps);
  assert.deepStrictEqual(s.hooks.Stop, [foreignStop]);
  assert.strictEqual(ours(s).length, 1);
});

test("install upgrades old statusLine config", () => {
  const home = mkHome();
  writeSettings(home, {
    statusLine: { type: "command", command: 'bash "$HOME/.claude/statusline.sh"' },
  });
  run(home);
  assert.strictEqual(readSettings(home).statusLine.refreshInterval, 30);
});

test("uninstall removes ours only", () => {
  const home = mkHome();
  const foreignUps = { hooks: [{ type: "command", command: "echo other" }] };
  const foreignStop = { hooks: [{ type: "command", command: "echo stop" }] };
  writeSettings(home, { hooks: { UserPromptSubmit: [foreignUps], Stop: [foreignStop] } });
  run(home);
  fs.mkdirSync(path.join(home, ".claude", "statusline-state"), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "statusline-state", "x"), "1");
  run(home, "--uninstall");
  const c = path.join(home, ".claude");
  assert.ok(!fs.existsSync(path.join(c, "keepwarm-hook.sh")));
  assert.ok(!fs.existsSync(path.join(c, "skills", "keepwarm")));
  assert.ok(!fs.existsSync(path.join(c, "statusline-state")));
  assert.ok(!fs.existsSync(path.join(c, "statusline.sh")));
  const s = readSettings(home);
  assert.strictEqual(s.statusLine, undefined);
  assert.deepStrictEqual(s.hooks.UserPromptSubmit, [foreignUps]);
  assert.deepStrictEqual(s.hooks.Stop, [foreignStop]);
});

test("uninstall drops empty containers", () => {
  const home = mkHome();
  run(home);
  run(home, "--uninstall");
  const s = readSettings(home);
  assert.strictEqual(s.hooks, undefined);
});

test("uninstall removes only our hook from a mixed group", () => {
  const home = mkHome();
  const foreign = { type: "command", command: "echo other" };
  writeSettings(home, {
    hooks: {
      UserPromptSubmit: [
        { hooks: [foreign, { type: "command", command: 'bash "$HOME/.claude/keepwarm-hook.sh"' }] },
      ],
    },
  });
  run(home, "--uninstall");
  assert.deepStrictEqual(readSettings(home).hooks.UserPromptSubmit, [{ hooks: [foreign] }]);
});

test("uninstall restores statusline backup", () => {
  const home = mkHome();
  const c = path.join(home, ".claude");
  fs.mkdirSync(c, { recursive: true });
  fs.writeFileSync(path.join(c, "statusline.sh"), "ORIGINAL");
  run(home);
  assert.ok(fs.existsSync(path.join(c, "statusline.sh.bak")));
  run(home, "--uninstall");
  assert.strictEqual(fs.readFileSync(path.join(c, "statusline.sh"), "utf-8"), "ORIGINAL");
  assert.ok(!fs.existsSync(path.join(c, "statusline.sh.bak")));
});

test("uninstall with backup keeps statusLine command, drops refreshInterval", () => {
  const home = mkHome();
  const c = path.join(home, ".claude");
  fs.mkdirSync(c, { recursive: true });
  fs.writeFileSync(path.join(c, "statusline.sh"), "ORIGINAL");
  run(home);
  run(home, "--uninstall");
  const s = JSON.parse(fs.readFileSync(path.join(c, "settings.json"), "utf-8"));
  assert.ok(s.statusLine.command.includes("statusline.sh"));
  assert.ok(!("refreshInterval" in s.statusLine));
});

function rawSettings(home, text) {
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), text);
}

for (const [name, text] of [
  ["object UserPromptSubmit", '{"hooks":{"UserPromptSubmit":{"a":1}}}'],
  ["array hooks", '{"hooks":[]}'],
  ["array root", "[]"],
  ["null root", "null"],
]) {
  for (const args of [[], ["--uninstall"]]) {
    test(`malformed settings (${name}) aborts untouched ${args.join("")}`, () => {
      const home = mkHome();
      rawSettings(home, text);
      const r = spawnSync("node", [INSTALLER, ...args], {
        env: { ...process.env, HOME: home },
        encoding: "utf-8",
      });
      assert.notStrictEqual(r.status, 0);
      const c = path.join(home, ".claude");
      assert.strictEqual(fs.readFileSync(path.join(c, "settings.json"), "utf-8"), text);
      assert.deepStrictEqual(fs.readdirSync(c), ["settings.json"]);
    });
  }
}

test("install keeps extra statusLine keys of our own config", () => {
  const home = mkHome();
  writeSettings(home, {
    statusLine: { type: "command", command: 'bash "$HOME/.claude/statusline.sh"', padding: 2 },
  });
  run(home);
  const sl = readSettings(home).statusLine;
  assert.strictEqual(sl.padding, 2);
  assert.strictEqual(sl.refreshInterval, 30);
});

test("reinstall does not overwrite backup with our own script", () => {
  const home = mkHome();
  const c = path.join(home, ".claude");
  fs.mkdirSync(c, { recursive: true });
  fs.writeFileSync(path.join(c, "statusline.sh"), "USER");
  run(home);
  run(home);
  run(home, "--uninstall");
  assert.strictEqual(fs.readFileSync(path.join(c, "statusline.sh"), "utf-8"), "USER");
});

test("uninstall keeps a foreign statusLine", () => {
  const home = mkHome();
  writeSettings(home, { statusLine: { type: "command", command: "my-own-line" } });
  run(home, "--uninstall");
  assert.strictEqual(readSettings(home).statusLine.command, "my-own-line");
});
