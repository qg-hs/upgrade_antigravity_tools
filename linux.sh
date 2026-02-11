#!/bin/bash
set -e

# =============================================================================
# Antigravity Tools 自动更新脚本 - Linux 版
# =============================================================================

# 配置常量
readonly REPO="lbjlaq/Antigravity-Manager"
readonly APP_NAME="Antigravity Tools"
readonly APP_BIN_NAME="antigravity-tools"
readonly INSTALL_DIR_SYSTEM="/opt/antigravity-tools"
readonly INSTALL_DIR_USER="$HOME/.local/share/antigravity-tools"
readonly DESKTOP_FILE_PATH="$HOME/.local/share/applications/antigravity-tools.desktop"
readonly TMP_DIR="/tmp/antigravity-updater-$$"
readonly API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
readonly CURL_TIMEOUT=30
readonly MIN_FREE_SPACE_MB=500

# ANSI颜色代码
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_CYAN='\033[0;36m'

# 安装模式(user/system)，默认 user
INSTALL_MODE="user"

# 清理函数(异常退出时调用)
cleanup_on_error() {
  echo -e "${C_RED}⚠️  异常退出，清理临时文件...${C_RESET}" >&2
  rm -rf "$TMP_DIR"
}
trap cleanup_on_error EXIT

# =============================================================================
# 工具函数
# =============================================================================

# 检查命令是否存在
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${C_RED}❌ 缺少依赖命令: ${cmd}${C_RESET}"
    echo "请先安装: sudo apt install ${cmd} / sudo dnf install ${cmd}"
    exit 1
  fi
}

# 语义化版本比较(返回0表示$1 > $2)
ver_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# 读取已安装版本
read_installed_version() {
  local install_dir="$1"
  local exe_path="${install_dir}/${APP_BIN_NAME}"
  # 尝试 --version 参数
  if [ -x "$exe_path" ]; then
    local ver_output
    ver_output=$("$exe_path" --version 2>/dev/null || true)
    echo "$ver_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
    return
  fi
  # 尝试读取版本文件
  local ver_file="${install_dir}/version"
  if [ -f "$ver_file" ]; then
    cat "$ver_file"
    return
  fi
  echo ""
}

# 查找已安装应用
find_installed_app() {
  # 优先级: 系统级安装 > 用户级安装 > PATH 中查找
  if [ -d "$INSTALL_DIR_SYSTEM" ] && [ -x "${INSTALL_DIR_SYSTEM}/${APP_BIN_NAME}" ]; then
    echo "$INSTALL_DIR_SYSTEM"
    return 0
  fi

  if [ -d "$INSTALL_DIR_USER" ] && [ -x "${INSTALL_DIR_USER}/${APP_BIN_NAME}" ]; then
    echo "$INSTALL_DIR_USER"
    return 0
  fi

  # 检查 PATH
  local found
  found=$(command -v "$APP_BIN_NAME" 2>/dev/null || echo "")
  if [ -n "$found" ]; then
    dirname "$(readlink -f "$found")"
    return 0
  fi

  # 检查 AppImage
  local appimage_path="$HOME/Applications/${APP_NAME}.AppImage"
  if [ -f "$appimage_path" ]; then
    echo "$HOME/Applications"
    return 0
  fi

  echo ""
}

# 检查磁盘空间
check_disk_space() {
  local target_dir="$1"
  local free_mb
  free_mb=$(df -m "$(dirname "$target_dir")" 2>/dev/null | tail -1 | awk '{print $4}')
  if [ -n "$free_mb" ] && [ "$free_mb" -lt "$MIN_FREE_SPACE_MB" ]; then
    echo -e "${C_RED}❌ 磁盘空间不足(需要${MIN_FREE_SPACE_MB}MB，当前${free_mb}MB)${C_RESET}"
    exit 1
  fi
}

# 从JSON提取字段(优先使用jq，回退正则)
parse_json_field() {
  local json="$1"
  local field="$2"

  if command -v jq &>/dev/null; then
    echo "$json" | jq -r ".${field} // empty" 2>/dev/null
  else
    echo "$json" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)".*/\1/' | head -n 1
  fi
}

# 选择下载URL(根据架构优先级匹配)
pick_download_url() {
  local json="$1"
  local pattern="$2"

  if command -v jq &>/dev/null; then
    echo "$json" | jq -r '.assets[].browser_download_url' 2>/dev/null | grep -E "$pattern" | head -n 1
  else
    echo "$json" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | \
      sed 's/.*"\([^"]*\)".*/\1/' | grep -E "$pattern" | head -n 1
  fi
}

