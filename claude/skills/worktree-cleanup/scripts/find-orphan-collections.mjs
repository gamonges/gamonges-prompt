#!/usr/bin/env node
// claude-context が Milvus に残した孤児 collection を検出し、承認されたものだけを drop する。
// 手順と判定の説明は ../reference/orphan-check.md。
//
// 孤児は「元パス（description の codebasePath:、無ければ snapshot のハッシュ照合で得たもの）が
// ディスクに存在しない collection」と定義する。snapshot との差分では判定しない。MCP の sync は
// snapshot に無い collection を description から書き戻し、次回起動時にまた除去するため、
// snapshot は同期のたびに孤児を含んだり含まなかったりして判定が安定しない。
//
// 判定できないもの（describe の失敗・元パス不明・ハッシュ不一致・未知の snapshot 形式）は
// すべて unknown に倒し、drop 対象にしない。依存している内部仕様（collection 名の規則・
// description の形式）が版上げで変わった場合に、誤 drop ではなく unknown の急増として現れるようにするため。
//
// 実行権限は不要（node 経由で起動する）。
//
//   node find-orphan-collections.mjs [--snapshot <path>]                 # list モード
//   node find-orphan-collections.mjs [--snapshot <path>] --drop <name>…  # drop モード
//
// exit code: 0 = 正常（孤児 0 件を含む）/ drop が全件 dropped
//            1 = drop に refused / error がある、または予期しないエラー（stderr に詳細）
//            2 = Milvus に到達できない

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

/** 末尾の 8 桁は md5(path.resolve(codebasePath)) の先頭。名前の override を設定しても維持される */
const COLLECTION_NAME = /^(?:hybrid_)?code_chunks_(?:.*_)?([0-9a-f]{8})$/;
const DESCRIPTION_PREFIX = 'codebasePath:';
const DEFAULT_ADDRESS = 'localhost:19530';
const TIMEOUT_MS = 5000;

class UnreachableError extends Error {}
class MilvusError extends Error {}

function parseArgs(argv) {
  const args = {
    snapshot: join(homedir(), '.context', 'mcp-codebase-snapshot.json'),
    drop: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--snapshot') {
      if (i + 1 >= argv.length) throw new Error('--snapshot にパスが無い');
      args.snapshot = argv[++i];
    } else if (arg === '--drop') {
      args.drop ??= [];
    } else if (args.drop && !arg.startsWith('--')) {
      args.drop.push(arg);
    } else {
      throw new Error(`不明な引数: ${arg}`);
    }
  }
  if (args.drop && args.drop.length === 0) throw new Error('--drop に collection 名が無い');
  return args;
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * MCP と同じ Milvus を点検するため、MCP 側の解決を再現する。MCP の process.env は
 * Claude Code が ~/.claude.json の MCP env を重ねたもので、それが無ければ ~/.context/.env を読む。
 * 空文字は未設定として次へ進む（MCP 側の `if (process.env[name])` と同じ扱い）。
 * プロジェクトスコープの MCP 設定は読まない。読むと cwd によって点検先が変わる
 */
function resolveSetting(name) {
  const mcpEnv = readJson(join(homedir(), '.claude.json'))?.mcpServers?.['claude-context']?.env;
  if (typeof mcpEnv?.[name] === 'string' && mcpEnv[name]) {
    return { value: mcpEnv[name], source: 'claude.json' };
  }
  if (process.env[name]) {
    return { value: process.env[name], source: 'env' };
  }
  let dotenv = '';
  try {
    dotenv = readFileSync(join(homedir(), '.context', '.env'), 'utf8');
  } catch {
    // 無ければ既定値へ
  }
  // claude-context の envManager と同じく、trim した行の前方一致で最初の 1 件を採る（引用符は外さない）
  const line = dotenv.split('\n').map((l) => l.trim()).find((l) => l.startsWith(`${name}=`));
  const value = line?.slice(name.length + 1);
  if (value) {
    return { value, source: 'dotenv' };
  }
  return null;
}

