#!/bin/bash

# =============================================================================
# Claude Skills & SubAgents セットアップスクリプト
# =============================================================================
#
# このスクリプトは、リポジトリ内の Skills, Agents (subagent 定義), settings.json を ~/.claude/ 配下に
# シンボリックリンクとして、Scripts を実体コピーとして配置します。
# これにより、すべてのプロジェクトで共通して使用できるようになります。
#
# ~/.codex が在れば、Codex にも同じ資産を展開します（無ければ省略。~/.codex は作りません）:
#   - skills  ~/.agents/skills/<name> への symlink（衝突する他者の実体・リンクは触らず warn）
#   - agents  agents の .md から TOML を生成して ~/.codex/agents/ へ（手書きの TOML は触らない）
#   - 規約    ~/.codex/AGENTS.md のマーカーブロック 2 つ（共通規約と、Codex 専用の読み替え表）
#   - hook    ~/.codex/hooks.json の自前エントリだけ（Muxy・Orca 等の位置を動かさない）
#
# 使用方法:
#   ./setup.sh          # インストール（デフォルト）
#   ./setup.sh install  # インストール
#   ./setup.sh uninstall # アンインストール
#   ./setup.sh status   # 現在の状態を表示
#   ./setup.sh migrate  # 旧形式 (commands→skill 化されたディレクトリ・旧配置先の subagent リンク) を撤去し、旧 claude/ を指す skills・agents のリンクを shared/ へ張り替える
#
# 注: 過去に commands/ から疑似的に skill 化していた構造は廃止されました。
#     旧バージョンで install したユーザーは migrate サブコマンドで一括移行できます。
#
# =============================================================================

set -e

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# パス定義
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 共通資産（Claude Code・Codex の両方が使うもの）は shared/ に置く。claude/ に残るのは Claude Code 固有の settings.json だけ
REPO_SKILLS_DIR="${SCRIPT_DIR}/shared/skills"
REPO_SCRIPTS_DIR="${SCRIPT_DIR}/shared/scripts"
REPO_GLOBAL_RULES="${SCRIPT_DIR}/shared/global-rules.md"
REPO_COMMANDS_DIR="${SCRIPT_DIR}/claude/commands"
# Claude Code がユーザーレベルの subagent を読み込むのは ~/.claude/agents/ だけ（サブフォルダも再帰的に読む）
REPO_AGENTS_DIR="${SCRIPT_DIR}/shared/agents"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_SKILLS_DIR="${CLAUDE_DIR}/skills"
CLAUDE_AGENTS_DIR="${CLAUDE_DIR}/agents"

# Codex の配置先。skill は Claude Code と別の ~/.agents/skills（他のツールも書き込む共有の場所）を読み、
# custom agent は ~/.codex/agents/*.toml、グローバルの指示は ~/.codex/AGENTS.md、hook は ~/.codex/hooks.json
CODEX_DIR="${HOME}/.codex"
CODEX_SKILLS_DIR="${HOME}/.agents/skills"
CODEX_AGENTS_DIR="${CODEX_DIR}/agents"
CODEX_AGENTS_MD="${CODEX_DIR}/AGENTS.md"
CODEX_HOOKS_JSON="${CODEX_DIR}/hooks.json"
REPO_CODEX_RULES="${SCRIPT_DIR}/codex/codex-rules.md"
REPO_GEN_AGENTS="${SCRIPT_DIR}/codex/gen-agents.py"
# gen-agents.py が出力する TOML の 1 行目の先頭。「自分が置いたもの」の目印（uninstall・orphan 判定）
GEN_HEADER_PREFIX="# generated-by: gamonges-prompt setup.sh"
# install の段のうち失敗したものの名前（run_stage が積む）
STAGE_FAILURES=()
# install・uninstall・migrate を直列化するロック（acquire_lock）
SETUP_LOCK="${CLAUDE_DIR}/.setup.lock"
# Codex の /hooks で信頼を確かめる案内を、install の最後に出すか（install_codex が決める）
CODEX_TRUST_NOTICE=false
CODEX_RULES_BEGIN="<!-- BEGIN gamonges-prompt: codex 読み替え表 -->"
CODEX_RULES_END="<!-- END gamonges-prompt: codex 読み替え表 -->"

# ヘルパー関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# setup.sh 同士の並行実行を止める。固定名の一時ファイルの衝突と、rm → ln -s の間に別の install がリンクを
# 作ると BSD の ln がその先（チェックアウトの中）に自己参照リンクを作る問題があるため。書き込み先を HOME で共有し、
# メインと worktree の両方から install されうるので、repo ではなく HOME に置く。
# 残骸のロックは自動で奪わない（2 本が同時に奪う窓を作らない）。EXIT trap はサブシェル（run_stage の段）では
# 発火しないので、段が終わってもロックは外れない
acquire_lock() {
    mkdir -p "$CLAUDE_DIR" 2>/dev/null || true
    if ! mkdir "$SETUP_LOCK" 2>/dev/null; then
        # ロックが無いのに失敗した（その間に他方が外した）ときは 1 回だけやり直す
        if [[ -d "$SETUP_LOCK" ]] || ! mkdir "$SETUP_LOCK" 2>/dev/null; then
            if [[ -d "$SETUP_LOCK" ]]; then
                report_lock_held
            fi
            log_error "  ✗ ロックを作れません: ${SETUP_LOCK}（~/.claude の権限を確かめてください）"
            exit 1
        fi
    fi
    # pid を書く前に trap を張る（書く前に止まってもロックを残さない）。trap の中は失敗させない
    # （EXIT trap の中のコマンドが失敗すると終了コードが変わる）
    trap 'rm -rf "$SETUP_LOCK" 2>/dev/null || true' EXIT
    echo "$$" >"$SETUP_LOCK/pid"
}