# 显示更新日志
show_release_notes() {
  local json="$1"
  local old_ver="$2"
  local new_ver="$3"

  echo ""
  echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo -e "${C_CYAN}📋 版本更新日志: v${old_ver:-无} → v${new_ver}${C_RESET}"
  echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"

  local release_body=""
  if command -v jq &>/dev/null; then
    release_body=$(echo "$json" | jq -r '.body // empty' 2>/dev/null)
  else
    release_body=$(echo "$json" | sed -n 's/.*"body"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*}$/\1/p' | sed 's/\\n/\n/g' | sed 's/\\r//g')
  fi

  if [ -n "$release_body" ]; then
    echo "$release_body" | head -20
    echo ""
  else
    echo "未找到更新说明，访问完整发布页:"
    echo "https://github.com/${REPO}/releases/latest"
    echo ""
  fi

  echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo ""
}

# 安装 AppImage
install_appimage() {
  local src_file="$1"
  local target_dir="$2"
  local target_path="${target_dir}/${APP_NAME}.AppImage"

  mkdir -p "$target_dir"
  cp "$src_file" "$target_path"
  chmod +x "$target_path"

  # 创建符号链接到 PATH
  if [ "$INSTALL_MODE" = "system" ]; then
    sudo ln -sf "$target_path" "/usr/local/bin/${APP_BIN_NAME}"
  else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$target_path" "$HOME/.local/bin/${APP_BIN_NAME}"
  fi

  echo -e "${C_GREEN}✅ AppImage 已安装: ${target_path}${C_RESET}"
}

# 安装 deb 包
install_deb() {
  local deb_file="$1"
  echo -e "${C_GREEN}📦 安装 .deb 包(需要管理员密码)...${C_RESET}"
  if command -v apt &>/dev/null; then
    sudo apt install -y "$deb_file"
  elif command -v dpkg &>/dev/null; then
    sudo dpkg -i "$deb_file" || sudo apt-get install -f -y
  else
    echo -e "${C_RED}❌ 未找到 apt/dpkg，无法安装 .deb 包${C_RESET}"
    exit 1
  fi
}

# 安装 rpm 包
install_rpm() {
  local rpm_file="$1"
  echo -e "${C_GREEN}📦 安装 .rpm 包(需要管理员密码)...${C_RESET}"
  if command -v dnf &>/dev/null; then
    sudo dnf install -y "$rpm_file"
  elif command -v rpm &>/dev/null; then
    sudo rpm -Uvh "$rpm_file"
  else
    echo -e "${C_RED}❌ 未找到 dnf/rpm，无法安装 .rpm 包${C_RESET}"
    exit 1
  fi
}

