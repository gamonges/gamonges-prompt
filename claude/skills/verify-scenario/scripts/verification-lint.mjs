#!/usr/bin/env node
// verification.md の書式を検査する。検査するのは「書かれ方」だけで、中身の妥当性
// （expected が仕様と合っているか）は検査しない。
//
// 検査仕様の正典は ../reference/verification-format.md。
// 検査対象パスは引数で受ける（リポジトリ非依存にするため、暗黙のパス解決をしない）。
//
// 実行権限は不要。setup.sh の chmod は skill 内 scripts/*.sh のみを対象にするため、
// node 経由で起動する前提の .mjs にしている。
//
//   node verification-lint.mjs <path-to-verification.md> [more...]
//
// exit code: error が 1 件以上あれば 1、warn のみ / 問題なしは 0

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

const REQUIRED_HEADINGS = [
  'Preconditions',
  'Sub-features',
  'How to get to it',
  'Driving it',
  'Gotchas',
];

const DRIVING_HEADING = 'Driving it';

/** `- [ ]` / `- [x]` で始まる Driving 行の開始 */
const ENTRY_START = /^\s*-\s*\[[ xX]\]\s*/;
/** `Side effect:` とそれに続くバッククォート区間 */
const SIDE_EFFECT_WITH_SQL = /Side effect:\s*`([^`]*)`/g;
const SIDE_EFFECT_ANY = /Side effect:/g;
/**
 * テナント絞り込みの opt-out。`Side effect:` と**同じ行**に、理由を続けて書く。
 * 理由の記述（`:` の後の非空白）を必須にするのは、理由の無い opt-out が検査を空文化させるため。
 *
 * スコープが `draft:` と異なる点に注意する: `draft:` はエントリの 1 行目に係り、
 * 本マーカーはその `Side effect:` の行だけに係る。1 エントリは Side effect: を複数持てるので、
 * エントリ単位にすると 1 本の逃げ道が同エントリの他の SQL の検査まで外してしまう。
 */
const NO_TENANT_MARKER = /no-tenant-filter:\s*\S/;

class Findings {
  constructor(file) {
    this.file = file;
    this.errors = [];
    this.warns = [];
    this.infos = [];
  }

  error(line, message) {
    this.errors.push(`${this.file}:L${line}: ${message}`);
  }

  warn(line, message) {
    this.warns.push(`${this.file}:L${line}: ${message}`);
  }

  info(message) {
    this.infos.push(`${this.file}: ${message}`);
  }
}

/** 行頭 `## ` の見出し名 → 出現行番号（1-indexed） */
function collectHeadings(lines) {
  const headings = new Map();
  lines.forEach((line, index) => {
    const match = /^##\s+(.+?)\s*$/.exec(line);
    if (match && !headings.has(match[1])) {
      headings.set(match[1], index + 1);
    }
  });
  return headings;
}

/**
 * `## Driving it` セクション内のエントリを切り出す。
 * 1 エントリは複数行にまたがる（Side effect: と actual/expected は継続行に置く）ため、
 * 次のエントリ開始か次の `## ` 見出しまでを 1 件として扱う。
 *
 * 3 つの表現を持たせるのは、判定の粒度がそれぞれ違うため:
 *   text  — 全行を連結した文字列。折り返した SQL を繋ぐ用途と、エントリのどこかに 1 つあれば
 *           よい要素（expected: / actual:）の存在検査に使う。**行境界を失っている**ので、
 *           「特定の行に置く」と決めたマーカーの判定には使ってはいけない
 *   head  — エントリの 1 行目。`draft:` のようなエントリ単位のマーカー判定に使う
 *   lines — 各行の配列（1 行目を含む）。`Side effect:` 行に置くマーカーのような行単位の判定に使う
 *
 * この 3 者の取り違えが「注記に draft: と書いただけで実行済み行が未実行扱いになり、
 * actual: 欠落の error が消える」不具合の原因だった。用途を混ぜないこと。
 */
function collectDrivingEntries(lines, drivingLine) {
  const entries = [];
  let current = null;

  for (let index = drivingLine; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^##\s/.test(line)) {
      break;
    }
    if (ENTRY_START.test(line)) {
      if (current) {
        entries.push(current);
      }
      // lines に 1 行目を含めるのは、単一行エントリ（Side effect: がチェックボックス行にある形）が
      // 実在するため。ここで初期値を与えないとその形で行単位のマーカーが一切効かない
      current = { line: index + 1, text: line, head: line, lines: [line] };
      continue;
    }
    if (current) {
      // SQL が改行で折り返されるため、結合して 1 行として扱う
      current.text += ` ${line.trim()}`;
      current.lines.push(line);
    }
  }
  if (current) {
    entries.push(current);
  }
  return entries;
}

