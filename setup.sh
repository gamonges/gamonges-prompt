#!/bin/bash

# =============================================================================
# Claude Skills & SubAgents セットアップスクリプト
# =============================================================================
#
# このスクリプトは、リポジトリ内の Skills, SubAgents, settings.json を ~/.claude/ 配下に
# シンボリックリンクとして、Scripts を実体コピーとして配置します。
# これにより、すべてのプロジェクトで共通して使用できるようになります。
#
# 使用方法:
#   ./setup.sh          # インストール（デフォルト）
#   ./setup.sh install  # インストール
#   ./setup.sh uninstall # アンインストール
#   ./setup.sh status   # 現在の状態を表示
#   ./setup.sh migrate  # 旧形式 (commands→skill 化されたディレクトリ) を撤去して新形式へ移行
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
REPO_SKILLS_DIR="${SCRIPT_DIR}/claude/skills"
REPO_COMMANDS_DIR="${SCRIPT_DIR}/claude/commands"
REPO_SUBAGENTS_DIR="${SCRIPT_DIR}/claude/subagents"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_SKILLS_DIR="${CLAUDE_DIR}/skills"
CLAUDE_SUBAGENTS_DIR="${CLAUDE_DIR}/sub-agents"

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

# ディレクトリの存在確認
check_source_dirs() {
    if [[ ! -d "$REPO_SKILLS_DIR" ]]; then
        log_error "Skills ディレクトリが見つかりません: $REPO_SKILLS_DIR"
        exit 1
    fi
    if [[ ! -d "$REPO_SUBAGENTS_DIR" ]]; then
        log_error "SubAgents ディレクトリが見つかりません: $REPO_SUBAGENTS_DIR"
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
    if [[ ! -d "$CLAUDE_SUBAGENTS_DIR" ]]; then
        mkdir -p "$CLAUDE_SUBAGENTS_DIR"
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

    # atomic 置換
    ln -s "$source_file" "${target_link}.new"
    mv -f "${target_link}.new" "$target_link"
    log_success "  ✓ settings.json → $source_file"
}

# install 元が linked worktree なら警告する。
#
# settings.json と skills は symlink のままなので、install 元のチェックアウトを全プロジェクトの
# ランタイムが参照する。worktree から install すると、その worktree を削除した瞬間に
# deny リスト・hook 定義・全 skill がまとめて失われる。hook のように exit 127 がログに残る形ではなく
# Claude Code がデフォルト設定で静かに起動するため、スクリプト側の失敗モードより気づきにくい。
# 判定はパス非依存にする（メインチェックアウトの場所をハードコードしない）。
warn_if_worktree() {
    local git_dir git_common
    git_dir=$(git -C "$SCRIPT_DIR" rev-parse --git-dir 2>/dev/null) || return 0
    git_common=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null) || return 0
    if [[ "$git_dir" != "$git_common" ]]; then
        log_warning "  ! linked worktree から install しています: ${SCRIPT_DIR}"
        log_warning "    settings.json / skills の symlink がこの worktree を指すため、削除すると設定が失われます"
        log_warning "    可能ならメインチェックアウトから install してください"
    fi
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
    local scripts_dir="${SCRIPT_DIR}/claude/scripts"
    local target_dir="${CLAUDE_DIR}/scripts"
    mkdir -p "$target_dir"

    local count=0
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
            mv "$target" "${target}.backup.$(date +%Y%m%d%H%M%S)"
        elif [[ -f "$target" ]] && ! cmp -s "$script" "$target"; then
            # 他の install 関数と同じくローカル改変を保護する。
            # 内容が同じときは退避しない（毎回バックアップが増えるとノイズになるため）
            cp "$target" "${target}.backup.$(date +%Y%m%d%H%M%S)"
            log_warning "  ! ${name} はローカル改変あり。バックアップしました"
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
            local backup_dir="${target_dir}/.orphan-backup.$(date +%Y%m%d%H%M%S)"
            mkdir -p "$backup_dir"
            local n
            for n in "${orphans[@]}"; do
                mv "${target_dir}/${n}" "${backup_dir}/${n}"
                log_success "  ✓ 削除: ${n} (orphan)"
            done
            log_info "  orphan ${#orphans[@]} 件を ${backup_dir} へ退避しました"
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