function milvusClient() {
  const address = resolveSetting('MILVUS_ADDRESS') ?? { value: DEFAULT_ADDRESS, source: 'default' };
  const token = resolveSetting('MILVUS_TOKEN')?.value;
  const base = (/^https?:\/\//.test(address.value) ? address.value : `http://${address.value}`).replace(/\/+$/, '');
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;

  // Milvus REST はエラーも HTTP 200 で返すため、成否は body の code で判定する
  async function call(op, body) {
    let res;
    try {
      res = await fetch(`${base}/v2/vectordb/collections/${op}`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      throw new UnreachableError(`${base} に到達できない（${op}）: ${e.cause?.code ?? e.name}`);
    }
    const text = await res.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      throw new MilvusError(`${op}: HTTP ${res.status} で JSON 以外の応答: ${text.slice(0, 200)}`);
    }
    if (json.code !== 0) {
      throw new MilvusError(`${op}: code=${json.code} ${json.message ?? ''}`.trim());
    }
    return json.data;
  }

  return { milvus: base, milvusSource: address.source, call };
}

/** snapshot が不在・パース不能・未知の形式なら空を返す。照合を飛ばすだけで、判定は unknown 側に倒れる */
function readSnapshotPaths(path) {
  const snapshot = readJson(path);
  if (snapshot?.formatVersion !== 'v2' || typeof snapshot.codebases !== 'object' || !snapshot.codebases) {
    return [];
  }
  return Object.keys(snapshot.codebases);
}

function pathHash(p) {
  return createHash('md5').update(resolve(p)).digest('hex').slice(0, 8);
}

/**
 * 1 collection を ignored / live / orphan / unknown に分類する。
 * UnreachableError だけは呼び出し元へ投げる（到達不能を unknown に紛れさせると「0 件」と区別できない）
 */
async function classify(client, snapshotPaths, name) {
  const match = COLLECTION_NAME.exec(name);
  if (!match) return { kind: 'ignored' };
  const hash = match[1];
  const unknown = (reason) => ({ kind: 'unknown', entry: { name, reason } });

  let description;
  try {
    description = (await client.call('describe', { collectionName: name }))?.description;
  } catch (e) {
    if (e instanceof UnreachableError) throw e;
    return unknown(`describe に失敗: ${e.message}`);
  }

  let path = null;
  let pathSource = null;
  if (typeof description === 'string' && description.startsWith(DESCRIPTION_PREFIX)) {
    path = description.slice(DESCRIPTION_PREFIX.length);
    pathSource = 'description';
  } else {
    path = snapshotPaths.find((p) => pathHash(p) === hash) ?? null;
    pathSource = path ? 'snapshot' : null;
  }
  if (!path) return unknown('description に codebasePath が無く、snapshot にも一致するパスが無い');
  // description の改ざんや命名規則の変更を検知する
  if (pathHash(path) !== hash) return unknown(`元パス（${pathSource}）のハッシュが collection 名と一致しない`);

  try {
    if (statSync(path).isDirectory()) return { kind: 'live' };
    return unknown(`元パス（${pathSource}）がディレクトリではない: ${path}`);
  } catch (e) {
    if (e.code !== 'ENOENT' && e.code !== 'ENOTDIR') {
      return unknown(`元パス（${pathSource}）の実在を確認できない: ${e.code}`);
    }
  }
  return { kind: 'orphan', entry: { name, path, pathSource } };
}

async function rowCount(client, name) {
  try {
    const n = Number((await client.call('get_stats', { collectionName: name }))?.rowCount);
    return Number.isFinite(n) ? n : null;
  } catch (e) {
    // 行数は表示用なので、取れなくても分類は変えない
    if (e instanceof UnreachableError) throw e;
    return null;
  }
}

async function list(client, snapshotPaths) {
  const names = await client.call('list', {});
  if (!Array.isArray(names)) throw new MilvusError(`list: 配列ではない応答: ${JSON.stringify(names)}`);
  const orphans = [];
  const unknown = [];
  let liveCount = 0;
  // 順に呼ぶ。Milvus への同時接続を増やさない（100 件規模でも数秒で終わる）
  for (const name of names) {
    const result = await classify(client, snapshotPaths, name);
    if (result.kind === 'orphan') {
      orphans.push({ ...result.entry, rowCount: await rowCount(client, name) });
    } else if (result.kind === 'unknown') {
      unknown.push(result.entry);
    } else if (result.kind === 'live') {
      liveCount++;
    }
  }
  return { orphans, unknown, liveCount };
}

/** list の提示から承認までの間に状態が変わりうるため、各名前をその場で判定し直してから drop する */
async function drop(client, snapshotPaths, names) {
  const existing = new Set(await client.call('list', {}));
  const results = [];
  for (const name of names) {
    try {
      if (!existing.has(name)) {
        results.push({ name, status: 'refused', detail: 'collection が存在しない' });
        continue;
      }
      const result = await classify(client, snapshotPaths, name);
      if (result.kind !== 'orphan') {
        const detail = {
          ignored: 'claude-context の collection 名ではない',
          live: '元パスが存在する',
          unknown: result.entry?.reason,
        }[result.kind];
        results.push({ name, status: 'refused', detail });
        continue;
      }
      await client.call('drop', { collectionName: name });
      results.push({ name, status: 'dropped', detail: result.entry.path });
    } catch (e) {
      results.push({ name, status: 'error', detail: e.message });
    }
  }
  return { results };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const client = milvusClient();
  const snapshotPaths = readSnapshotPaths(args.snapshot);
  const body = args.drop
    ? await drop(client, snapshotPaths, args.drop)
    : await list(client, snapshotPaths);
  process.stdout.write(`${JSON.stringify({ milvus: client.milvus, milvusSource: client.milvusSource, ...body }, null, 2)}\n`);
  return body.results?.some((r) => r.status !== 'dropped') ? 1 : 0;
}

main().then(
  (code) => { process.exitCode = code; },
  (e) => {
    process.stderr.write(`find-orphan-collections: ${e.message}\n`);
    process.exitCode = e instanceof UnreachableError ? 2 : 1;
  },
);