/**
 * organization_id で「絞り込んでいる」か。列名が出現するだけでは通さない —
 * `SELECT organization_id FROM t;` は全テナントの読み出しであって絞り込みではない。
 *
 * 選言（OR）は見ていない。`WHERE user_id = :u OR organization_id = :org` はここを通るが
 * テナントを跨ぐため、その形は lintSql 側で warn として拾う。
 */
function hasTenantFilter(sql) {
  return /\b(where|and)\b[\s\S]*?\borganization_id\b\s*(=|in\b)/i.test(sql);
}

/**
 * 各 `Side effect:` に対応する opt-out マーカーの有無を、出現順に返す。
 * entry.text（連結済み）ではなく entry.lines を走査するのは、text が行境界を失っており、
 * エントリ末尾の注記に書かれた語に反応してしまうため（draft: と同型の誤り）。
 */
function collectNoTenantFlags(entry) {
  const flags = [];
  for (const line of entry.lines) {
    const occurrences = [...line.matchAll(SIDE_EFFECT_ANY)].length;
    const marked = NO_TENANT_MARKER.test(line);
    for (let index = 0; index < occurrences; index += 1) {
      flags.push(marked);
    }
  }
  return flags;
}

function lintSql(findings, entry, sql, allowNoTenantFilter) {
  const normalized = sql.trim();
  if (!/^select\b/i.test(normalized)) {
    findings.error(
      entry.line,
      `Side effect: の SQL は SELECT で始める（検証手順が状態を書き換えないため）。CTE が必要なら派生表に書き換える: \`${normalized.slice(0, 60)}\``,
    );
  }
  if (!allowNoTenantFilter && !hasTenantFilter(normalized)) {
    findings.error(
      entry.line,
      'Side effect: の SQL に organization_id の絞り込みが無い（クロステナントの読み出しを検証手順に持ち込まないため）。テナント列を持たないテーブルなら、同じ行に `no-tenant-filter: <理由>` を付ける',
    );
  }
  // 絞り込みがあっても選言に入っていれば他テナントの行が返る。error にしないのは、正当な OR を
  // 含むクエリでの過剰検知が「警告を読み飛ばす習慣」を育て、検出漏れとは逆方向から検査を殺すため。
  // 文字列リテラル内の or（`WHERE name = 'or'`）で誤検知しうるが、除去処理はエスケープや
  // ダラー引用符まで抱え込むわりに得るものが小さいので入れない
  if (!allowNoTenantFilter && hasTenantFilter(normalized) && /\bor\b/i.test(normalized)) {
    findings.warn(
      entry.line,
      'Side effect: の SQL に OR が含まれる。organization_id の絞り込みが選言に入っていると他テナントの行を返す。単一テナントに閉じていることを確認する',
    );
  }
}

function lintEntry(findings, entry) {
  // entry.text ではなく head に、さらに head の中でもチェックボックス直後に限定する。
  // text だと「注: 未実行の行には draft: を付ける」という注記だけで実行済み行が未実行扱いになり、
  // head 全体を見ると「ステータスが draft: のまま」のような本文と未実行マーカーが区別できない。
  // 置ける位置は verification-format.md が定めている。ENTRY_START を再利用するのは、
  // チェックボックス構文を 2 箇所に分けて片方だけ更新される事故を避けるため
  const isDraft = /^draft:/.test(entry.head.replace(ENTRY_START, ''));

  const sqls = [...entry.text.matchAll(SIDE_EFFECT_WITH_SQL)].map((m) => m[1]);
  const sideEffectCount = [...entry.text.matchAll(SIDE_EFFECT_ANY)].length;

  if (sideEffectCount === 0) {
    findings.error(entry.line, 'Driving 行に Side effect: が無い（副作用の読み戻しが 3 点セットの 1 つ）');
  } else if (sqls.length < sideEffectCount) {
    findings.error(entry.line, 'Side effect: の SQL がバッククォートで囲まれていない');
  }

  // flags は Side effect: の全出現に対応する。SQL がバッククォートで囲まれていない行があると
  // sqls 側が短くなり対応がずれるが、その場合は上で既に error を出しているので実害はない
  const noTenantFlags = collectNoTenantFlags(entry);
  sqls.forEach((sql, index) => {
    lintSql(findings, entry, sql, noTenantFlags[index] === true);
  });

  if (!/expected\s*:/.test(entry.text)) {
    findings.error(entry.line, 'Driving 行に expected: が無い（期待値の無い行は 3 工程のどこでも判定に使えない）');
  }

  // 未実行の行は actual を測っていないのが正常。draft: を外した行に actual が無い場合は
  // 「実行したつもりで測っていない」状態なので error にする
  if (!isDraft && !/actual\s*:/.test(entry.text)) {
    findings.error(entry.line, 'draft: の無い Driving 行に actual: が無い（実行済みなら実測値を転記する）');
  }

  return isDraft;
}

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], {
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
}