# Skills のインストール
install_skills() {
    log_info "Skills をインストールしています..."

    local count=0
    for skill_dir in "$REPO_SKILLS_DIR"/*/; do
        if [[ -d "$skill_dir" ]]; then
            local skill_name=$(basename "$skill_dir")
            # _ プレフィックスは雛形 / プライベート用としてスキップ
            [[ "$skill_name" == _* ]] && continue
            local target_link="${CLAUDE_SKILLS_DIR}/${skill_name}"

            # 既に正しい先を指しているなら触らない。変更が無いのに毎回 rm → ln -s すると
            # symlink が存在しない窓が開き、併走セッションの skill ロードが失敗しうる
            # （install は Claude Code セッション内から走り、複数 worktree が併走する）
            if [[ ! -L "$target_link" || "$(readlink "$target_link")" != "$skill_dir" ]]; then
                # 既存のリンクまたはディレクトリを処理
                if [[ -L "$target_link" ]]; then
                    log_warning "既存のシンボリックリンクを更新: ${skill_name}"
                    rm "$target_link"
                elif [[ -d "$target_link" ]]; then
                    log_warning "既存のディレクトリをバックアップ: ${skill_name}"
                    mv "$target_link" "${target_link}.backup.$(date +%Y%m%d%H%M%S)"
                fi

                ln -s "$skill_dir" "$target_link"
            fi

            # skill 内 scripts/*.sh に実行権限を付与（symlink 経由でも実行可能にする）
            # find 自体の exit code は -exec の最終結果を反映しないため、失敗を明示検知
            if [[ -d "${skill_dir}scripts" ]]; then
                if ! find "${skill_dir}scripts" -name '*.sh' -type f -exec chmod +x {} + 2>&1; then
                    log_warning "  ! ${skill_name}/scripts への chmod に失敗"
                fi
            fi

            log_success "  ✓ ${skill_name}"
            ((count++))
        fi
    done

    log_info "Skills: ${count} 件インストール完了"
}

# Migrate: 旧形式 (commands→skill 化されたディレクトリ) を撤去
# 過去の install_commands で作られた dead symlink + ディレクトリを安全に削除する
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
    echo ""
    install_skills
}

# SubAgents のインストール
install_subagents() {
    log_info "SubAgents をインストールしています..."

    local count=0
    # サブディレクトリ内の .md ファイルを再帰的に検索
    while IFS= read -r -d '' md_file; do
        local relative_path="${md_file#$REPO_SUBAGENTS_DIR/}"
        local filename=$(basename "$md_file")

        # README.md はスキップ
        if [[ "$filename" == "README.md" ]]; then
            continue
        fi

        local target_link="${CLAUDE_SUBAGENTS_DIR}/${filename}"

        # install_skills と同じ理由で、既に正しい先を指していれば触らない
        if [[ ! -L "$target_link" || "$(readlink "$target_link")" != "$md_file" ]]; then
            # 既存のリンクまたはファイルを処理
            if [[ -L "$target_link" ]]; then
                log_warning "既存のシンボリックリンクを更新: ${filename}"
                rm "$target_link"
            elif [[ -f "$target_link" ]]; then
                log_warning "既存のファイルをバックアップ: ${filename}"
                mv "$target_link" "${target_link}.backup.$(date +%Y%m%d%H%M%S)"
            fi

            ln -s "$md_file" "$target_link"
        fi
        log_success "  ✓ ${filename}"
        ((count++))
    done < <(find "$REPO_SUBAGENTS_DIR" -name "*.md" -type f -print0)

    log_info "SubAgents: ${count} 件インストール完了"
}

# アンインストール
uninstall() {
    log_info "インストールされた Scripts, Skills, Commands, SubAgents を削除しています..."

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

    # Skills の削除
    local skills_count=0
    for skill_dir in "$REPO_SKILLS_DIR"/*/; do
        if [[ -d "$skill_dir" ]]; then
            local skill_name=$(basename "$skill_dir")
            local target_link="${CLAUDE_SKILLS_DIR}/${skill_name}"

            if [[ -L "$target_link" ]]; then
                # リンク先がこのリポジトリを指しているか確認
                local link_target=$(readlink "$target_link")
                if [[ "$link_target" == "$skill_dir" ]]; then
                    rm "$target_link"
                    log_success "  ✓ 削除: ${skill_name}"
                    ((skills_count++))
                fi
            fi
        fi
    done

    # SubAgents の削除
    local subagents_count=0
    while IFS= read -r -d '' md_file; do
        local filename=$(basename "$md_file")

        if [[ "$filename" == "README.md" ]]; then
            continue
        fi

        local target_link="${CLAUDE_SUBAGENTS_DIR}/${filename}"

        if [[ -L "$target_link" ]]; then
            local link_target=$(readlink "$target_link")
            if [[ "$link_target" == "$md_file" ]]; then
                rm "$target_link"
                log_success "  ✓ 削除: ${filename}"
                ((subagents_count++))
            fi
        fi
    done < <(find "$REPO_SUBAGENTS_DIR" -name "*.md" -type f -print0)

    # Scripts の削除
    local scripts_dir="${SCRIPT_DIR}/claude/scripts"
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

    log_info "削除完了 - Scripts: ${scripts_count} 件, Skills: ${skills_count} 件, Commands: ${commands_count} 件, SubAgents: ${subagents_count} 件, Settings: ${settings_count} 件"
}

