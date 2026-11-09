#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_DEST = path.join(CLAUDE_DIR, "statusline.sh");
const STATUSLINE_SRC = path.resolve(__dirname, "statusline.sh");
const HOOK_DEST = path.join(CLAUDE_DIR, "keepwarm-hook.sh");
const HOOK_SRC = path.resolve(__dirname, "keepwarm-hook.sh");
const SKILL_DEST = path.join(CLAUDE_DIR, "skills", "keepwarm");
const SKILL_SRC = path.resolve(__dirname, "..", "skills", "keepwarm");
const STATE_DIR = path.join(CLAUDE_DIR, "statusline-state");
const HOOK_MARKER = "keepwarm-hook.sh";
const HOOK_COMMAND = 'bash "$HOME/.claude/keepwarm-hook.sh"';
const REFRESH_INTERVAL = 30;

const blue = "\x1b[38;2;0;153;255m";
const green = "\x1b[38;2;0;175;80m";
const red = "\x1b[38;2;255;85;85m";
const yellow = "\x1b[38;2;230;200;0m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

function log(msg) {
  console.log(`  ${msg}`);
}

function success(msg) {
  console.log(`  ${green}✓${reset} ${msg}`);
}

function warn(msg) {
  console.log(`  ${yellow}!${reset} ${msg}`);
}

function fail(msg) {
  console.error(`  ${red}✗${reset} ${msg}`);
}

function checkDeps() {
  const { execSync } = require("child_process");
  const missing = [];

  try {
    execSync("which jq", { stdio: "ignore" });
  } catch {
    missing.push("jq");
  }

  try {
    execSync("which curl", { stdio: "ignore" });
  } catch {
    missing.push("curl");
  }

  try {
    execSync("which git", { stdio: "ignore" });
  } catch {
    missing.push("git");
  }

  return missing;
}

function isOurs(h) {
  return !!h && typeof h.command === "string" && h.command.includes(HOOK_MARKER);
}

// Adds our UserPromptSubmit hook unless one is already present. Returns true if settings changed.
function installKeepwarm(settings) {
  if (!settings.hooks || typeof settings.hooks !== "object") settings.hooks = {};
  if (!Array.isArray(settings.hooks.UserPromptSubmit)) settings.hooks.UserPromptSubmit = [];
  const groups = settings.hooks.UserPromptSubmit;
  const present = groups.some((g) => g && Array.isArray(g.hooks) && g.hooks.some(isOurs));
  if (present) return false;
  groups.push({ hooks: [{ type: "command", command: HOOK_COMMAND }] });
  return true;
}

// Removes only our hook; drops groups/arrays/objects left empty. Returns true if settings changed.
function uninstallKeepwarm(settings) {
  const hooks = settings.hooks;
  if (!hooks || !Array.isArray(hooks.UserPromptSubmit)) return false;
  let changed = false;
  const kept = [];
  for (const g of hooks.UserPromptSubmit) {
    if (g && Array.isArray(g.hooks) && g.hooks.some(isOurs)) {
      changed = true;
      g.hooks = g.hooks.filter((h) => !isOurs(h));
      if (g.hooks.length === 0) continue;
    }
    kept.push(g);
  }
  if (!changed) return false;
  if (kept.length > 0) hooks.UserPromptSubmit = kept;
  else delete hooks.UserPromptSubmit;
  if (Object.keys(hooks).length === 0) delete settings.hooks;
  return true;
}

