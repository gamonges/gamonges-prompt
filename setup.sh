#!/bin/bash

# =============================================================================
# Claude Skills & SubAgents セットアップスクリプト
# =============================================================================
#
# このスクリプトは、リポジトリ内の Skills, SubAgents を
# ~/.claude/ 配下にシンボリックリンクとして配置します。
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

# Scripts のインストール
install_scripts() {
    log_info "Scripts をインストールしています..."
    local scripts_dir="${SCRIPT_DIR}/claude/scripts"
    local target_dir="${CLAUDE_DIR}/scripts"
    mkdir -p "$target_dir"

    local count=0
    for script in "$scripts_dir"/*.sh "$scripts_dir"/*.py; do
        [ -f "$script" ] || continue
        local name=$(basename "$script")
        local target_link="${target_dir}/${name}"

        if [[ -L "$target_link" ]]; then
            rm "$target_link"
        fi

        ln -s "$script" "$target_link"
        chmod +x "$script"
        log_success "  ✓ ${name}"
        ((count++))
    done
    log_info "Scripts: ${count} 件インストール完了"
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

            # 既存のリンクまたはディレクトリを処理
            if [[ -L "$target_link" ]]; then
                log_warning "既存のシンボリックリンクを更新: ${skill_name}"
                rm "$target_link"
            elif [[ -d "$target_link" ]]; then
                log_warning "既存のディレクトリをバックアップ: ${skill_name}"
                mv "$target_link" "${target_link}.backup.$(date +%Y%m%d%H%M%S)"
            fi

            ln -s "$skill_dir" "$target_link"
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

        # 既存のリンクまたはファイルを処理
        if [[ -L "$target_link" ]]; then
            log_warning "既存のシンボリックリンクを更新: ${filename}"
            rm "$target_link"
        elif [[ -f "$target_link" ]]; then
            log_warning "既存のファイルをバックアップ: ${filename}"
            mv "$target_link" "${target_link}.backup.$(date +%Y%m%d%H%M%S)"
        fi

        ln -s "$md_file" "$target_link"
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
            local link_target=$(readlink "$target_link")
            if [[ "$link_target" == "$script" ]]; then
                rm "$target_link"
                log_success "  ✓ 削除: ${name}"
                ((scripts_count++))
            fi
        fi
    done

    log_info "削除完了 - Scripts: ${scripts_count} 件, Skills: ${skills_count} 件, Commands: ${commands_count} 件, SubAgents: ${subagents_count} 件"
}

# 状態表示
show_status() {
    echo ""
    echo "=========================================="
    echo "  Claude Scripts, Skills, SubAgents 状態"
    echo "=========================================="
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
                local link_target=$(readlink "$target_link")
                if [[ "$link_target" == "$script" ]]; then
                    echo -e "  ${GREEN}✓${NC} ${name} (リンク済み)"
                    has_scripts=true
                else
                    echo -e "  ${YELLOW}!${NC} ${name} (別のリンク先)"
                fi
            elif [[ -f "$target_link" ]]; then
                echo -e "  ${YELLOW}!${NC} ${name} (実ファイルが存在)"
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

    case "$command" in
        install)
            check_source_dirs
            init_claude_dir
            install_scripts
            echo ""
            install_skills
            echo ""
            install_subagents
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
            echo "使用方法: $0 {install|uninstall|status|migrate}"
            exit 1
            ;;
    esac
}

main "$@"