report_lock_held() {
    local pid comm
    pid=$(cat "$SETUP_LOCK/pid" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
        log_error "  ✗ 別の setup.sh が実行中です（PID 不明: ロックの取得の直後）。終わってから実行し直してください。続くようなら、他に setup.sh が動いていないことを確かめてから rm -rf ~/.claude/.setup.lock で消してください"
    elif comm=$(ps -p "$pid" -o comm= 2>/dev/null) && [[ -n "$comm" ]]; then
        log_error "  ✗ 別の setup.sh が実行中です（PID ${pid}: ${comm}）。終わってから実行し直してください（ロック: ${SETUP_LOCK}）"
    else
        log_error "  ✗ ロック ${SETUP_LOCK} が残っていますが、PID ${pid} は動いていません（前の実行が強制終了された可能性があります）。他に setup.sh が動いていないことを確かめてから、rm -rf ~/.claude/.setup.lock で消して実行し直してください"
    fi
    exit 1
}

# 一時リンクを mv -h で名前ごと置き換える。リンクが無い瞬間を作らず、既存のリンク先ディレクトリの中へ入らないため。
# 置き換え先は symlink か不在であること（実ディレクトリなら mv -h もその中へ移す）。一時名をドットで始めるのは、
# ln と mv の間で強制終了されたとき、残骸が同名の skill の重複として読み込まれにくくするため
replace_link() {  # $1=リンク先, $2=リンクのパス
    local tmp
    tmp="$(dirname "$2")/.$(basename "$2").tmp.$$"
    ln -sfn "$1" "$tmp"
    mv -fh "$tmp" "$2"
}

# install の段を走らせ、失敗しても続行して段の名前を STAGE_FAILURES に積む。段は ( set -e; … ) で走らせる。
# f || … ・if ! f の形で呼ぶと f の中の set -e が無効になり、段の内部の失敗が黙って消えるため。
# 段の中で変えた変数は呼び出し元に戻らない。run_stage を呼ぶ関数を ||・if の条件の中で呼ばない
# （外側が ||・if の文脈だと、サブシェルの set -e も効かない）
run_stage() {  # $1=段名, $2...=コマンド
    local label="$1" rc
    shift
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        STAGE_FAILURES+=("$label")
    fi
    return 0
}

# ディレクトリの存在確認
check_source_dirs() {
    if [[ ! -d "$REPO_SKILLS_DIR" ]]; then
        log_error "Skills ディレクトリが見つかりません: $REPO_SKILLS_DIR"
        exit 1
    fi
}

# ~/.claude ディレクトリの初期化
init_claude_dir() {
    if [[ ! -d "$CLAUDE_DIR" ]]; then
        log_info "~/.claude ディレクトリを作成します..."
        mkdir -p "$CLAUDE_DIR"
    fi
    if [[ ! -d "$CLAUDE_SKILLS_DIR" ]]; then
        mkdir -p "$CLAUDE_SKILLS_DIR"
    fi
    if [[ ! -d "$CLAUDE_AGENTS_DIR" ]]; then
        mkdir -p "$CLAUDE_AGENTS_DIR"
    fi
}

# Settings のインストール (~/.claude/settings.json を repo 内 claude/settings.json への symlink にする)
install_settings() {
    log_info "Settings をインストールしています..."
    local source_file="${SCRIPT_DIR}/claude/settings.json"
    local target_link="${CLAUDE_DIR}/settings.json"

    if [[ ! -f "$source_file" ]]; then
        log_warning "  ! ソースファイルが存在しません: $source_file"
        return
    fi

    # ディレクトリ異常検知: 過去の install ミスで実ディレクトリ化していたら明示エラー
    if [[ -d "$target_link" && ! -L "$target_link" ]]; then
        log_error "  ✗ $target_link が実ディレクトリです。手動で確認してください"
        return 1
    fi

    # 既存 symlink で同一先なら skip、それ以外 (実ファイル含む) は退避してから atomic 置換
    if [[ -L "$target_link" ]] || [[ -e "$target_link" ]]; then
        local current_target=$(readlink "$target_link" 2>/dev/null || true)
        if [[ -L "$target_link" && "$current_target" == "$source_file" ]]; then
            log_success "  ✓ settings.json (既にリンク済み)"
            return
        fi
        # PID 付与で同一秒内の install 衝突回避 (macOS BSD date は %N 非対応のため PID を採用)
        local backup_path="${target_link}.pre-install.$(date +%Y%m%d%H%M%S)-$$"
        mv "$target_link" "$backup_path"
        log_warning "  ! 既存をバックアップ: $backup_path"
    fi

    # atomic 置換（固定名の一時リンクは、強制終了の後に残ると ln -s が File exists で失敗し続ける）
    replace_link "$source_file" "$target_link"
    log_success "  ✓ settings.json → $source_file"
}

# install 元が linked worktree なら警告する。
#
# settings.json と skills は symlink のままなので、install 元のチェックアウトを全プロジェクトの
# ランタイムが参照する。worktree から install すると、その worktree を削除した瞬間に
# deny リスト・hook 定義・全 skill がまとめて失われる。hook のように exit 127 がログに残る形ではなく
# Claude Code がデフォルト設定で静かに起動するため、スクリプト側の失敗モードより気づきにくい。
# 判定はパス非依存にする（メインチェックアウトの場所をハードコードしない）。
# 共通規約を ~/.claude/CLAUDE.md へ配置する
#
# 本リポジトリの CLAUDE.md は project スコープなので、他プロジェクトでは 1 行もロードされない。
# ~/.claude/CLAUDE.md は repo 管理外かつユーザーが手で編集するファイルなので、全置換はできない。
# マーカーで囲んだブロックだけを冪等に差し替え、ブロック外の記述には触れない。
GLOBAL_RULES_BEGIN="<!-- BEGIN gamonges-prompt: skills 共通規約 -->"
GLOBAL_RULES_END="<!-- END gamonges-prompt: skills 共通規約 -->"

# 一時ファイルで置き換え先を差し替える。置き換え先が symlink のときは、リンクを通常ファイルに
# 置き換えて壊さないよう、リンク先へ書き込む（dotfiles への symlink にしている場合）。
# 通常ファイルのときは置き換え先の mode を一時ファイルに写す（mktemp は 0600 で作るので、写さないと mode が変わる）
replace_file() {  # $1=一時ファイル, $2=置き換え先
    if [[ -L "$2" ]]; then
        cat "$1" > "$2" || { rm -f "$1"; return 1; }   # rm の終了コードで cat の失敗を上書きしない
        rm -f "$1"
    else
        if [[ -f "$2" ]]; then chmod "$(stat -f %Lp "$2")" "$1" 2>/dev/null || true; fi
        mv -f "$1" "$2" || return 1
    fi
}

# BEGIN・END は行の完全一致で数える。部分一致で判定すると、書き込みの awk（行の完全一致）と食い違い、
# BEGIN 以降を消す
marker_shape() {  # $1=ファイル, $2=BEGIN 行, $3=END 行 → none | ok | bad
    awk -v b="$2" -v e="$3" '
        $0 == b { nb++; if (open) bad = 1; open = 1; next }
        $0 == e { ne++; if (!open) bad = 1; open = 0; next }
        END { if (!nb && !ne) print "none"; else if (bad || open || nb != 1 || ne != 1) print "bad"; else print "ok" }
    ' "$1"
}

# マーカーで囲んだブロックだけを冪等に追記・差し替える（ブロック外の記述には触れない）。
#   $1=書き込み先, 以降は 4 つ組（表示名, ブロックの中身のファイル, BEGIN 行, END 行）の繰り返し
# 同じファイルの複数のブロックは、写しに順に適用し、すべて成功したときだけ 1 回で置き換える（1 つ目を書いた後に
# 2 つ目で失敗すると、半端な状態が残る）。マーカーの並びが「BEGIN 行 1 つ・その後ろに END 行 1 つ」でなければ、
# 書き込まずに失敗する。差し替えの awk は BEGIN から END までを読み飛ばすので、END が無い・前にある等では
# BEGIN 以降（ユーザーが書いた記述を含む）が消える。
# この関数は if !・|| の中から呼ばれうる（set -e が効かない）ので、各書き込みの失敗を自分で返す
install_marker_blocks() {
    local dest="$1" tmp next label src begin end shape i
    local labels=() srcs=() begins=() ends=() done_msgs=()
    shift
    while [[ $# -ge 4 ]]; do
        if [[ -f "$2" ]]; then
            labels+=("$1") srcs+=("$2") begins+=("$3") ends+=("$4")
        else
            log_warning "  ! ${2} がありません。${1}の配置をスキップします"
        fi
        shift 4
    done
    # 中身のファイルが 1 つも無ければ dest に触れない（空の写しで置き換えると、無かったファイルを作る）
    [[ ${#labels[@]} -gt 0 ]] || return 0

    mkdir -p "$(dirname "$dest")" || return 1
    tmp=$(mktemp "${dest}.XXXXXX") || return 1
    if [[ -f "$dest" ]]; then
        # 読めなければ止める（握りつぶすと空の写しから組み立て、個人部分を消す）
        cat "$dest" >"$tmp" 2>/dev/null || { rm -f "$tmp"; log_error "  ✗ ${dest} を読めません（権限を確かめてください）。書き込まずに中断します"; return 1; }
    else
        # mktemp は 0600 で作るので、新規のファイルは umask に従わせる
        chmod "$(printf '%o' $(( 0666 & ~$(umask) )))" "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    for i in "${!labels[@]}"; do
        label="${labels[$i]}" src="${srcs[$i]}" begin="${begins[$i]}" end="${ends[$i]}"
        shape=$(marker_shape "$tmp" "$begin" "$end" 2>/dev/null) || shape=error
        case "$shape" in
            ok)
                # 既存ブロックの中身だけを差し替える。写しの mode を保つため、mv でなく cat で戻す
                next=$(mktemp "${dest}.XXXXXX") || { rm -f "$tmp"; return 1; }
                awk -v b="$begin" -v e="$end" -v f="$src" '
                    $0 == b { print; while ((getline line < f) > 0) print line; close(f); skip = 1; next }
                    $0 == e { skip = 0 }
                    !skip
                ' "$tmp" >"$next" && cat "$next" >"$tmp" || { rm -f "$tmp" "$next"; return 1; }
                rm -f "$next"
                done_msgs+=("${label}を更新しました")
                ;;
            none)
                # 既存の中身の後ろに空行 1 行（ファイルが無いときも置く）・BEGIN・中身・END。中身が改行で終わらなければ
                # END の前に改行を足す（END が中身の最終行にくっつくと、次の install で END が見つからない）
                { echo "" && echo "$begin" && cat "$src" && { [[ -z "$(tail -c1 "$src")" ]] || echo ""; } && echo "$end"; } >>"$tmp" \
                    || { rm -f "$tmp"; return 1; }
                done_msgs+=("${label}を追記しました")
                ;;
            *)
                log_error "  ✗ ${dest} の ${label}のマーカーの並びが不正です（BEGIN 行 1 つ・その後ろに END 行 1 つが必要）。BEGIN 以降を消さないよう、書き込まずに中断します"
                rm -f "$tmp"
                return 1
                ;;
        esac
    done

    # 後のブロックの差し替えが前のブロックを消すことがある（入れ子の並び）。適用したブロックがすべて残っていることを
    # 確かめてから置き換える
    for i in "${!labels[@]}"; do
        if [[ "$(marker_shape "$tmp" "${begins[$i]}" "${ends[$i]}" 2>/dev/null)" != ok ]]; then
            log_error "  ✗ ${dest} の ${labels[$i]}のマーカーの並びが不正です（ブロックが入れ子になっている等）。BEGIN 以降を消さないよう、書き込まずに中断します"
            rm -f "$tmp"
            return 1
        fi
    done

    replace_file "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    for i in "${!done_msgs[@]}"; do
        log_success "  ✓ ${done_msgs[$i]}"
    done
}

# マーカーで囲んだブロックだけを撤去する。並びが不正なら撤去せずに残す（awk が BEGIN 以降を全部消すため）
uninstall_marker_block() {  # $1=表示名, $2=対象ファイル, $3=BEGIN 行, $4=END 行
    local label="$1" dest="$2" begin="$3" end="$4" shape
    [[ -f "$dest" ]] || return 0
    shape=$(marker_shape "$dest" "$begin" "$end" 2>/dev/null) || shape=error
    case "$shape" in
        none) return 0 ;;
        ok) ;;
        error)
            log_warning "  ! ${dest} を読めません（権限を確かめてください）。${label}は撤去せずに残します"
            return 0
            ;;
        *)
            log_warning "  ! ${dest} の ${label}のマーカーの並びが不正です。${label}は撤去せずに残します（BEGIN 以降を消さないため）"
            return 0
            ;;
    esac
    local tmp="${dest}.new.$$"
    # 追記のときに足した区切りの空行（BEGIN の直前の 1 行）も一緒に落とし、install → uninstall で元に戻す
    awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; held = 0; next }
        skip { if ($0 == e) skip = 0; next }
        held { print ""; held = 0 }
        $0 == "" { held = 1; next }
        { print }
        END { if (held) print "" }
    ' "$dest" > "$tmp"
    replace_file "$tmp" "$dest"
    log_success "  ✓ 削除: ${label}（ブロック外の記述は保持）"
}

install_global_rules() {
    install_marker_blocks "${CLAUDE_DIR}/CLAUDE.md" \
        "CLAUDE.md の共通規約ブロック" "$REPO_GLOBAL_RULES" "$GLOBAL_RULES_BEGIN" "$GLOBAL_RULES_END"
}

warn_if_worktree() {
    local git_dir git_common
    git_dir=$(git -C "$SCRIPT_DIR" rev-parse --git-dir 2>/dev/null) || return 0
    git_common=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null) || return 0
    if [[ "$git_dir" != "$git_common" ]]; then
        log_warning "  ! linked worktree から実行しています: ${SCRIPT_DIR}"
        log_warning "    settings.json / skills の symlink がこの worktree を指すため、削除すると設定が失われます"
        log_warning "    可能ならメインチェックアウトから install してください"
    fi
}

# 前回 install 時の commit の中の shared/scripts/<name> のパスを返す（無ければ非 0 で、初回として扱う）。
# 前回 sha が shared/ 移行前（claude/scripts/ だけを持つ）なら見つからず、ローカル改変を退避せずに上書きする。
# 移行前の sha からの install は移行の PR（#25）の時点で済んでいるので、旧パスは探さない
prev_tree_path() {  # $1=sha, $2=スクリプト名
    local p="shared/scripts/$2"
    git -C "$SCRIPT_DIR" cat-file -e "$1:$p" 2>/dev/null || return 1
    printf '%s\n' "$p"
}