/**
 * 同ディレクトリの spec.md の最終コミットが verification.md より新しければ warn。
 * 「spec.md を直したが verification.md を追従させていない」状態の検知。
 *
 * 判定に本文の `最終更新:` を使わないのは、その行を持つ spec.md が少数派で warn が
 * 原理的に発火しないうえ、比較軸が編集者の手入力に依存してしまうため。
 */
function lintSpecFollowUp(findings, file) {
  // git -C <root> に渡すパスは絶対にする。cwd 相対のまま渡すと、リポジトリルート以外から
  // 起動したときに git 側で解決できず、しかも失敗として現れない:
  // git status は一致 0 件で素通りし、git log が空を返して「コミットが無い」に化ける。
  // 結果、この追従チェックが無言で無効化する
  file = resolve(file);
  const specPath = join(dirname(file), 'spec.md');
  if (!existsSync(specPath)) {
    return;
  }

  let repo;
  try {
    repo = git(dirname(file), ['rev-parse', '--show-toplevel']);
  } catch {
    findings.info('git リポジトリ外のため spec.md の追従チェックをスキップした');
    return;
  }

  let dirty;
  try {
    dirty = git(repo, ['status', '--porcelain', '--', file, specPath]);
  } catch {
    findings.info('git status に失敗したため spec.md の追従チェックをスキップした');
    return;
  }
  if (dirty !== '') {
    // 作業中の verification.md は未コミットゆえ「古い」と判定される。commit 前に lint を
    // 回す運用での偽陽性を避けるためスキップする
    findings.info('対象ファイルが未コミットのため spec.md の追従チェックをスキップした');
    return;
  }

  let specTime;
  let verificationTime;
  try {
    specTime = git(repo, ['log', '-1', '--format=%ct', '--', specPath]);
    verificationTime = git(repo, ['log', '-1', '--format=%ct', '--', file]);
  } catch {
    findings.info('git log に失敗したため spec.md の追従チェックをスキップした');
    return;
  }
  if (specTime === '' || verificationTime === '') {
    findings.info('spec.md または verification.md に一致するコミットが無いため追従チェックをスキップした');
    return;
  }

  if (Number(specTime) > Number(verificationTime)) {
    findings.warn(
      1,
      'spec.md の最終コミットが verification.md より新しい。変わった Requirement に対応する Driving 行を見直し、変えた行に draft: を戻す（/verification-authoring）',
    );
  }
}

function lintFile(file) {
  const findings = new Findings(file);

  if (!existsSync(file)) {
    findings.error(1, 'ファイルが存在しない');
    return findings;
  }
  if (basename(file) !== 'verification.md') {
    findings.info(`ファイル名が verification.md ではない（${basename(file)}）`);
  }

  const lines = readFileSync(file, 'utf-8').split('\n');
  const headings = collectHeadings(lines);

  for (const heading of REQUIRED_HEADINGS) {
    if (!headings.has(heading)) {
      findings.error(1, `必須の見出し \`## ${heading}\` が無い`);
    }
  }

  const drivingLine = headings.get(DRIVING_HEADING);
  if (drivingLine === undefined) {
    return findings;
  }

  const entries = collectDrivingEntries(lines, drivingLine);
  if (entries.length === 0) {
    findings.error(drivingLine, '`## Driving it` に Driving 行が 1 行も無い');
    return findings;
  }

  let draftCount = 0;
  for (const entry of entries) {
    if (lintEntry(findings, entry)) {
      draftCount += 1;
    }
  }

  if (draftCount > 0) {
    findings.warn(
      drivingLine,
      `未実行の Driving 行が ${draftCount} / ${entries.length} 行ある（draft: が残る状態を「検証済み」として報告しない）`,
    );
  }

  lintSpecFollowUp(findings, file);

  return findings;
}

function main(argv) {
  const files = argv.slice(2);
  if (files.length === 0) {
    console.error('usage: node verification-lint.mjs <path-to-verification.md> [more...]');
    console.error('  検査対象パスは必須（暗黙のパス解決はしない）');
    return 1;
  }

  let errorCount = 0;
  let warnCount = 0;

  for (const file of files) {
    const findings = lintFile(file);
    for (const message of findings.errors) {
      console.error(`ERROR ${message}`);
    }
    for (const message of findings.warns) {
      console.warn(`WARN  ${message}`);
    }
    for (const message of findings.infos) {
      console.log(`INFO  ${message}`);
    }
    errorCount += findings.errors.length;
    warnCount += findings.warns.length;
  }

  console.log(`\n${files.length} file(s): ${errorCount} error / ${warnCount} warn`);
  return errorCount > 0 ? 1 : 0;
}

// process.exit ではなく exitCode に代入する（stdout がパイプの場合に出力が切り捨てられるため）
process.exitCode = main(process.argv);