# 状態表示
show_status() {
    echo ""
    echo "=========================================="
    echo "  Claude Scripts, Skills, SubAgents 状態"
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
    local scripts_dir="${SCRIPT_DIR}/claude/scripts"
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
    echo -e "${BLUE}[SubAgents]${NC} (${CLAUDE_SUBAGENTS_DIR})"
    if [[ -d "$CLAUDE_SUBAGENTS_DIR" ]]; then
        local has_subagents=false
        while IFS= read -r -d '' md_file; do
            local filename=$(basename "$md_file")

            if [[ "$filename" == "README.md" ]]; then
                continue
            fi

            local target_link="${CLAUDE_SUBAGENTS_DIR}/${filename}"

            if [[ -L "$target_link" ]]; then
                local link_target=$(readlink "$target_link")
                if [[ "$link_target" == "$md_file" ]]; then
                    echo -e "  ${GREEN}✓${NC} ${filename} (リンク済み)"
                    has_subagents=true
                else
                    echo -e "  ${YELLOW}!${NC} ${filename} (別のリンク先)"
                fi
            elif [[ -f "$target_link" ]]; then
                echo -e "  ${YELLOW}!${NC} ${filename} (実ファイルが存在)"
            else
                echo -e "  ${RED}✗${NC} ${filename} (未インストール)"
            fi
        done < <(find "$REPO_SUBAGENTS_DIR" -name "*.md" -type f -print0)
    else
        echo "  (ディレクトリが存在しません)"
    fi

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

    case "$command" in
        install)
            check_source_dirs
            warn_if_worktree
            init_claude_dir
            install_scripts "$prune_scripts"
            echo ""
            install_skills
            echo ""
            install_subagents
            echo ""
            install_settings
            echo ""
            log_success "セットアップが完了しました！"
            echo ""
            echo "確認するには: ./setup.sh status"
            ;;
        uninstall)
            uninstall
            ;;
        status)
            show_status
            ;;
        migrate)
            check_source_dirs
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