# Scripts のインストール（実体コピー）
#
# skills は symlink のままだが scripts は実体をコピーする。symlink だとメインチェックアウトが
# スクリプトを含まないブランチにある間に解決できなくなり、全 hook が exit 127 で失敗する。
# exit 127 は non-blocking error でツール呼び出しは素通りするため、tmp/ コミット禁止・
# 破壊的 git の確認・一括フォーマット禁止のガードレールが「止まる」のではなく「開く」。
# scripts は skills と違って変更頻度が低いので、即時反映を捨てて確実性を取る。
install_scripts() {
    local prune="${1:-false}"
    log_info "Scripts をインストールしています（実体コピー）..."
    local scripts_dir="$REPO_SCRIPTS_DIR"
    local target_dir="${CLAUDE_DIR}/scripts"
    mkdir -p "$target_dir"

    local count=0

    # 前回 install 時の commit を 1 回だけ読む。install 全体で同じ基準を使うため、
    # スクリプトごとのループ内では読み直さない
    local prev_sha=""
    if [[ -f "${target_dir}/.installed-from" ]]; then
        prev_sha=$(cut -f3 "${target_dir}/.installed-from" 2>/dev/null || true)
    fi

    for script in "$scripts_dir"/*.sh "$scripts_dir"/*.py; do
        [ -f "$script" ] || continue
        local name=$(basename "$script")
        local target="${target_dir}/${name}"

        # 旧形式（symlink）が残っていれば除去してから実体を配置する
        if [[ -L "$target" ]]; then
            rm "$target"
        elif [[ -d "$target" ]]; then
            # ディレクトリのままだと cp が中に潜り込み chmod +x がディレクトリに当たる。
            # その状態で hook が起動すると exit 126 = 本方式が排除したい失敗モードと同型
            log_warning "  ! ${name} はディレクトリです。退避します"
            mv "$target" "${target}.backup.$(date +%Y%m%d%H%M%S).$$"
        elif [[ -f "$target" ]] && ! cmp -s "$script" "$target"; then
            # repo 側と差分がある。ただし cmp だけでは「repo が更新された」と
            # 「インストール先が手で改変された」を区別できず、CLAUDE.md が推奨する標準運用
            # （shared/scripts/ を編集 → ./setup.sh install）そのものが毎回警告を出して
            # .backup.* を積み上げる。常時点灯する警告は無視されるようになるため、
            # .installed-from の sha から前回 install 時の内容を復元して突き合わせ、
            # そこから変わっているものだけを「ローカル改変」と判定する。
            # 前回 sha が無い / その sha にファイルが無い（新規追加スクリプト）場合は初回と
            # みなす。初回に守るべきローカル改変は定義上存在しないので退避しない
            local prev_path=""
            if [[ -n "$prev_sha" ]]; then
                prev_path=$(prev_tree_path "$prev_sha" "$name" || true)
            fi
            if [[ -n "$prev_path" ]] \
                && ! git -C "$SCRIPT_DIR" show "${prev_sha}:${prev_path}" 2>/dev/null | cmp -s - "$target"; then
                cp "$target" "${target}.backup.$(date +%Y%m%d%H%M%S).$$"
                log_warning "  ! ${name} はローカル改変あり。バックアップしました"
            fi
        fi

        # hook は常時発火するため、上書き中のファイルが別セッションから実行されうる。
        # install_settings と同じく rename(2) によるアトミック置換にする
        cp "$script" "${target}.new"
        chmod +x "${target}.new"
        mv -f "${target}.new" "$target"
        log_success "  ✓ ${name}"
        count=$((count + 1))
    done

    # 実体コピーでは symlink と違いリンク先から由来が読めない。
    # 「どのチェックアウトから install したか」を verify-skills.sh の check 4 が照合できるよう記録する
    printf '%s\t%s\t%s\n' "$SCRIPT_DIR" \
        "$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" \
        "$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        > "${target_dir}/.installed-from"

    # repo から削除されたスクリプトの検出。repo 起点のループでは見えないため逆方向に走査する。
    # 既定を警告に留めるのは ~/.claude/scripts/ にユーザーが手で置いたスクリプトがありうるため
    local orphans=()
    for installed in "$target_dir"/*.sh "$target_dir"/*.py; do
        [ -e "$installed" ] || [ -L "$installed" ] || continue
        local n=$(basename "$installed")
        [ -f "${scripts_dir}/${n}" ] && continue
        orphans+=("$n")
    done

    if [ ${#orphans[@]} -gt 0 ]; then
        if [[ "$prune" == true ]]; then
            local backup_dir="${target_dir}/.orphan-backup.$(date +%Y%m%d%H%M%S).$$"
            mkdir -p "$backup_dir"
            local n
            for n in "${orphans[@]}"; do
                # 緑の「✓」を使わないのは、退避が「成功」ではなく注意すべき操作だから。
                # ~/.claude/scripts/ にはユーザーが手で置いたスクリプトもありうるため、
                # dangling symlink（復元価値なし）と実体ファイル（手置きの可能性）を区別する
                if [[ -L "${target_dir}/${n}" && ! -e "${target_dir}/${n}" ]]; then
                    log_warning "  ! 退避: ${n} (dangling symlink) → ${backup_dir}/"
                else
                    log_warning "  ! 退避: ${n} (実体ファイル。手置きの可能性あり) → ${backup_dir}/"
                fi
                mv "${target_dir}/${n}" "${backup_dir}/${n}"
            done
            log_info "  orphan ${#orphans[@]} 件を ${backup_dir} へ退避しました（削除ではなく退避。不要なら手で消す）"
        else
            local n
            for n in "${orphans[@]}"; do
                log_warning "  ! ${n} は repo に存在しません（orphan）"
            done
            log_warning "  削除するには: ./setup.sh install --prune-scripts"
        fi
    fi

    log_info "Scripts: ${count} 件インストール完了（スクリプト編集後は ./setup.sh install の再実行が必要）"
}

# 「自分のリンク」か。Codex 側の install・uninstall・status と verify-skills.sh の check 8 で同じ本体を使う
# （互いを source しないので複製し、verify の check 7(1) が一致を確かめる）。
# ~/.agents/skills は他のツールと共有する場所なので、パターンだけで自分と判定しない。リンク先が実在すれば
# git の共通ディレクトリで本 repo か確かめ、切れているときだけパターンで判定する。
# 今のチェックアウトとの完全一致にはしない: 同じ repo の別 worktree を指すリンク（worktree からの一時
# install で生じる）を他者のものと誤判定すると、worktree を消した後に install は skip・uninstall は
# 対象外・verify は warn のままになり、誰も直さない切れたリンクが残る
own_git_common() {  # $1=ディレクトリ → git の共通ディレクトリ（絶対パス。git でなければ空）
    git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

is_own_skill_link() {  # $1=リンク, $2=skill 名, $3=本 repo のルート
    local target root own_common
    target=$(readlink "$1" 2>/dev/null) || return 1
    # 相対パスはリンクのディレクトリ基準で解く（cwd 基準で解くと、自分の repo を指す相対リンクを他者と判定する）
    [[ $target == /* ]] || target="$(dirname "$1")/$target"
    # 今のチェックアウトそのもの（/tmp と /private/tmp の表記違いを含む）なら git を起動しない
    if [[ -e "$1" && "$(realpath "$target" 2>/dev/null)" == "$(realpath "$3/shared/skills/$2" 2>/dev/null)" ]]; then
        return 0
    fi
    case "$target" in
        */shared/skills/"$2"|*/shared/skills/"$2"/|*/claude/skills/"$2"|*/claude/skills/"$2"/) ;;
        *) return 1 ;;
    esac
    # 切れたリンクは、どの repo のものかを確かめようがないのでパターンで判定する
    [[ -e "$1" ]] || return 0
    root="${target%/*/skills/*}"
    own_common=$(own_git_common "$3")
    if [[ -n "$own_common" ]]; then
        [[ "$(own_git_common "$root")" == "$own_common" ]]
    else
        # git でないチェックアウト: 空どうしで一致させず、repo のルートの実パスで比べる
        [[ "$(realpath "$root" 2>/dev/null)" == "$(realpath "$3" 2>/dev/null)" ]]
    fi
}

