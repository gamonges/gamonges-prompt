#!/usr/bin/env node
// Claude Code と `tsc --lsp --stdio`（TypeScript 7 / typescript-go）の間に入る LSP 中継。
//
// Claude Code は診断を push（textDocument/publishDiagnostics）でしか受けないが、
// tsgo は開いたファイルの診断を pull（textDocument/diagnostic）でしか返さない。
// そこで中継が didOpen / didChange / didSave を見て pull を投げ、結果を push に変えて返す。
// それ以外のメッセージは素通しする。
//
// 環境変数:
//   TSGO_LSP_COMMAND   起動する tsc（既定: 下の resolveTsc の順で探す）
//   TSGO_LSP_DEBOUNCE  変更から pull までの待ち（ms、既定: 150）
//   TSGO_LSP_PULL_SCOPE changed（既定）| all
//   TSGO_LSP_DEBUG     1 なら中継の動きを stderr に出す

import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { denyFile, matchDenyRule, runInertServer } from "./guard.mjs";

// PATH の tsc はディレクトリごとに別物になりうる（repo の mise.toml が古い node を固定し、
// その node のグローバル TS 5 が先に解決される等）。--lsp は TS 7 にしか無いので、
// 版を確かめてから使う。
function tscMajor(cmd) {
  try {
    const m = /Version (\d+)\./.exec(execFileSync(cmd, ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
    return m ? Number(m[1]) : 0;
  } catch {
    return 0;
  }
}
function resolveTsc() {
  if (process.env.TSGO_LSP_COMMAND) return process.env.TSGO_LSP_COMMAND;
  const candidates = [];
  try {
    const dir = execFileSync("mise", ["where", "npm:typescript@7"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    candidates.push(path.join(dir, "node_modules", ".bin", "tsc"));
  } catch {}
  candidates.push("tsc");
  for (const c of candidates) if ((c === "tsc" || fs.existsSync(c)) && tscMajor(c) >= 7) return c;
  process.stderr.write(`[tsgo-lsp-proxy] TypeScript 7 の tsc が見つからない（試した候補: ${candidates.join(", ")}）。TSGO_LSP_COMMAND で指定する\n`);
  process.exit(1);
}

const command = resolveTsc();
const debounceMs = Number(process.env.TSGO_LSP_DEBOUNCE ?? 150);
// changed: 変更したファイルだけ引き直す（既定） / all: 開いている全件（import 先の変更も拾うが、
// frontend の実測で 1 回 2〜3 秒・RSS が書き換えのたびに増えた。changed は 1.1 秒・RSS 一定）
const pullScope = process.env.TSGO_LSP_PULL_SCOPE === "all" ? "all" : "changed";
const debug = process.env.TSGO_LSP_DEBUG === "1";
const log = (...a) => debug && process.stderr.write(`[tsgo-lsp-proxy] ${a.join(" ")}\n`);

// 大きな repo では明示の許可が無い限り tsc を起動しない（guard.mjs の冒頭を参照）
const deniedBy = matchDenyRule(process.cwd());
if (deniedBy && process.env.TSGO_LSP_ALLOW !== "1") {
  runInertServer(`${process.cwd()} が ${denyFile} の「${deniedBy}」に一致（許可するなら TSGO_LSP_ALLOW=1 で Claude Code を起動）`);
  await new Promise(() => {}); // 以降の中継を動かさない
}

const server = spawn(command, ["--lsp", "--stdio"], { stdio: ["pipe", "pipe", "inherit"] });
server.on("error", (e) => {
  process.stderr.write(`[tsgo-lsp-proxy] failed to start ${command}: ${e.message}\n`);
  process.exit(1);
});
server.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
process.stdin.on("end", () => server.stdin.end());

// --- Content-Length フレーミング -------------------------------------------------
function reader(stream, onMessage) {
  let buf = Buffer.alloc(0);
  stream.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const headerEnd = buf.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const m = /Content-Length:\s*(\d+)/i.exec(buf.subarray(0, headerEnd).toString("ascii"));
      if (!m) {
        // ヘッダが壊れていたら同期を取り直せないので、ここまでを捨てる
        buf = buf.subarray(headerEnd + 4);
        continue;
      }
      const start = headerEnd + 4;
      const end = start + Number(m[1]);
      if (buf.length < end) return;
      const body = buf.subarray(start, end).toString("utf8");
      buf = buf.subarray(end);
      onMessage(JSON.parse(body));
    }
  });
}
function write(stream, msg) {
  const body = Buffer.from(JSON.stringify(msg), "utf8");
  stream.write(`Content-Length: ${body.length}\r\n\r\n`);
  stream.write(body);
}
const toServer = (msg) => write(server.stdin, msg);
const toClient = (msg) => write(process.stdout, msg);

// --- 開いているドキュメントと pull の管理 ------------------------------------------
const openDocs = new Map(); // uri -> version
const timers = new Map(); // uri -> timeout
const latestRequest = new Map(); // uri -> 最後に投げた pull の id（古い応答を捨てるため）
const pending = new Map(); // proxy request id -> { uri, version }
let nextId = 0;
let initialized = false;

function schedulePull(uri) {
  clearTimeout(timers.get(uri));
  timers.set(
    uri,
    setTimeout(() => {
      timers.delete(uri);
      if (!initialized || !openDocs.has(uri)) return;
      const id = `proxy-${++nextId}`;
      pending.set(id, { uri, version: openDocs.get(uri) });
      latestRequest.set(uri, id);
      log("pull", uri);
      toServer({ jsonrpc: "2.0", id, method: "textDocument/diagnostic", params: { textDocument: { uri } } });
    }, debounceMs),
  );
}
// 1 ファイルの変更で他のファイルの診断も変わる（import 先の型が変わる等）ので、開いている全件を引き直す
const pullAll = () => openDocs.forEach((_, uri) => schedulePull(uri));

function publish(uri, version, diagnostics) {
  toClient({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: { uri, ...(version != null ? { version } : {}), diagnostics },
  });
}

// --- Claude Code → tsgo -----------------------------------------------------------
reader(process.stdin, (msg) => {
  switch (msg.method) {
    case "initialize": {
      // pull を使うことを tsgo に伝える（Claude Code 自身は pull を名乗らない）
      const td = ((msg.params.capabilities ??= {}).textDocument ??= {});
      td.diagnostic ??= { dynamicRegistration: false, relatedDocumentSupport: false };
      break;
    }
    case "initialized":
      initialized = true;
      break;
    case "textDocument/didOpen":
      openDocs.set(msg.params.textDocument.uri, msg.params.textDocument.version);
      break;
    case "textDocument/didChange":
      openDocs.set(msg.params.textDocument.uri, msg.params.textDocument.version);
      break;
    case "textDocument/didClose": {
      const { uri } = msg.params.textDocument;
      openDocs.delete(uri);
      clearTimeout(timers.get(uri));
      latestRequest.delete(uri);
      toServer(msg);
      publish(uri, null, []); // 閉じたファイルの診断を消す
      return;
    }
  }
  toServer(msg);
  if (["textDocument/didOpen", "textDocument/didChange", "textDocument/didSave"].includes(msg.method)) {
    if (pullScope === "changed") schedulePull(msg.params.textDocument.uri);
    else pullAll();
  }
});

// --- tsgo → Claude Code -----------------------------------------------------------
reader(server.stdout, (msg) => {
  // 中継が投げた pull の応答
  if (msg.id != null && !msg.method && pending.has(msg.id)) {
    const { uri, version } = pending.get(msg.id);
    pending.delete(msg.id);
    if (latestRequest.get(uri) !== msg.id) return; // 後から投げた pull があるので捨てる
    if (msg.error) return log("pull error", uri, JSON.stringify(msg.error));
    const report = msg.result;
    if (report?.kind === "full") publish(uri, version, report.items ?? []);
    // kind: "unchanged" は前回の push のままでよい
    return;
  }
  // サーバーから「診断を引き直して」と頼まれたら、中継が引き受ける（Claude Code は未対応のため）
  if (msg.method === "workspace/diagnostic/refresh") {
    toServer({ jsonrpc: "2.0", id: msg.id, result: null });
    pullAll();
    return;
  }
  toClient(msg);
});