function uninstall() {
  console.log();
  console.log(`  ${blue}Claude Line Uninstaller${reset}`);
  console.log(`  ${dim}───────────────────────${reset}`);
  console.log();

  const backup = STATUSLINE_DEST + ".bak";

  if (fs.existsSync(backup)) {
    fs.copyFileSync(backup, STATUSLINE_DEST);
    fs.unlinkSync(backup);
    success(`Restored previous statusline from ${dim}statusline.sh.bak${reset}`);
  } else if (fs.existsSync(STATUSLINE_DEST)) {
    fs.unlinkSync(STATUSLINE_DEST);
    success(`Removed ${dim}statusline.sh${reset}`);
  } else {
    warn("No statusline found — nothing to remove");
  }

  if (fs.existsSync(HOOK_DEST)) {
    fs.unlinkSync(HOOK_DEST);
    success(`Removed ${dim}keepwarm-hook.sh${reset}`);
  }
  if (fs.existsSync(SKILL_DEST)) {
    fs.rmSync(SKILL_DEST, { recursive: true, force: true });
    success(`Removed ${dim}skills/keepwarm${reset}`);
  }
  if (fs.existsSync(STATE_DIR)) {
    fs.rmSync(STATE_DIR, { recursive: true, force: true });
    success(`Removed ${dim}statusline-state${reset}`);
  }

  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
      let changed = false;
      if (settings.statusLine) {
        delete settings.statusLine;
        changed = true;
      }
      if (uninstallKeepwarm(settings)) changed = true;
      if (changed) {
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
        success(`Removed statusLine and keep-alive hook from ${dim}settings.json${reset}`);
      } else {
        success("Settings already clean");
      }
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to apply changes.`);
  console.log();
}

function run() {
  if (process.argv.includes("--uninstall")) {
    uninstall();
    return;
  }

  console.log();
  console.log(`  ${blue}Claude Line Installer${reset}`);
  console.log(`  ${dim}─────────────────────${reset}`);
  console.log();

  const missing = checkDeps();
  if (missing.length > 0) {
    fail(`Missing required dependencies: ${missing.join(", ")}`);
    log(`  Install them and try again.`);
    if (missing.includes("jq")) {
      log(`  ${dim}brew install jq${reset}`);
    }
    process.exit(1);
  }
  success("Dependencies found (jq, curl, git)");

  if (!fs.existsSync(CLAUDE_DIR)) {
    fs.mkdirSync(CLAUDE_DIR, { recursive: true });
    success(`Created ${CLAUDE_DIR}`);
  }

  const backup = STATUSLINE_DEST + ".bak";
  if (fs.existsSync(STATUSLINE_DEST)) {
    fs.copyFileSync(STATUSLINE_DEST, backup);
    warn(`Backed up existing statusline to ${dim}statusline.sh.bak${reset}`);
  }

  fs.copyFileSync(STATUSLINE_SRC, STATUSLINE_DEST);
  fs.chmodSync(STATUSLINE_DEST, 0o755);
  success(`Installed statusline to ${dim}${STATUSLINE_DEST}${reset}`);

  fs.copyFileSync(HOOK_SRC, HOOK_DEST);
  fs.chmodSync(HOOK_DEST, 0o755);
  success(`Installed keep-alive hook to ${dim}${HOOK_DEST}${reset}`);

  fs.mkdirSync(path.dirname(SKILL_DEST), { recursive: true });
  fs.cpSync(SKILL_SRC, SKILL_DEST, { recursive: true });
  success(`Installed keepwarm skill to ${dim}${SKILL_DEST}${reset}`);

  let settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  let changed = false;
  const statusLineConfig = {
    type: "command",
    command: 'bash "$HOME/.claude/statusline.sh"',
    refreshInterval: REFRESH_INTERVAL,
  };

  if (
    settings.statusLine &&
    settings.statusLine.type === "command" &&
    settings.statusLine.command === statusLineConfig.command &&
    settings.statusLine.refreshInterval === statusLineConfig.refreshInterval
  ) {
    success("Statusline settings already configured");
  } else {
    settings.statusLine = statusLineConfig;
    changed = true;
    success(`Configured statusLine in ${dim}settings.json${reset}`);
  }

  if (installKeepwarm(settings)) {
    changed = true;
    success(`Registered keep-alive hook in ${dim}settings.json${reset}`);
  } else {
    success("Keep-alive hook already registered");
  }

  if (changed || !fs.existsSync(SETTINGS_FILE)) {
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to see your new status line.`);
  console.log();
}

run();
