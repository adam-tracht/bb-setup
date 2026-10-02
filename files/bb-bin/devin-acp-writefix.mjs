#!/usr/bin/env node
// ACP stdio shim for `devin acp`: rewrites fs/write_text_file responses from
// result:null to result:{}. bb's provider-acp bridge answers write requests
// with null, which Devin's client fails to deserialize ("Parse error"), so
// writes land on disk but are reported as failed. Passing through everything
// else untouched. Remove once bb fixes the bridge upstream.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const child = spawn("devin", process.argv.slice(2), {
  stdio: ["pipe", "pipe", "inherit"],
});

// Track request ids whose response we must rewrite: agent -> client requests
// for fs/write_text_file (seen on the child's stdout stream).
const writeRequestIds = new Set();

const fromChild = createInterface({ input: child.stdout });
fromChild.on("line", (line) => {
  try {
    const msg = JSON.parse(line);
    if (msg && msg.method === "fs/write_text_file" && msg.id != null) {
      writeRequestIds.add(typeof msg.id === "string" ? `s:${msg.id}` : msg.id);
    }
  } catch {
    // not JSON, pass through untouched
  }
  process.stdout.write(line + "\n");
});

const fromParent = createInterface({ input: process.stdin });
fromParent.on("line", (line) => {
  let out = line;
  try {
    const msg = JSON.parse(line);
    const key = msg && msg.id != null ? (typeof msg.id === "string" ? `s:${msg.id}` : msg.id) : null;
    if (msg && "result" in msg && msg.result === null && key !== null && writeRequestIds.has(key)) {
      writeRequestIds.delete(key);
      msg.result = {};
      out = JSON.stringify(msg);
    }
  } catch {
    // not JSON, pass through untouched
  }
  child.stdin.write(out + "\n");
});

child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
child.on("error", (err) => {
  process.stderr.write(`devin-acp-writefix: failed to spawn devin: ${err.message}\n`);
  process.exit(1);
});
