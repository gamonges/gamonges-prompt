// tsc を起動してよい場所かを判定し、だめなら「何もしない LSP」として振る舞う。
//
// tsgo の LSP は開いたファイルの tsconfig 全体を読み込み、大きな repo では 4〜6GB を常に使う。
// そうした repo では明示の許可（TSGO_LSP_ALLOW=1 で Claude Code を起動）が無い限り tsc を起動しない。
//
// 止める場所の一覧はローカルの設定ファイルに置く（公開リポジトリに repo 名を書かないため）:
//   ${XDG_CONFIG_HOME:-~/.config}/tsgo-lsp/deny-roots
//   1 行 1 件。`#` 以降はコメント。
//   `/` か `~` で始まる行はパスの前方一致、それ以外はパスのいずれかの区切り（ディレクトリ名）との一致。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const configDir = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config");
export const denyFile = path.join(configDir, "tsgo-lsp", "deny-roots");

function readRules() {
  try {
    return fs
      .readFileSync(denyFile, "utf8")
      .split("\n")
      .map((l) => l.replace(/#.*/, "").trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

// 一致したルールを返す（無ければ null）
export function matchDenyRule(dir) {
  const abs = path.resolve(dir);
  const segments = abs.split(path.sep);
  for (const rule of readRules()) {
    if (rule.startsWith("/") || rule.startsWith("~")) {
      const prefix = path.resolve(rule.replace(/^~(?=$|\/)/, os.homedir()));
      if (abs === prefix || abs.startsWith(prefix + path.sep)) return rule;
    } else if (segments.includes(rule)) {
      return rule;
    }
  }
  return null;
}

// 何もしない LSP。initialize には空の capabilities で答え、shutdown / exit で終わる。
// プロセスを落とすと Claude Code が再起動を繰り返すので、生かしたまま黙らせる。
export function runInertServer(reason) {
  process.stderr.write(`[tsgo-lsp-proxy] tsc を起動しない: ${reason}\n`);
  const reply = (msg) => {
    const body = Buffer.from(JSON.stringify(msg), "utf8");
    process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
    process.stdout.write(body);
  };
  let buf = Buffer.alloc(0);
  process.stdin.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const h = buf.indexOf("\r\n\r\n");
      if (h < 0) return;
      const m = /Content-Length:\s*(\d+)/i.exec(buf.subarray(0, h).toString("ascii"));
      const end = h + 4 + (m ? Number(m[1]) : 0);
      if (buf.length < end) return;
      const msg = m ? JSON.parse(buf.subarray(h + 4, end).toString("utf8")) : {};
      buf = buf.subarray(end);
      if (msg.method === "exit") process.exit(0);
      if (msg.id == null || !msg.method) continue; // 通知とクライアントへの応答は捨てる
      reply({ jsonrpc: "2.0", id: msg.id, result: msg.method === "initialize" ? { capabilities: {}, serverInfo: { name: "tsgo-lsp (inert)" } } : null });
    }
  });
  process.stdin.on("end", () => process.exit(0));
}
