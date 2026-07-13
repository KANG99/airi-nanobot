#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Airi + nanobot 一键部署脚本
#
# 用法:
#   chmod +x setup.sh
#   ./setup.sh
#
# 做什么:
#   1. clone airi 和 nanobot 到脚本所在目录
#   2. 配置并启动 nanobot Docker 服务 (gateway + api)
#   3. 启动 CORS 代理（消息合并 + CORS 头）
#   4. 安装 airi 依赖并启动 dev server
#   5. 自动配置 Airi 的 nanobot provider（localStorage 注入）
#   6. 打开浏览器完成 Airi 设置
#
# 再次运行会跳过已完成步骤（clone、install）
# ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIRI_DIR="$SCRIPT_DIR/airi"
NANOBOT_DIR="$SCRIPT_DIR/nanobot"
CORS_PROXY="$SCRIPT_DIR/cors-proxy.py"
SETUP_HTML="$SCRIPT_DIR/nanobot-setup.html"
CONFIG_TOOL="$SCRIPT_DIR/nanobot_config.py"
AIRI_PUBLIC_DIR="$AIRI_DIR/apps/stage-web/public"
BASE_URL="http://127.0.0.1:18900/v1/"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

banner()  { echo -e "${CYAN}==>${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }

# ──────────────────────────────────────────────────────────────────────
# 依赖检查
# ──────────────────────────────────────────────────────────────────────

check_deps() {
    banner "检查依赖..."

    for cmd in git docker node pnpm python3 curl; do
        command -v "$cmd" &>/dev/null || fail "缺少 $cmd，请先安装"
    done

    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        fail "缺少 docker compose"
    fi

    success "依赖检查通过"
}

# ──────────────────────────────────────────────────────────────────────
# Clone 仓库
# ──────────────────────────────────────────────────────────────────────

clone_repos() {
    banner "Clone/更新仓库..."

    for repo in airi nanobot; do
        local dir url
        if [ "$repo" = "airi" ]; then
            dir="$AIRI_DIR"
            url="https://github.com/moeru-ai/airi.git"
        else
            dir="$NANOBOT_DIR"
            url="https://github.com/HKUDS/nanobot.git"
        fi

        if [ -d "$dir/.git" ]; then
            banner "更新 $repo..."
            cd "$dir"
            git pull --ff-only || warn "$repo git pull 失败，继续使用当前版本"
            cd "$SCRIPT_DIR"
        else
            rm -rf "$dir"
            git clone "$url" "$dir"
            success "$repo clone 完成"
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────
# nanobot 配置
# ──────────────────────────────────────────────────────────────────────

setup_nanobot_config() {
    banner "配置 nanobot..."

    # generate key + write config in one call
    local result
    result=$(python3 "$CONFIG_TOOL" setup)
    local api_key config_path
    api_key=$(echo "$result" | head -1)
    config_path=$(echo "$result" | tail -1)

    success "nanobot 配置已写入 $config_path"
    echo -e "  API Key: ${CYAN}$api_key${NC}"

    API_KEY="$api_key"
}

# ──────────────────────────────────────────────────────────────────────
# nanobot 交互式配置引导（provider / model / API key）
# ──────────────────────────────────────────────────────────────────────

onboard_nanobot() {
    banner "nanobot 配置引导 (onboard --wizard)"
    echo ""
    echo ""
    echo -e "  ${YELLOW}[1]${NC} 运行 nanobot onboard --wizard 配置 LLM provider"
    echo -e "  ${YELLOW}[2]${NC} 跳过，使用已有配置"
    echo ""
    local choice
    read -r -p "  请选择 (1/2): " choice

    if [ "$choice" = "1" ]; then
        cd "$NANOBOT_DIR"
        $DOCKER_COMPOSE run --rm nanobot-cli onboard --wizard || true
        cd "$SCRIPT_DIR"
    else
        warn "跳过 provider 配置，使用已有配置"
    fi

    # 刷新可能被 wizard 改过的 API key
    API_KEY=$(python3 "$CONFIG_TOOL" get-api-key)

    # 修复 localhost → host.docker.internal（Ollama 等本地模型）
    fix_nanobot_localhost

    success "onboard 完成"
}

# ──────────────────────────────────────────────────────────────────────
# 修复 Docker 容器内 localhost 指向问题
# ──────────────────────────────────────────────────────────────────────

fix_nanobot_localhost() {
    local result
    result=$(python3 "$CONFIG_TOOL" fix-localhost)
    if [ -n "$result" ] && [ "$result" != "(no localhost api_base entries found)" ]; then
        banner "修复 Docker 本地 provider 地址..."
        echo -e "  $result"
        success "localhost → host.docker.internal"
    fi
}

# ──────────────────────────────────────────────────────────────────────
# nanobot Docker 镜像构建
# ──────────────────────────────────────────────────────────────────────

build_nanobot() {
    banner "构建 nanobot Docker 镜像..."

    # npm ci 需要 lock 文件与 package.json 一致，上游 lock 文件可能过期
    if [ -f "$NANOBOT_DIR/webui/package.json" ]; then
        banner "同步 webui lock 文件..."
        cd "$NANOBOT_DIR/webui"
        npm install --package-lock-only 2>/dev/null || npm install
        cd "$SCRIPT_DIR"
    fi

    cd "$NANOBOT_DIR"
    $DOCKER_COMPOSE build --build-arg NANOBOT_EXTRAS=whatsapp,api
    cd "$SCRIPT_DIR"
    success "镜像构建完成"
}

# ──────────────────────────────────────────────────────────────────────
# nanobot Docker 启动
# ──────────────────────────────────────────────────────────────────────

start_nanobot() {
    banner "启动 nanobot 服务..."

    cd "$NANOBOT_DIR"
    $DOCKER_COMPOSE up -d nanobot-gateway nanobot-api

    # 等待就绪
    banner "等待 nanobot 就绪..."
    local ok=0
    for i in $(seq 1 30); do
        if curl -sf http://127.0.0.1:8900/v1/models \
            -H "Authorization: Bearer $API_KEY" &>/dev/null; then
            ok=1; break
        fi
        sleep 2
    done
    if [ "$ok" -eq 0 ]; then
        fail "nanobot API 启动超时，请检查: cd $NANOBOT_DIR && $DOCKER_COMPOSE logs nanobot-api"
    fi
    success "nanobot API 就绪"
    cd "$SCRIPT_DIR"
}

# ──────────────────────────────────────────────────────────────────────
# CORS 代理
# ──────────────────────────────────────────────────────────────────────

start_proxy() {
    banner "启动 CORS 代理..."

    # 检查是否已有代理在跑
    if lsof -ti :18900 &>/dev/null; then
        warn "端口 18900 已被占用，跳过代理启动"
        return
    fi

    if [ ! -f "$CORS_PROXY" ]; then
        fail "找不到 $CORS_PROXY"
    fi

    python3 "$CORS_PROXY" &
    disown %%
    sleep 1

    if curl -sf http://127.0.0.1:18900/v1/models \
        -H "Authorization: Bearer $API_KEY" &>/dev/null; then
        success "CORS 代理已启动 (port 18900)"
    else
        fail "CORS 代理启动失败"
    fi
}

# ──────────────────────────────────────────────────────────────────────
# Airi 自动配置（localStorage 注入）
# ──────────────────────────────────────────────────────────────────────

setup_airi_config() {
    banner "部署 Airi provider 配置页..."

    if [ ! -d "$AIRI_PUBLIC_DIR" ]; then
        warn "Airi public 目录不存在: $AIRI_PUBLIC_DIR，跳过自动配置"
        return
    fi

    sed -e "s|__BASE_URL__|$BASE_URL|g" \
        -e "s|__API_KEY__|$API_KEY|g" \
        "$SETUP_HTML" > "$AIRI_PUBLIC_DIR/nanobot-setup.html"

    success "配置页已部署到 $AIRI_PUBLIC_DIR/nanobot-setup.html"
}

teardown_airi_config() {
    local f="$AIRI_PUBLIC_DIR/nanobot-setup.html"
    if [ -f "$f" ]; then
        rm -f "$f"
        success "已清理 $f"
    fi
}

# ──────────────────────────────────────────────────────────────────────
# 打开浏览器
# ──────────────────────────────────────────────────────────────────────

open_browser() {
    local port="${AIRI_PORT:-5173}"
    local url="http://localhost:${port}/nanobot-setup.html"

    # 等待 Airi dev server 就绪
    banner "等待 Airi dev server..."
    for i in $(seq 1 30); do
        if curl -sf -o /dev/null "http://localhost:${port}/" 2>/dev/null; then
            break
        fi
        sleep 2
    done

    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    else
        echo -e "  请手动打开: ${CYAN}$url${NC}"
    fi
    success "浏览器已打开: $url"

    echo ""
    echo -e "  浏览器将自动配置 Airi provider，完成后按 ${YELLOW}Enter${NC} 继续..."
    read -r
}

# ──────────────────────────────────────────────────────────────────────
# Airi 依赖 & 启动
# ──────────────────────────────────────────────────────────────────────

setup_airi() {
    banner "安装 Airi 依赖 (pnpm) — 首次较慢，请耐心等待..."
    cd "$AIRI_DIR"
    pnpm install
    success "pnpm install 完成"
    cd "$SCRIPT_DIR"
}

start_airi() {
    banner "启动 Airi dev server..."

    AIRI_PORT=5173
    if lsof -ti :5173 &>/dev/null; then
        AIRI_PORT=5174
        warn "端口 5173 已被占用，使用 $AIRI_PORT"
    fi

    cd "$AIRI_DIR"
    VITE_PORT=$AIRI_PORT pnpm run dev:web &
    disown %%
    sleep 3
    cd "$SCRIPT_DIR"
}

# ──────────────────────────────────────────────────────────────────────
# 完成
# ──────────────────────────────────────────────────────────────────────

print_guide() {
    local port="${AIRI_PORT:-5173}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  部署完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  浏览器应已自动打开配置页面。如未打开，手动访问:"
    echo -e "  ${CYAN}http://localhost:${port}/nanobot-setup.html${NC}"
    echo ""
    echo -e "  配置完成后在 Airi 中:"
    echo -e "  Settings → Providers → Chat → nanobot"
    echo ""
    echo -e "  凭证信息:"
    echo -e "    ${YELLOW}Base URL${NC}: ${CYAN}$BASE_URL${NC}"
    echo -e "    ${YELLOW}API Key${NC} : ${CYAN}$API_KEY${NC}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────

cleanup() {
    echo ""
    banner "清理..."

    # 清理 Airi public 中的配置页
    teardown_airi_config 2>/dev/null || true

    # 停止 CORS 代理
    if lsof -ti :18900 &>/dev/null; then
        kill "$(lsof -ti :18900)" 2>/dev/null || true
        success "CORS 代理已停止 (port 18900)"
    fi

    # 停止 Airi dev server
    if lsof -ti :"${AIRI_PORT:-5173}" &>/dev/null; then
        kill "$(lsof -ti :"${AIRI_PORT:-5173}")" 2>/dev/null || true
        success "Airi dev server 已停止"
    fi

    # 停止 nanobot Docker 服务
    if [ -f "$NANOBOT_DIR/docker-compose.yml" ]; then
        cd "$NANOBOT_DIR"
        $DOCKER_COMPOSE down nanobot-gateway nanobot-api 2>/dev/null || true
        cd "$SCRIPT_DIR"
        success "nanobot Docker 服务已停止"
    fi

    echo -e "${YELLOW}已中断${NC}"
    exit 130
}

trap cleanup INT TERM

check_deps
clone_repos
setup_nanobot_config
build_nanobot
onboard_nanobot
start_nanobot
start_proxy
setup_airi
setup_airi_config
start_airi
open_browser
teardown_airi_config
print_guide

echo -e "${CYAN}所有服务已启动。按 Ctrl+C 停止。${NC}"
wait