# Skills のインストール
#   $1=表示名, $2=配置先, $3=衝突時の扱い（既存の実ディレクトリ・自分のリンクでない symlink に当たったとき）
#     backup = 実ディレクトリは <name>.backup.* へ退避し、symlink はリンク先を問わず張り替える（Claude 側の従来の挙動）
#     skip   = 上書きも退避もせず warn して次へ（Codex 側）。~/.agents/skills は skills CLI や他のツールも
#              書き込む共有の場所で、他者の実体を動かさない。退避は走査対象の中に <name>.backup.* を作り、
#              退避先の SKILL.md も読まれて同名の skill が 2 つになる
install_skills() {
    local label="${1:-Skills}" dst_dir="${2:-$CLAUDE_SKILLS_DIR}" collision="${3:-backup}"
    log_info "${label} をインストールしています..."
    mkdir -p "$dst_dir"

    local count=0 skipped=0
    for skill_dir in "$REPO_SKILLS_DIR"/*/; do
        if [[ -d "$skill_dir" ]]; then
            local skill_name=$(basename "$skill_dir")
            # _ プレフィックスは雛形 / プライベート用としてスキップ
            [[ "$skill_name" == _* ]] && continue
            local target_link="${dst_dir}/${skill_name}"

            # 既に正しい先を指しているなら触らない。変更が無いのに毎回 rm → ln -s すると
            # symlink が存在しない窓が開き、併走セッションの skill ロードが失敗しうる
            # （install は Claude Code セッション内から走り、複数 worktree が併走する）
            if [[ ! -L "$target_link" || "$(readlink "$target_link")" != "$skill_dir" ]]; then
                if [[ "$collision" == skip ]]; then
                    if [[ -L "$target_link" ]] && is_own_skill_link "$target_link" "$skill_name" "$SCRIPT_DIR"; then
                        log_warning "既存のシンボリックリンクを更新: ${skill_name}"
                    elif [[ -e "$target_link" || -L "$target_link" ]]; then
                        # 他者の実体に SKILL.md があれば、その名前で呼ぶと repo の skill ではなく他者の skill が起動する
                        if [[ -f "$target_link/SKILL.md" ]]; then
                            log_warning "  ! ${target_link} は repo の skill ではありません（他のツールの実体・リンク）。上書きせず配置をスキップします。\$${skill_name} を呼ぶと、この別の skill が起動します（${label} では repo の ${skill_name} が使えません）"
                        else
                            log_warning "  ! ${target_link} は repo の skill ではありません（他のツールの実体・リンク）。同名の他者のリンク・実体があるので、repo の ${skill_name} を張りませんでした"
                        fi
                        skipped=$((skipped + 1))
                        continue
                    fi
                else
                    # 既存のリンクはそのまま置き換え、実体（ディレクトリ・ファイル）は退避する。replace_link の置き換え先は
                    # symlink か不在に限る（実ファイルを黙って上書きせず、実ディレクトリの中へ一時リンクを入れない）
                    if [[ -L "$target_link" ]]; then
                        log_warning "既存のシンボリックリンクを更新: ${skill_name}"
                    elif [[ -e "$target_link" ]]; then
                        log_warning "既存の実体をバックアップ: ${skill_name}"
                        mv "$target_link" "${target_link}.backup.$(date +%Y%m%d%H%M%S).$$"
                    fi
                fi

                replace_link "$skill_dir" "$target_link"
            fi

            # skill 内 scripts/*.sh に実行権限を付与（symlink 経由でも実行可能にする）
            # find 自体の exit code は -exec の最終結果を反映しないため、失敗を明示検知
            if [[ -d "${skill_dir}scripts" ]]; then
                if ! find "${skill_dir}scripts" -name '*.sh' -type f -exec chmod +x {} + 2>&1; then
                    log_warning "  ! ${skill_name}/scripts への chmod に失敗"
                fi
            fi

            log_success "  ✓ ${skill_name}"
            count=$((count + 1))
        fi
    done

    log_info "${label}: ${count} 件インストール完了"
    if [[ "$skipped" -gt 0 ]]; then
        log_warning "${label}: ${skipped} 件は衝突のためスキップしました（上の ! の行）"
    fi
}

# Migrate: 旧形式 (commands→skill 化されたディレクトリ・旧配置先の subagent リンク) を撤去し、skills・agents のリンクを今の配置元（shared/）へ張り替える
# 過去の install_commands で作られた dead symlink + ディレクトリと、過去の install が張った subagent のリンクを安全に削除する
migrate() {
    log_info "旧形式 (commands→skill 化されたディレクトリ) を撤去しています..."

    local count=0
    for cmd_dir in "$CLAUDE_SKILLS_DIR"/*/; do
        [ -d "$cmd_dir" ] || continue
        local skill_link="${cmd_dir}SKILL.md"

        # SKILL.md が claude/commands/*.md への symlink になっているディレクトリのみ対象
        if [[ -L "$skill_link" ]]; then
            local link_target=$(readlink "$skill_link")
            if [[ "$link_target" == */claude/commands/*.md ]]; then
                rm "$skill_link"
                rmdir "$cmd_dir" 2>/dev/null || true
                log_success "  ✓ 撤去: $(basename "$cmd_dir")"
                ((count++))
            fi
        fi
    done

    log_info "旧形式の撤去: ${count} 件"

    # ~/.claude/sub-agents/ は Claude Code が読み込まない旧配置先。repo の claude/subagents/ を指すリンクだけを消し、
    # ユーザーの実ファイルと repo 外を指すリンクは残す。旧リンクはメインチェックアウトを指しているので、
    # worktree から実行しても一致するよう、リンク先をチェックアウトのパスではなく */claude/subagents/* で判定する
    local legacy_dir="${CLAUDE_DIR}/sub-agents"
    local legacy_count=0
    for legacy_link in "$legacy_dir"/*.md; do
        [[ -L "$legacy_link" ]] || continue
        if [[ "$(readlink "$legacy_link")" == */claude/subagents/* ]]; then
            rm "$legacy_link"
            log_success "  ✓ 撤去: sub-agents/$(basename "$legacy_link")"
            legacy_count=$((legacy_count + 1))
        fi
    done
    # 実ファイルが残っていると rmdir は失敗する。set -e で後続の install_skills まで止めないよう吸収する
    if [[ -d "$legacy_dir" ]]; then
        rmdir "$legacy_dir" 2>/dev/null || true
    fi
    log_info "旧配置先 (~/.claude/sub-agents/) のリンクの撤去: ${legacy_count} 件"

    echo ""
    install_skills
    # 旧 claude/agents/ を指す agents のリンク（互換 symlink を外した後は切れている）も shared/agents/ に張り替える
    echo ""
    install_md_links "Agents" "$REPO_AGENTS_DIR" "$CLAUDE_AGENTS_DIR"
    echo ""
    log_info "続けて ./setup.sh install を実行してください（scripts・settings.json・共通規約・Codex への展開は install が行う）"
}

# subagent 定義（.md）の symlink を張る・外す・状態を表示する（shared/agents/ → ~/.claude/agents/）。
# src 配下を再帰的に探し、dst には basename で平置きする。そのため name とファイル名を一致させ、ツリー全体で一意にする。
# README.md はドキュメント用なのでスキップする。
# show_status() の外に置くのは、verify-skills.sh が show_status() の本文を切り出して文字列検査するため。
# src が無いチェックアウト（shared/agents/ を持たない古いブランチ）では warning を出してスキップする。
# check_source_dirs のように exit すると skills / settings の install まで止まるため

install_md_links() {
    local label="$1" src_dir="$2" dst_dir="$3"
    log_info "${label} をインストールしています..."

    if [[ ! -d "$src_dir" ]]; then
        log_warning "  ! ${src_dir} がありません。${label} の配置をスキップします"
        return 0
    fi

    local count=0
    while IFS= read -r -d '' md_file; do
        local filename=$(basename "$md_file")
        [[ "$filename" == "README.md" ]] && continue

        local target_link="${dst_dir}/${filename}"

        # install_skills と同じ理由で、既に正しい先を指していれば触らない
        if [[ ! -L "$target_link" || "$(readlink "$target_link")" != "$md_file" ]]; then
            # 既存のリンクはそのまま置き換え、実体（ファイル・ディレクトリ）は退避する（install_skills と同じ理由）
            if [[ -L "$target_link" ]]; then
                log_warning "既存のシンボリックリンクを更新: ${filename}"
            elif [[ -e "$target_link" ]]; then
                log_warning "既存の実体をバックアップ: ${filename}"
                mv "$target_link" "${target_link}.backup.$(date +%Y%m%d%H%M%S).$$"
            fi

            replace_link "$md_file" "$target_link"
        fi
        log_success "  ✓ ${filename}"
        count=$((count + 1))
    done < <(find "$src_dir" -name "*.md" -type f -print0)

    log_info "${label}: ${count} 件インストール完了"
}

# 削除した件数は MD_LINKS_REMOVED に入れる（件数を stdout で返すとログと混ざるため）
uninstall_md_links() {
    local label="$1" src_dir="$2" dst_dir="$3"
    MD_LINKS_REMOVED=0

    if [[ ! -d "$src_dir" ]]; then
        log_warning "  ! ${src_dir} がありません。${label} の削除をスキップします"
        return 0
    fi

    while IFS= read -r -d '' md_file; do
        local filename=$(basename "$md_file")
        [[ "$filename" == "README.md" ]] && continue

        local target_link="${dst_dir}/${filename}"

        if [[ -L "$target_link" ]]; then
            local link_target=$(readlink "$target_link")
            if [[ "$link_target" == "$md_file" ]]; then
                rm "$target_link"
                log_success "  ✓ 削除: ${filename}"
                MD_LINKS_REMOVED=$((MD_LINKS_REMOVED + 1))
            fi
        fi
    done < <(find "$src_dir" -name "*.md" -type f -print0)
}

show_md_links_status() {
    local label="$1" src_dir="$2" dst_dir="$3"
    echo -e "${BLUE}[${label}]${NC} (${dst_dir})"

    if [[ ! -d "$src_dir" ]]; then
        echo "  (repo に ${src_dir} がありません)"
        return 0
    fi
    if [[ ! -d "$dst_dir" ]]; then
        echo "  (ディレクトリが存在しません)"
        return 0
    fi

    while IFS= read -r -d '' md_file; do
        local filename=$(basename "$md_file")
        [[ "$filename" == "README.md" ]] && continue

        local target_link="${dst_dir}/${filename}"

        if [[ -L "$target_link" ]]; then
            local link_target=$(readlink "$target_link")
            if [[ "$link_target" == "$md_file" ]]; then
                echo -e "  ${GREEN}✓${NC} ${filename} (リンク済み)"
            else
                echo -e "  ${YELLOW}!${NC} ${filename} (別のリンク先)"
            fi
        elif [[ -f "$target_link" ]]; then
            echo -e "  ${YELLOW}!${NC} ${filename} (実ファイルが存在)"
        else
            echo -e "  ${RED}✗${NC} ${filename} (未インストール)"
        fi
    done < <(find "$src_dir" -name "*.md" -type f -print0)
}

# =============================================================================
# Codex への展開（~/.codex が在るときだけ）
#
# 共通資産（shared/）は Claude Code と Codex の両方が使う。Codex には次の 4 つを置く:
#   - skills        ~/.agents/skills/<name>      symlink（Codex は ~/.claude/skills を読まない）
#   - agents        ~/.codex/agents/<name>.toml  agents の .md から生成（Codex は .md の定義を読まない）
#   - 規約          ~/.codex/AGENTS.md           マーカーブロック 2 つ（共通規約と、Codex 専用の読み替え表）
#   - hook          ~/.codex/hooks.json          自前の hook だけ（Muxy・Orca・他の主体の定義には触れない）
# どれも「自分が置いたもの」だけを作り直し・撤去する。
# =============================================================================

# 生成ヘッダを持つ TOML か（setup.sh が置いたもの）
is_generated_toml() {  # $1=ファイル
    [[ "$(head -n 1 "$1" 2>/dev/null)" == "$GEN_HEADER_PREFIX"* ]]
}

# agents の .md から Codex 用の TOML を生成して ~/.codex/agents/ に置く。
# 手書きの TOML（生成ヘッダが無いもの）は上書きも削除もしない。生成元に無くなった生成物は削除する。
# 生成に失敗したら何も書き込まない（古い物と新しい物が混ざった状態を残さない）
install_codex_agents() {
    log_info "Codex の agents (TOML) を生成して配置しています..."
    local work err
    work=$(mktemp -d)
    if ! python3 "$REPO_GEN_AGENTS" --repo-root "$SCRIPT_DIR" --out "$work/out" 2>"$work/err"; then
        err=$(cat "$work/err")
        rm -rf "$work"
        log_error "  ✗ agents の TOML 生成に失敗しました（何も書き込んでいません）: ${err}"
        return 1
    fi

    mkdir -p "$CODEX_AGENTS_DIR"
    local count=0 skipped=0 removed=0 gen name dst existing
    for gen in "$work"/out/*.toml; do
        [[ -f "$gen" ]] || continue
        name=$(basename "$gen")
        dst="${CODEX_AGENTS_DIR}/${name}"
        if [[ -e "$dst" || -L "$dst" ]]; then
            if ! is_generated_toml "$dst"; then
                log_warning "  ! ${dst} は手書きの TOML です。上書きせず配置をスキップします（Codex では repo の agent ${name%.toml} が使えません）"
                skipped=$((skipped + 1))
                continue
            fi
            if cmp -s "$gen" "$dst"; then
                count=$((count + 1))
                continue
            fi
        fi
        cp "$gen" "${dst}.new.$$"
        mv -f "${dst}.new.$$" "$dst"
        log_success "  ✓ ${name}"
        count=$((count + 1))
    done

    # 生成元に無くなった生成物（agent の削除・改名）。生成物なので退避せずに削除する
    for existing in "$CODEX_AGENTS_DIR"/*.toml; do
        [[ -f "$existing" ]] || continue
        is_generated_toml "$existing" || continue
        [[ -f "$work/out/$(basename "$existing")" ]] && continue
        rm "$existing"
        log_warning "  ! 削除: $(basename "$existing")（repo に対応する agent が無い生成物）"
        removed=$((removed + 1))
    done
    rm -rf "$work"
    log_info "Codex agents: ${count} 件が最新（手書きと衝突してスキップ ${skipped} 件・生成元が無く削除 ${removed} 件）"
}

# hooks.json の自前 hook を、位置を保ったまま差し替える jq プログラム。
#
# Codex の hook の信頼は配列上の位置をキーにする（~/.codex/config.toml の
# [hooks.state."<hooks.json の絶対パス>:<event の snake_case>:<グループ index>:<hook index>"]）。
# 中身が同じでも並べ替えると位置キーが変わり、その hook は「要レビュー」としてスキップされる。
# そのため他者（Orca・Muxy 等）のグループの位置を動かさない:
#   - 自前の hook = command が /.claude/scripts/ を含むもの（ホームを問わない。settings.json の command は
#     リテラルの絶対パスなので、$HOME での前方一致にすると sandbox の HOME で 0 件になる）
#   - 自前グループ = 自前の hook だけから成るグループ。各イベントの先頭から連続して置く
#   - 先頭の自前グループの列を、settings.json から作った列で置き換える（数が同じなら位置は 1 つもずれない）
#   - 先頭以外に自前の hook がある（他者のグループに混ざる・途中にある）場合は、推測で並べ替えず失敗する
# イベントの並びは元のファイルのまま保つ（keys / unique はソートするので使わない。信頼キーには影響しないが、
# ユーザーのファイルの差分を最小にする）。settings.json にだけあるイベントは後ろに足す。
# 入力は hooks.json の中身、変数 $s は settings.json の中身を 1 要素に持つ配列。
# 出力は {doc: 新しい hooks.json, changed: 自前グループの数が変わったイベント}
read -r -d '' CODEX_HOOKS_JQ <<'JQ' || true
def selfhook: ((.command // "") | contains("/.claude/scripts/"));
def solely: ((.hooks // []) | ((length > 0) and all(.[]; selfhook)));
def hasself: ((.hooks // []) | any(.[]; selfhook));
def gen($settings):
  ($settings.hooks // {})
  | with_entries(.value |= [ .[] | (.hooks // []) as $hs | select($hs | any(.[]; selfhook)) | .hooks = [ $hs[] | select(selfhook) ] ])
  | with_entries(select(.value | length > 0));
def lead($arr): ([ range(0; ($arr | length)) | select(($arr[.] | solely) | not) ] | first) // ($arr | length);

. as $doc
| ($doc.hooks // {}) as $cur
| gen($s[0]) as $gen
| (($cur | keys_unsorted) as $ck | $ck + (($gen | keys_unsorted) - $ck)) as $events
| (reduce $events[] as $ev ({hooks: {}, changed: []};
    ($cur[$ev] // []) as $arr
    | lead($arr) as $k
    | ([ range($k; ($arr | length)) | select($arr[.] | hasself) ]) as $bad
    | (if ($bad | length) > 0
         then error("\($ev): 先頭の自前グループの後ろに自前の hook があります（グループ index \($bad | map(tostring) | join(","))）。他者の位置を動かさないよう、手で整理してください。整理すると位置が変わるので、./setup.sh install を再実行した後に Codex の /hooks でこのイベントの全件（Orca・Muxy を含む）を信頼し直してください")
         else . end)
    | ($gen[$ev] // []) as $g
    | .hooks[$ev] = ($g + $arr[$k:])
    | (if ($g | length) != $k then .changed += [$ev] else . end)
  )) as $r
# 自前を抜いた結果として空になったイベントだけを消す。他者の空配列・null のイベントは元の値のまま残す
| ($r.hooks | with_entries(.key as $e
    | if (.value | length) > 0 then .
      elif ($cur | has($e)) and (($cur[$e] // []) | length) == 0 then .value = $cur[$e]
      else empty end)) as $new
| { doc: (if ($new | length) == 0 and ($doc | has("hooks") | not) then $doc else ($doc | .hooks = $new) end),
    changed: $r.changed }
JQ

# hooks.json の中身と settings.json の中身（配列に包んだ JSON）から {doc, changed} を作る
codex_hooks_transform() {  # $1=hooks.json の中身, $2=[settings.json の中身]
    printf '%s' "$1" | jq -c --argjson s "$2" "$CODEX_HOOKS_JQ"
}

codex_self_hook_count() {  # $1=hooks.json の中身 → 自前の hook の数
    printf '%s' "$1" | jq '[.hooks[]?[]? | .hooks[]? | (.command // "") | select(contains("/.claude/scripts/"))] | length'
}

install_codex_hooks() {
    log_info "Codex の hooks.json に自前の hook を登録しています..."
    local settings="${SCRIPT_DIR}/claude/settings.json"
    if [[ ! -f "$settings" ]]; then
        log_warning "  ! ${settings} がありません。hooks.json の更新をスキップします"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_error "  ✗ jq が見つかりません。hooks.json の更新には jq が必要です（hook も jq に依存しています）"
        return 1
    fi

    local doc="{}" snap="" result new_doc changed self_n err settings_json
    # 一時ファイルは hooks.json の隣に作る。テンプレート無しの mktemp は macOS では TMPDIR より
    # _CS_DARWIN_USER_TEMP_DIR を優先するので、残骸を ~/.codex の hooks.json.* として数えられない。
    # 各 return の経路で消す（EXIT trap は使わない。ロックの trap を上書きするため）
    if ! err=$(mktemp "${CODEX_HOOKS_JSON}.err.XXXXXX"); then
        log_error "  ✗ ${CODEX_DIR} に一時ファイルを作れません（hooks.json には何も書き込んでいません）"
        return 1
    fi
    if [[ -f "$CODEX_HOOKS_JSON" ]]; then
        # 読んだ時点の写しを取り、読み込み・比較・退避をこの写しで行う（書き込む直前に今のファイルと比べる）
        if ! snap=$(mktemp "${CODEX_HOOKS_JSON}.snap.XXXXXX") || ! cp -p "$CODEX_HOOKS_JSON" "$snap"; then
            log_error "  ✗ ${CODEX_HOOKS_JSON} を読めません（hooks.json には何も書き込んでいません）"
            rm -f "$err" "$snap"
            return 1
        fi
        # 0 バイトは他者の非原子的な書き込みの途中状態でもあるので、新規作成扱いにしない。-s で {} {} も弾く
        if ! jq -se 'length == 1 and (.[0] | type == "object")' "$snap" >/dev/null 2>&1; then
            log_error "  ✗ ${CODEX_HOOKS_JSON} が JSON のオブジェクトではありません（空のファイルを含む）。何も書き込んでいません"
            rm -f "$err" "$snap"
            return 1
        fi
        doc=$(cat "$snap")
    fi
    # {} {} のような複数の値も弾くため -s で読む
    if ! settings_json=$(jq -cse 'select(length == 1 and (.[0] | type == "object")) | .[0]' "$settings" 2>"$err"); then
        log_error "  ✗ ${settings} を JSON のオブジェクトとして読めません（hooks.json には何も書き込んでいません）: $(cat "$err")"
        rm -f "$err" "$snap"
        return 1
    fi
    # settings.json 由来の自前 hook が 0 本なら撤去しない。撤去は uninstall の役目で、settings.json の
    # 読み損ないで全ガードを外さないため
    if [[ "$(codex_self_hook_count "$settings_json")" -eq 0 ]] && [[ "$(codex_self_hook_count "$doc" 2>/dev/null)" -gt 0 ]]; then
        log_error "  ✗ ${settings} に自前 hook が 1 本もありません。撤去は ./setup.sh uninstall の役目なので、何も書き込まずに中断します"
        rm -f "$err" "$snap"
        return 1
    fi
    if ! result=$(codex_hooks_transform "$doc" "[$settings_json]" 2>"$err") || [[ -z "$result" ]]; then
        log_error "  ✗ hooks.json を更新できません（何も書き込んでいません）: $(cat "$err")"
        rm -f "$err" "$snap"
        return 1
    fi
    rm -f "$err"
    new_doc=$(printf '%s' "$result" | jq '.doc')
    changed=$(printf '%s' "$result" | jq -r '.changed[]')
    self_n=$(codex_self_hook_count "$new_doc")

    if [[ -n "$snap" ]]; then
        # 書式の違い（インデント・キー順）で書き換えないよう、正規化して比べる。
        # 実機と同じ並びなら初回の install から書き込まない（書けば位置キーの検証が要る）
        if [[ "$(jq -S . "$snap")" == "$(printf '%s' "$new_doc" | jq -S .)" ]]; then
            log_success "  ✓ hooks.json は最新です（自前 hook ${self_n} 本は各イベントの先頭に登録済み。書き込みなし）"
            rm -f "$snap"
            return 0
        fi
    elif [[ "$self_n" -eq 0 ]]; then
        log_info "  自前の hook が無いので hooks.json を作りません"
        return 0
    fi

    # 読んだ写しと今のファイルが違えば書かない。Codex・Orca・Muxy も hooks.json に書くので、古い版で
    # 上書きすると他者の変更が消える。読んだ時に無かったファイルが現れた場合も同じ
    if [[ -n "$snap" ]] && ! cmp -s "$snap" "$CODEX_HOOKS_JSON" || [[ -z "$snap" && -e "$CODEX_HOOKS_JSON" ]]; then
        log_error "  ✗ hooks.json を読んだ後に他のツールが書き換えました。何も書き込まずに中断します（もう一度 ./setup.sh install を実行してください）"
        rm -f "$snap"
        return 1
    fi
    mkdir -p "$CODEX_DIR"
    if [[ -n "$snap" ]]; then
        local backup="${CODEX_HOOKS_JSON}.pre-install.$(date +%Y%m%d%H%M%S)-$$"
        mv "$snap" "$backup"
        log_warning "  ! 既存の hooks.json を退避: $backup"
    fi
    local tmp="${CODEX_HOOKS_JSON}.new.$$"
    printf '%s\n' "$new_doc" > "$tmp"
    replace_file "$tmp" "$CODEX_HOOKS_JSON"
    log_success "  ✓ hooks.json（自前 hook ${self_n} 本を登録）"
    log_warning "  ! Codex で /hooks を開き、変わった定義を信頼し直してください。信頼は hook の位置と定義に紐づくため、そのままでは hook がスキップされます"
    local ev
    # イベント名は hooks.json 由来なので、未クォートの for（単語分割・glob 展開）には渡さない
    while IFS= read -r ev; do
        [[ -n "$ev" ]] || continue
        log_warning "  ! ${ev}: 自前グループの数が変わったため、このイベントの Orca・Muxy を含む全件の位置がずれます。/hooks で全件を信頼し直してください"
    done <<< "$changed"
}

# 自前の hook（先頭の自前グループ）だけを撤去する。先頭のグループを取り除くと後ろの位置が 1 つずつずれ、
# Orca・Muxy を含むそのイベントの hook の信頼が外れる。撤去しても位置を保つ方法は無いので、案内を出す
uninstall_codex_hooks() {
    [[ -f "$CODEX_HOOKS_JSON" ]] || return 0
    # 失敗は warn と return 0 にする（uninstall は段を通らないので、return 1 だと set -e で残りの撤去が走らない）
    local doc result new_doc self_before snap
    if ! snap=$(mktemp "${CODEX_HOOKS_JSON}.snap.XXXXXX") || ! cp -p "$CODEX_HOOKS_JSON" "$snap"; then
        log_warning "  ! ${CODEX_HOOKS_JSON} を読めないため、自前 hook の撤去をスキップします"
        rm -f "$snap"
        return 0
    fi
    if ! jq -se 'length == 1 and (.[0] | type == "object")' "$snap" >/dev/null 2>&1; then
        log_warning "  ! ${CODEX_HOOKS_JSON} が JSON のオブジェクトではない（空のファイルを含む）ため、自前 hook の撤去をスキップします"
        rm -f "$snap"
        return 0
    fi
    doc=$(cat "$snap")
    if ! result=$(codex_hooks_transform "$doc" '[{}]' 2>/dev/null); then
        log_warning "  ! hooks.json を解釈できない（先頭以外に自前の hook がある等）ため、自前 hook の撤去をスキップします。自前の hook を先頭のグループにまとめてから ./setup.sh uninstall を再実行し、Codex の /hooks でこのイベントの全件を信頼し直してください"
        rm -f "$snap"
        return 0
    fi
    self_before=$(codex_self_hook_count "$doc")
    if [[ "$self_before" -eq 0 ]]; then
        rm -f "$snap"
        return 0
    fi
    new_doc=$(printf '%s' "$result" | jq '.doc')
    # 読んだ写しと今のファイルが違えば書かない（他者の変更を古い版で消さない）
    if ! cmp -s "$snap" "$CODEX_HOOKS_JSON"; then
        log_warning "  ! hooks.json を読んだ後に他のツールが書き換えたため、自前 hook の撤去をスキップします（何も書き込んでいません）"
        rm -f "$snap"
        return 0
    fi
    local backup="${CODEX_HOOKS_JSON}.pre-uninstall.$(date +%Y%m%d%H%M%S)-$$"
    mv "$snap" "$backup"
    local tmp="${CODEX_HOOKS_JSON}.new.$$"
    printf '%s\n' "$new_doc" > "$tmp"
    replace_file "$tmp" "$CODEX_HOOKS_JSON"
    log_success "  ✓ 削除: hooks.json の自前 hook ${self_before} 本（退避: ${backup}）"
    log_warning "  ! 先頭の自前グループを取り除いたため、そのイベントの Orca・Muxy を含む hook の位置がずれ、信頼が外れます。Codex の /hooks で全件を信頼し直すか、退避した hooks.json と config.toml を戻してください"
}

# ~/.codex/AGENTS.md の 2 ブロック（共通規約・読み替え表）は同じファイルなので、1 回の置き換えにまとめる
install_codex_agents_md() {
    install_marker_blocks "$CODEX_AGENTS_MD" \
        "~/.codex/AGENTS.md の共通規約ブロック" "$REPO_GLOBAL_RULES" "$GLOBAL_RULES_BEGIN" "$GLOBAL_RULES_END" \
        "~/.codex/AGENTS.md の読み替え表ブロック" "$REPO_CODEX_RULES" "$CODEX_RULES_BEGIN" "$CODEX_RULES_END"
}

codex_hooks_cksum() {  # hooks.json の cksum（無ければ none）。書き換えの有無を親シェルで見る
    if [[ -f "$CODEX_HOOKS_JSON" ]]; then
        cksum <"$CODEX_HOOKS_JSON" 2>/dev/null || echo unreadable
    else
        echo none
    fi
}

# hooks.json の段を最初に置く。他の段の失敗で自前 hook が入らないと、Codex のガードが開いたままになる。
# 段は run_stage のサブシェルで走るので、案内の判定（変数）はこの親シェルで行う。||・if の条件の中で呼ばない
install_codex() {
    log_info "Codex への展開を行います（~/.codex が在るため）..."
    local hooks_before hooks_after
    hooks_before=$(codex_hooks_cksum)
    run_stage "Codex の hooks.json" install_codex_hooks
    hooks_after=$(codex_hooks_cksum)
    echo ""
    run_stage "Codex の skills" install_skills "Codex Skills (~/.agents/skills)" "$CODEX_SKILLS_DIR" skip
    echo ""
    run_stage "Codex の agents" install_codex_agents
    echo ""
    run_stage "Codex の規約ファイル" install_codex_agents_md

    # 信頼ハッシュはイベント名・matcher・hook 定義から作られ、スクリプトの中身を含まない（G-1）。
    # 信頼が外れうるのは hooks.json を書き換えたときだけなので、スクリプトの更新では案内しない
    if [[ "$hooks_before" != "$hooks_after" ]]; then
        CODEX_TRUST_NOTICE=true
    fi
}

# Skills の symlink を外す。$2 は exact（今のチェックアウトへの完全一致。Claude 側の従来の挙動）か
# own（自分のリンク。別 worktree を指すものを含む。Codex 側）。件数は SKILL_LINKS_REMOVED に入れる
uninstall_skill_links() {  # $1=配置先, $2=exact | own
    local dst_dir="$1" mode="$2" skill_dir skill_name target_link
    SKILL_LINKS_REMOVED=0
    for skill_dir in "$REPO_SKILLS_DIR"/*/; do
        [[ -d "$skill_dir" ]] || continue
        skill_name=$(basename "$skill_dir")
        [[ "$skill_name" == _* ]] && continue
        target_link="${dst_dir}/${skill_name}"
        [[ -L "$target_link" ]] || continue
        if [[ "$mode" == own ]]; then
            is_own_skill_link "$target_link" "$skill_name" "$SCRIPT_DIR" || continue
        else
            [[ "$(readlink "$target_link")" == "$skill_dir" ]] || continue
        fi
        rm "$target_link"
        log_success "  ✓ 削除: ${skill_name}"
        SKILL_LINKS_REMOVED=$((SKILL_LINKS_REMOVED + 1))
    done
}

uninstall_codex() {
    if [[ ! -d "$CODEX_DIR" && ! -d "$CODEX_SKILLS_DIR" ]]; then
        return 0
    fi
    log_info "Codex 側の自分が置いたものを削除しています..."
    uninstall_skill_links "$CODEX_SKILLS_DIR" own
    local codex_skills_count=$SKILL_LINKS_REMOVED

    local f codex_agents_count=0
    for f in "$CODEX_AGENTS_DIR"/*.toml; do
        [[ -f "$f" ]] || continue
        is_generated_toml "$f" || continue
        rm "$f"
        log_success "  ✓ 削除: $(basename "$f")"
        codex_agents_count=$((codex_agents_count + 1))
    done

    uninstall_marker_block "~/.codex/AGENTS.md の読み替え表ブロック" "$CODEX_AGENTS_MD" "$CODEX_RULES_BEGIN" "$CODEX_RULES_END"
    uninstall_marker_block "~/.codex/AGENTS.md の共通規約ブロック" "$CODEX_AGENTS_MD" "$GLOBAL_RULES_BEGIN" "$GLOBAL_RULES_END"
    uninstall_codex_hooks
    log_info "Codex 側の削除完了 - Skills: ${codex_skills_count} 件, Agents: ${codex_agents_count} 件"
}

# status の [Codex] 節。配置先ごとの件数と、ずれの有無を 1 行ずつ出す
show_codex_status() {
    echo -e "${BLUE}[Codex]${NC} (${CODEX_DIR}, ${CODEX_SKILLS_DIR})"
    if [[ ! -d "$CODEX_DIR" ]]; then
        echo "  (~/.codex が存在しません。Codex への展開は行われません)"
        return 0
    fi

    local skill_dir skill_name total=0 linked=0 foreign=0 relink=0 target_link
    for skill_dir in "$REPO_SKILLS_DIR"/*/; do
        [[ -d "$skill_dir" ]] || continue
        skill_name=$(basename "$skill_dir")
        [[ "$skill_name" == _* ]] && continue
        total=$((total + 1))
        target_link="${CODEX_SKILLS_DIR}/${skill_name}"
        if [[ -L "$target_link" && "$(readlink "$target_link")" == "$skill_dir" ]]; then
            linked=$((linked + 1))
        elif [[ -L "$target_link" ]] && is_own_skill_link "$target_link" "$skill_name" "$SCRIPT_DIR"; then
            relink=$((relink + 1))
        elif [[ -e "$target_link" || -L "$target_link" ]]; then
            foreign=$((foreign + 1))
        fi
    done
    if [[ "$linked" -eq "$total" ]]; then
        echo -e "  ${GREEN}✓${NC} Skills: ${linked}/${total} 件リンク済み"
    else
        echo -e "  ${YELLOW}!${NC} Skills: ${linked}/${total} 件リンク済み（張り替え待ち ${relink} 件・衝突・他者のリンク ${foreign} 件。張り替え待ちは別のチェックアウトを指す自分のリンクで、./setup.sh install で張り替わる。衝突は verify-skills.sh が知らせる）"
    fi

    local agent_total=0 agent_gen=0 agent_hand=0 f
    # 起点の末尾に / を付ける（起点が symlink のとき、付けないと find がリンク先へ降りない）
    agent_total=$(find "$REPO_AGENTS_DIR/" -name '*.md' -type f ! -name README.md 2>/dev/null | wc -l | tr -d ' ')
    for f in "$CODEX_AGENTS_DIR"/*.toml; do
        [[ -f "$f" ]] && is_generated_toml "$f" && agent_gen=$((agent_gen + 1))
    done
    # repo の agent と同名で生成ヘッダの無い TOML（手書き）。install は上書きしないので、件数に埋もれさせず示す
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        f="${CODEX_AGENTS_DIR}/$(basename "$f" .md).toml"
        if [[ -f "$f" ]] && ! is_generated_toml "$f"; then
            agent_hand=$((agent_hand + 1))
        fi
    done < <(find "$REPO_AGENTS_DIR/" -name '*.md' -type f ! -name README.md 2>/dev/null)
    if [[ "$agent_hand" -gt 0 ]]; then
        echo -e "  ${RED}✗${NC} Agents: 手書きと衝突 ${agent_hand} 件（install では解消しない。手書きの TOML を消すか改名する）"
    fi
    if [[ "$agent_gen" -eq "$agent_total" ]]; then
        echo -e "  ${GREEN}✓${NC} Agents: ${agent_gen}/${agent_total} 件の TOML を生成済み"
    else
        echo -e "  ${YELLOW}!${NC} Agents: ${agent_gen}/${agent_total} 件の TOML を生成済み（./setup.sh install で再生成）"
    fi

    local blocks=0 bad_blocks=0 unreadable=0 shape
    if [[ -f "$CODEX_AGENTS_MD" ]]; then
        for shape in "$(marker_shape "$CODEX_AGENTS_MD" "$GLOBAL_RULES_BEGIN" "$GLOBAL_RULES_END" 2>/dev/null || echo error)" \
                     "$(marker_shape "$CODEX_AGENTS_MD" "$CODEX_RULES_BEGIN" "$CODEX_RULES_END" 2>/dev/null || echo error)"; do
            case "$shape" in
                ok) blocks=$((blocks + 1)) ;;
                bad) bad_blocks=$((bad_blocks + 1)) ;;
                error) unreadable=1 ;;
            esac
        done
    fi
    if [[ "$unreadable" -eq 1 ]]; then
        echo -e "  ${RED}✗${NC} AGENTS.md: 読めません（権限を確かめてください）"
    elif [[ "$bad_blocks" -gt 0 ]]; then
        echo -e "  ${RED}✗${NC} AGENTS.md: マーカーの並びが不正なブロックが ${bad_blocks} 個（install は書き込まずに失敗します。手で直してください）"
    elif [[ "$blocks" -eq 2 ]]; then
        echo -e "  ${GREEN}✓${NC} AGENTS.md: 共通規約と読み替え表のブロックが入っている"
    else
        echo -e "  ${YELLOW}!${NC} AGENTS.md: ブロックが ${blocks}/2 個（./setup.sh install で追記）"
    fi

    if [[ -f "$CODEX_HOOKS_JSON" ]] && command -v jq >/dev/null 2>&1; then
        local self_now
        if ! jq -se 'length == 1 and (.[0] | type == "object")' "$CODEX_HOOKS_JSON" >/dev/null 2>&1; then
            echo -e "  ${RED}✗${NC} hooks.json: JSON のオブジェクトではありません（install は書き込まずに失敗します）"
        else
            self_now=$(codex_self_hook_count "$(cat "$CODEX_HOOKS_JSON")" 2>/dev/null || echo "?")
            echo -e "  ${BLUE}·${NC} hooks.json: 自前の hook ${self_now} 本（位置と信頼の検査は verify-skills.sh の check 12）"
        fi
    else
        echo -e "  ${YELLOW}!${NC} hooks.json: 無いか、jq が使えない"
    fi
}

# アンインストール
uninstall() {
    log_info "インストールされた Scripts, Skills, Commands, Agents を削除しています..."

    # Commands の削除
    local commands_count=0
    for cmd_file in "$REPO_COMMANDS_DIR"/*.md; do
        [ -f "$cmd_file" ] || continue
        local cmd_name=$(basename "$cmd_file" .md)
        local target_dir="${CLAUDE_SKILLS_DIR}/${cmd_name}"

        if [[ -d "$target_dir" && -L "${target_dir}/SKILL.md" ]]; then
            local link_target=$(readlink "${target_dir}/SKILL.md")
            if [[ "$link_target" == "$cmd_file" ]]; then
                rm "${target_dir}/SKILL.md"
                rmdir "$target_dir" 2>/dev/null || true
                log_success "  ✓ 削除: ${cmd_name}"
                ((commands_count++))
            fi
        fi
    done

    # Skills の削除（Claude 側は今のチェックアウトへの完全一致。従来の挙動）
    uninstall_skill_links "$CLAUDE_SKILLS_DIR" exact
    local skills_count=$SKILL_LINKS_REMOVED

    # Agents の削除
    uninstall_md_links "Agents" "$REPO_AGENTS_DIR" "$CLAUDE_AGENTS_DIR"
    local agents_count=$MD_LINKS_REMOVED

    # Scripts の削除
    local scripts_dir="$REPO_SCRIPTS_DIR"
    local scripts_target_dir="${CLAUDE_DIR}/scripts"
    local scripts_count=0
    for script in "$scripts_dir"/*.sh "$scripts_dir"/*.py; do
        [ -f "$script" ] || continue
        local name=$(basename "$script")
        local target_link="${scripts_target_dir}/${name}"

        if [[ -L "$target_link" ]]; then
            # 旧形式（symlink）: リンク先が本リポの場合のみ削除
            local link_target=$(readlink "$target_link")
            if [[ "$link_target" == "$script" ]]; then
                rm "$target_link"
                log_success "  ✓ 削除: ${name}"
                ((scripts_count++))
            fi
        elif [[ -f "$target_link" ]] && cmp -s "$script" "$target_link"; then
            # 実体コピー: repo と同一内容のときだけ削除（ローカル改変は残す）
            rm "$target_link"
            log_success "  ✓ 削除: ${name}"
            ((scripts_count++))
        elif [[ -e "$target_link" || -L "$target_link" ]]; then
            # 無言でスキップすると「アンインストールしたのに hook が動く」という
            # 調査困難な状態になる。件数だけ合わないより、残した理由を出す
            log_warning "  ! スキップ: ${name}（repo と差分あり。手動で確認してください）"
        fi
    done

    # install 出自の記録も併せて撤去する
    if [[ -f "${scripts_target_dir}/.installed-from" ]]; then
        rm "${scripts_target_dir}/.installed-from"
    fi

    # Settings の削除
    local settings_source="${SCRIPT_DIR}/claude/settings.json"
    local settings_target="${CLAUDE_DIR}/settings.json"
    local settings_count=0
    if [[ -L "$settings_target" ]]; then
        local link_target=$(readlink "$settings_target")
        if [[ "$link_target" == "$settings_source" ]]; then
            rm "$settings_target"
            log_success "  ✓ 削除: settings.json (バックアップ ${settings_target}.pre-install.* は残置)"
            ((settings_count++))
        fi
    fi

    # 共通規約ブロックの除去。ユーザーがブロック外に書いた内容には触れない
    uninstall_marker_block "CLAUDE.md の共通規約ブロック" "${CLAUDE_DIR}/CLAUDE.md" "$GLOBAL_RULES_BEGIN" "$GLOBAL_RULES_END"

    # Codex 側（自分が置いたものだけ）
    uninstall_codex

    log_info "削除完了 - Scripts: ${scripts_count} 件, Skills: ${skills_count} 件, Commands: ${commands_count} 件, Agents: ${agents_count} 件, Settings: ${settings_count} 件"
}

# 状態表示
show_status() {
    echo ""
    echo "=========================================="
    echo "  Claude Scripts, Skills, Agents 状態"
    echo "=========================================="
    echo ""

    local settings_source="${SCRIPT_DIR}/claude/settings.json"
    local settings_target="${CLAUDE_DIR}/settings.json"
    echo -e "${BLUE}[Settings]${NC} (${settings_target})"
    if [[ -L "$settings_target" ]]; then
        local link_target=$(readlink "$settings_target")
        if [[ "$link_target" == "$settings_source" ]]; then
            echo -e "  ${GREEN}✓${NC} settings.json (リンク済み)"
        else
            echo -e "  ${YELLOW}!${NC} settings.json (別のリンク先: $link_target)"
        fi
    elif [[ -f "$settings_target" ]]; then
        echo -e "  ${YELLOW}!${NC} settings.json (実ファイルが存在)"
    else
        echo -e "  ${RED}✗${NC} settings.json (未インストール)"
    fi

    echo ""
    local scripts_dir="$REPO_SCRIPTS_DIR"
    local scripts_target_dir="${CLAUDE_DIR}/scripts"
    echo -e "${BLUE}[Scripts]${NC} (${scripts_target_dir})"
    if [[ -d "$scripts_target_dir" ]]; then
        local has_scripts=false
        for script in "$scripts_dir"/*.sh "$scripts_dir"/*.py; do
            [ -f "$script" ] || continue
            local name=$(basename "$script")
            local target_link="${scripts_target_dir}/${name}"

            if [[ -L "$target_link" ]]; then
                # リンク先を出す。install は symlink を上書きするため、表示しないと
                # 「どこを指していたか」が復元不能なまま失われる
                local link_dest=$(readlink "$target_link")
                if [[ -e "$target_link" ]]; then
                    echo -e "  ${YELLOW}!${NC} ${name} (旧形式の symlink → ${link_dest} — ./setup.sh install で実体コピーへ移行)"
                else
                    echo -e "  ${RED}✗${NC} ${name} (dangling symlink → ${link_dest} — 実行すると exit 127)"
                fi
                has_scripts=true
            elif [[ -d "$target_link" ]]; then
                echo -e "  ${RED}✗${NC} ${name} (ディレクトリ — 実行すると exit 126)"
                has_scripts=true
            elif [[ -f "$target_link" ]]; then
                if cmp -s "$script" "$target_link"; then
                    echo -e "  ${GREEN}✓${NC} ${name} (コピー済み)"
                else
                    echo -e "  ${YELLOW}!${NC} ${name} (repo と差分あり — ./setup.sh install で再コピー。改変は .backup.* に退避される)"
                fi
                has_scripts=true
            else
                echo -e "  ${RED}✗${NC} ${name} (未インストール)"
            fi
        done

        # 逆方向の走査。repo 起点のループでは「repo から削除されたのに残っているファイル」が
        # 見えない。README / CLAUDE.md は本コマンドと verify-skills.sh を同等の確認手段として
        # 案内しているので、検出能力が食い違うと「status では綺麗なのに verify では warn」になる
        local installed_script
        for installed_script in "$scripts_target_dir"/*.sh "$scripts_target_dir"/*.py; do
            [ -e "$installed_script" ] || [ -L "$installed_script" ] || continue
            local orphan_name=$(basename "$installed_script")
            [ -f "${scripts_dir}/${orphan_name}" ] && continue
            if [[ -L "$installed_script" && ! -e "$installed_script" ]]; then
                echo -e "  ${RED}✗${NC} ${orphan_name} (repo に無い orphan / dangling — 実行すると exit 127)"
            else
                echo -e "  ${YELLOW}!${NC} ${orphan_name} (repo に無い orphan — ./setup.sh install --prune-scripts で退避)"
            fi
            has_scripts=true
        done

        # install 時のバックアップ残存。ローカル改変判定を修正した後は 0 件が正常で、
        # 増えていれば「repo 更新をローカル改変と誤判定している」兆候になる
        local backup_count=0
        local backup_file
        for backup_file in "$scripts_target_dir"/*.backup.*; do
            [ -e "$backup_file" ] || continue
            backup_count=$((backup_count + 1))
        done
        if [[ "$backup_count" -gt 0 ]]; then
            echo -e "  ${YELLOW}!${NC} install 時のバックアップが ${backup_count} 件残存（内容を確認して削除する）"
        fi

        # install 出自。実体コピーではリンク先から由来が読めないので記録を表示する。
        # worktree から install した状態を見落とすと、その worktree の削除で設定が消える
        if [[ -f "${scripts_target_dir}/.installed-from" ]]; then
            local from_dir_shown
            from_dir_shown=$(cut -f1 "${scripts_target_dir}/.installed-from" 2>/dev/null || true)
            if [[ -z "$from_dir_shown" ]]; then
                echo -e "  ${YELLOW}!${NC} install 元: .installed-from が空"
            elif [[ "$from_dir_shown" == "$SCRIPT_DIR" ]]; then
                echo -e "  ${GREEN}✓${NC} install 元: このチェックアウト"
            else
                echo -e "  ${YELLOW}!${NC} install 元: ${from_dir_shown} (別のチェックアウト)"
            fi
        else
            echo -e "  ${YELLOW}!${NC} install 元: 不明（.installed-from が無い。./setup.sh install で記録される）"
        fi

        if [[ "$has_scripts" == false ]]; then
            echo "  (インストールされた Scripts はありません)"
        fi
    else
        echo "  (ディレクトリが存在しません)"
    fi

    echo ""
    echo -e "${BLUE}[Skills]${NC} (${CLAUDE_SKILLS_DIR})"
    if [[ -d "$CLAUDE_SKILLS_DIR" ]]; then
        local has_skills=false
        for skill_dir in "$REPO_SKILLS_DIR"/*/; do
            if [[ -d "$skill_dir" ]]; then
                local skill_name=$(basename "$skill_dir")
                local target_link="${CLAUDE_SKILLS_DIR}/${skill_name}"

                if [[ -L "$target_link" ]]; then
                    local link_target=$(readlink "$target_link")
                    if [[ "$link_target" == "$skill_dir" ]]; then
                        echo -e "  ${GREEN}✓${NC} ${skill_name} (リンク済み)"
                        has_skills=true
                    else
                        echo -e "  ${YELLOW}!${NC} ${skill_name} (別のリンク先)"
                    fi
                elif [[ -d "$target_link" ]]; then
                    echo -e "  ${YELLOW}!${NC} ${skill_name} (実ディレクトリが存在)"
                else
                    echo -e "  ${RED}✗${NC} ${skill_name} (未インストール)"
                fi
            fi
        done
        if [[ "$has_skills" == false ]]; then
            echo "  (インストールされた Skills はありません)"
        fi
    else
        echo "  (ディレクトリが存在しません)"
    fi

    echo ""
    show_md_links_status "Agents" "$REPO_AGENTS_DIR" "$CLAUDE_AGENTS_DIR"

    echo ""
    show_codex_status

    echo ""
}

# メイン処理
main() {
    echo ""
    echo "=========================================="
    echo "  Claude Skills & SubAgents Setup"
    echo "=========================================="
    echo ""

    local command="${1:-install}"
    local prune_scripts=false

    # 未知のオプションはエラーにする。`--prune-script` のようなタイポを黙って無視すると
    # 「prune したつもりで実行されていない」という静かな失敗になる
    case "${2:-}" in
        "") ;;
        --prune-scripts) prune_scripts=true ;;
        *)
            echo "不明なオプション: $2"
            echo "使用方法: $0 {install|uninstall|status|migrate} [--prune-scripts]"
            exit 1
            ;;
    esac

    # コマンドとオプションの組み合わせも検証する。install 以外では prune_scripts が
    # 参照されないため、黙って受理すると「prune したつもりで実行されていない」という
    # 静かな失敗になる（タイポを弾く上記の case と同じ理由）
    if [[ "$prune_scripts" == true && "$command" != install ]]; then
        # 先頭が `--` の文字列を echo に渡すと環境によってオプションとして食われ、
        # 後続の展開結果まで欠落する。printf で明示的に書式指定する
        printf -- '--prune-scripts は install でのみ使用できます (指定されたコマンド: %s)\n' "$command"
        exit 1
    fi

    case "$command" in
        install)
            acquire_lock
            check_source_dirs
            warn_if_worktree
            init_claude_dir
            install_scripts "$prune_scripts"
            echo ""
            install_skills
            echo ""
            install_md_links "Agents" "$REPO_AGENTS_DIR" "$CLAUDE_AGENTS_DIR"
            echo ""
            install_settings
            echo ""
            # CLAUDE.md の段で止まると install_codex に到達しないので、段として走らせる
            run_stage "Claude の共通規約" install_global_rules
            echo ""
            local codex_done=false
            if [[ -d "$CODEX_DIR" ]]; then
                install_codex
                codex_done=true
            else
                log_info "~/.codex が無いので Codex への展開を省略します"
            fi
            echo ""
            # 案内と失敗一覧は、各段の出力に埋もれないよう最後に出す
            if [[ "$CODEX_TRUST_NOTICE" == true ]]; then
                log_warning "Codex を開いて /hooks を確認し、「要レビュー」の hook があれば信頼し直してください（hooks.json の自前 hook を書き換えたため）"
                echo ""
            fi
            if [[ ${#STAGE_FAILURES[@]} -gt 0 ]]; then
                log_error "次の段が失敗しました（他の段は最後まで実行しました）。上の ✗ の行で理由を確かめてください:"
                local stage
                for stage in "${STAGE_FAILURES[@]}"; do
                    echo "  - ${stage}"
                done
                exit 1
            fi
            if [[ "$codex_done" == true ]]; then
                log_success "セットアップが完了しました！（Claude Code と Codex の両方に展開しました）"
            else
                log_success "セットアップが完了しました！"
            fi
            echo ""
            echo "確認するには: ./setup.sh status"
            ;;
        uninstall)
            acquire_lock
            uninstall
            ;;
        status)
            show_status
            ;;
        migrate)
            acquire_lock
            check_source_dirs
            # CLAUDE.md が案内する他端末展開手順は `migrate && install` の順なので、
            # migrate で警告しないと最初の警告機会を逃す
            warn_if_worktree
            init_claude_dir
            migrate
            ;;
        *)
            echo "使用方法: $0 {install|uninstall|status|migrate} [--prune-scripts]"
            echo "  --prune-scripts : repo に存在しない ~/.claude/scripts/ の orphan を退避して削除する"
            exit 1
            ;;
    esac
}

main "$@"