# 安装 tar.gz 压缩包
install_tarball() {
  local tarball="$1"
  local target_dir="$2"

  echo -e "${C_GREEN}📦 解压安装包...${C_RESET}"
  local extract_dir="${TMP_DIR}/extracted"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  tar -xzf "$tarball" -C "$extract_dir" || {
    echo -e "${C_RED}❌ 解压失败${C_RESET}"
    exit 1
  }

  # 查找可执行文件
  local found_exe
  found_exe=$(find "$extract_dir" -maxdepth 4 -name "${APP_BIN_NAME}" -type f | head -n 1)
  [ -z "$found_exe" ] && found_exe=$(find "$extract_dir" -maxdepth 4 -name "$(echo "$APP_NAME" | tr ' ' '-')" -type f | head -n 1)

  if [ -z "$found_exe" ]; then
    echo -e "${C_RED}❌ 未在压缩包中找到可执行文件${C_RESET}"
    echo "目录内容:"
    ls -laR "$extract_dir"
    exit 1
  fi

  local source_dir
  source_dir=$(dirname "$found_exe")

  # 安装文件
  if [ "$INSTALL_MODE" = "system" ]; then
    sudo rm -rf "$target_dir"
    sudo mkdir -p "$target_dir"
    sudo cp -R "$source_dir"/* "$target_dir"/
    sudo chmod +x "${target_dir}/${APP_BIN_NAME}" 2>/dev/null || true
    sudo ln -sf "${target_dir}/${APP_BIN_NAME}" "/usr/local/bin/${APP_BIN_NAME}"
  else
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    cp -R "$source_dir"/* "$target_dir"/
    chmod +x "${target_dir}/${APP_BIN_NAME}" 2>/dev/null || true
    mkdir -p "$HOME/.local/bin"
    ln -sf "${target_dir}/${APP_BIN_NAME}" "$HOME/.local/bin/${APP_BIN_NAME}"
  fi

  echo -e "${C_GREEN}✅ 已安装至: ${target_dir}${C_RESET}"
}

# 创建桌面快捷方式(.desktop 文件)
create_desktop_entry() {
  local install_dir="$1"
  local exec_path="${install_dir}/${APP_BIN_NAME}"
  local icon_path="${install_dir}/icon.png"
  [ ! -f "$icon_path" ] && icon_path=""

  mkdir -p "$(dirname "$DESKTOP_FILE_PATH")"
  cat > "$DESKTOP_FILE_PATH" << EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=${exec_path}
Icon=${icon_path}
Terminal=false
Categories=Utility;Development;
Comment=Antigravity Tools Application
EOF
  chmod +x "$DESKTOP_FILE_PATH" 2>/dev/null || true
  # 更新桌面数据库
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
}

# =============================================================================
# 主逻辑
# =============================================================================

# 检查基本依赖
require_cmd curl

# 解析参数
while [ $# -gt 0 ]; do
  case "$1" in
    --system)
      INSTALL_MODE="system"
      shift
      ;;
    --user)
      INSTALL_MODE="user"
      shift
      ;;
    *)
      echo -e "${C_YELLOW}未知参数: $1${C_RESET}"
      shift
      ;;
  esac
done

INSTALL_DIR="$INSTALL_DIR_USER"
if [ "$INSTALL_MODE" = "system" ]; then
  INSTALL_DIR="$INSTALL_DIR_SYSTEM"
fi

mkdir -p "$TMP_DIR"

# ---------- 1) 获取最新版本信息 ----------
echo -e "${C_CYAN}🔎 检查 GitHub 最新版本...${C_RESET}"
JSON="$(curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 "$API_LATEST" 2>&1)" || {
  echo -e "${C_RED}❌ 网络请求失败(超时${CURL_TIMEOUT}s)，请检查网络或稍后重试${C_RESET}"
  rm -rf "$TMP_DIR"
  exit 1
}

LATEST_TAG="$(parse_json_field "$JSON" "tag_name")"
if [ -z "$LATEST_TAG" ]; then
  echo -e "${C_RED}❌ 无法解析 tag_name，API响应异常${C_RESET}"
  echo "响应前500字符:"
  echo "$JSON" | head -c 500
  rm -rf "$TMP_DIR"
  exit 1
fi

LATEST_VER="${LATEST_TAG#v}"
echo -e "📦 GitHub最新版本: ${C_GREEN}${LATEST_TAG}${C_RESET}"

# ---------- 2) 获取本地已安装版本 ----------
INSTALLED_APP_PATH="$(find_installed_app)"
INSTALLED_VER=""

if [ -n "$INSTALLED_APP_PATH" ]; then
  INSTALLED_VER="$(read_installed_version "$INSTALLED_APP_PATH")"
  if [ -n "$INSTALLED_VER" ]; then
    echo -e "💻 本地安装版本: ${C_YELLOW}v${INSTALLED_VER}${C_RESET}  (${INSTALLED_APP_PATH})"
  else
    echo -e "${C_YELLOW}💻 本地应用存在但版本号不可读取: ${INSTALLED_APP_PATH}${C_RESET}"
  fi
else
  echo -e "💻 本地安装版本: ${C_YELLOW}(未检测到)${C_RESET}"
fi

# ---------- 3) 版本比较与决策 ----------
if [ -n "$INSTALLED_VER" ] && ! ver_gt "$LATEST_VER" "$INSTALLED_VER"; then
  echo ""
  echo -e "${C_GREEN}✅ 已是最新版本，无需更新${C_RESET}"
  rm -rf "$TMP_DIR"
  trap - EXIT
  exit 0
fi

# 展示更新日志
show_release_notes "$JSON" "$INSTALLED_VER" "$LATEST_VER"

# 确认安装/更新
if [ -n "$INSTALLED_VER" ]; then
  action_text="更新"
else
  action_text="安装"
fi

echo -e "${C_YELLOW}⚠️  即将${action_text}: v${INSTALLED_VER:-无} → v${LATEST_VER}${C_RESET}"
printf "确认${action_text}? (y/N): "
read -r ANS
case "$ANS" in
  y|Y|yes|YES) ;;
  *)
    echo -e "${C_RED}🚫 用户取消${C_RESET}"
    rm -rf "$TMP_DIR"
    trap - EXIT
    exit 0
    ;;
esac

# 检查磁盘空间
check_disk_space "$INSTALL_DIR"

# ---------- 4) 选择下载资源(根据架构适配) ----------
ARCH="$(uname -m)"
echo "🖥️  系统架构: ${ARCH}"

# 检测发行版(用于选择包格式)
DISTRO_FAMILY="unknown"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "$ID" in
    ubuntu|debian|linuxmint|pop|elementary|zorin)
      DISTRO_FAMILY="debian"
      ;;
    fedora|rhel|centos|rocky|alma|opensuse*)
      DISTRO_FAMILY="redhat"
      ;;
    arch|manjaro|endeavouros)
      DISTRO_FAMILY="arch"
      ;;
  esac
fi
echo "📋 发行版系列: ${DISTRO_FAMILY}"

URL=""
case "$ARCH" in
  x86_64|amd64)
    ARCH_PATTERN="(x86_64|amd64|x64)"
    ;;
  aarch64|arm64)
    ARCH_PATTERN="(aarch64|arm64)"
    ;;
  armv7*|armhf)
    ARCH_PATTERN="(armv7|armhf)"
    ;;
  *)
    ARCH_PATTERN="$ARCH"
    ;;
esac

# 按发行版系列选择包格式优先级
case "$DISTRO_FAMILY" in
  debian)
    URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.deb$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.AppImage$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.tar\.gz$")"
    ;;
  redhat)
    URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.rpm$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.AppImage$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.tar\.gz$")"
    ;;
  *)
    URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.AppImage$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.tar\.gz$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.deb$")"
    [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity.*${ARCH_PATTERN}.*\.rpm$")"
    ;;
esac

if [ -z "$URL" ]; then
  echo -e "${C_RED}❌ 未找到适配当前架构(${ARCH})的下载资源${C_RESET}"
  echo "可用资源列表:"
  if command -v jq &>/dev/null; then
    echo "$JSON" | jq -r '.assets[].browser_download_url' 2>/dev/null
  else
    echo "$JSON" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)".*/\1/'
  fi
  rm -rf "$TMP_DIR"
  exit 1
fi

FILE_NAME="$(basename "$URL")"
FILE_PATH="${TMP_DIR}/${FILE_NAME}"

# ---------- 5) 下载文件(带进度条) ----------
echo ""
echo -e "${C_CYAN}⬇️  下载中: ${FILE_NAME}${C_RESET}"
echo "   URL: $URL"

curl -fL --max-time 600 --connect-timeout 10 --retry 3 --retry-delay 2 \
  --progress-bar "$URL" -o "$FILE_PATH" || {
  echo -e "${C_RED}❌ 下载失败，请检查网络连接${C_RESET}"
  rm -rf "$TMP_DIR"
  exit 1
}

# 验证文件非空
if [ ! -s "$FILE_PATH" ]; then
  echo -e "${C_RED}❌ 下载文件无效(大小为0)${C_RESET}"
  rm -rf "$TMP_DIR"
  exit 1
fi

echo "✅ 下载完成: $(du -h "$FILE_PATH" | cut -f1)"

# ---------- 6) 安装 ----------
# 关闭正在运行的应用
if pgrep -f "$APP_BIN_NAME" >/dev/null 2>&1; then
  echo -e "${C_YELLOW}⏳ 正在关闭运行中的 ${APP_NAME}...${C_RESET}"
  pkill -f "$APP_BIN_NAME" || true
  sleep 2
fi

EXT="${FILE_NAME##*.}"
case "$FILE_NAME" in
  *.tar.gz|*.tgz)
    install_tarball "$FILE_PATH" "$INSTALL_DIR"
    ;;
  *.AppImage)
    if [ "$INSTALL_MODE" = "system" ]; then
      install_appimage "$FILE_PATH" "/opt"
    else
      install_appimage "$FILE_PATH" "$HOME/Applications"
    fi
    ;;
  *.deb)
    install_deb "$FILE_PATH"
    ;;
  *.rpm)
    install_rpm "$FILE_PATH"
    ;;
  *)
    echo -e "${C_RED}❌ 不支持的文件格式: ${FILE_NAME}${C_RESET}"
    rm -rf "$TMP_DIR"
    exit 1
    ;;
esac

# 写入版本文件(方便后续版本检测)
if [ -d "$INSTALL_DIR" ]; then
  if [ "$INSTALL_MODE" = "system" ]; then
    echo "$LATEST_VER" | sudo tee "${INSTALL_DIR}/version" >/dev/null
  else
    echo "$LATEST_VER" > "${INSTALL_DIR}/version"
  fi
fi

# 创建桌面快捷方式
create_desktop_entry "$INSTALL_DIR"

# ---------- 7) 清理与完成 ----------
rm -rf "$TMP_DIR"
trap - EXIT

echo ""
echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_GREEN}🎉 ${action_text}成功! v${LATEST_VER}${C_RESET}"
echo -e "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "${C_GREEN}🚀 启动: ${APP_BIN_NAME}${C_RESET}"
