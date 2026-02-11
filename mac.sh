#!/bin/sh
set -e

# =============================================================================
# Antigravity Tools 自动更新脚本 - 生产级优化版
# =============================================================================

# 配置常量
readonly REPO="lbjlaq/Antigravity-Manager"
readonly APP_NAME="Antigravity Tools"
readonly DEFAULT_APP_PATH="/Applications/${APP_NAME}.app"
readonly TMP_DIR="/tmp/antigravity-updater-$$"
readonly API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
readonly CURL_TIMEOUT=30
readonly MIN_FREE_SPACE_MB=1000  # 原子替换需要双倍空间

# ANSI颜色代码
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_CYAN='\033[0;36m'

# 清理函数(异常退出时调用)
cleanup_on_error() {
  echo "${C_RED}⚠️  异常退出，清理临时文件...${C_RESET}" >&2
  rm -rf "$TMP_DIR"
}
trap cleanup_on_error EXIT

# =============================================================================
# 工具函数
# =============================================================================

# 语义化版本比较(返回0表示$1 > $2)
ver_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | /usr/bin/sort -V | tail -n 1)" = "$1" ]
}

# 读取已安装版本
read_installed_version() {
  local app_path="$1"
  /usr/bin/defaults read "${app_path}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo ""
}

# 查找已安装应用(优先级: /Applications > ~/Applications > Spotlight)
find_installed_app() {
  if [ -d "$DEFAULT_APP_PATH" ]; then
    echo "$DEFAULT_APP_PATH"
    return 0
  fi

  local user_app="$HOME/Applications/${APP_NAME}.app"
  if [ -d "$user_app" ]; then
    echo "$user_app"
    return 0
  fi

  local found="$(/usr/bin/mdfind "kMDItemFSName == '${APP_NAME}.app' && kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null | head -n 1 || echo "")"
  if [ -n "$found" ] && [ -d "$found" ]; then
    echo "$found"
    return 0
  fi

  echo ""
}

# 校验应用完整性
validate_app() {
  local app_path="$1"
  
  # 检查基本目录结构
  if [ ! -d "${app_path}/Contents" ]; then
    echo "${C_RED}❌ 校验失败: 缺少 Contents 目录${C_RESET}"
    return 1
  fi
  
  if [ ! -f "${app_path}/Contents/Info.plist" ]; then
    echo "${C_RED}❌ 校验失败: 缺少 Info.plist${C_RESET}"
    return 1
  fi
  
  # 验证 Info.plist 可读性
  if ! /usr/bin/defaults read "${app_path}/Contents/Info" CFBundleShortVersionString >/dev/null 2>&1; then
    echo "${C_RED}❌ 校验失败: Info.plist 损坏或不可读${C_RESET}"
    return 1
  fi
  
  # 检查可执行文件
  local exec_name="$(/usr/bin/defaults read "${app_path}/Contents/Info" CFBundleExecutable 2>/dev/null || echo "")"
  if [ -n "$exec_name" ]; then
    local exec_path="${app_path}/Contents/MacOS/${exec_name}"
    if [ ! -x "$exec_path" ]; then
      echo "${C_RED}❌ 校验失败: 可执行文件不存在或无执行权限${C_RESET}"
      return 1
    fi
  fi
  
  return 0
}

# 检查磁盘空间(至少500MB可用)
check_disk_space() {
  local free_mb=$(df -m /Applications | tail -1 | awk '{print $4}')
  if [ "$free_mb" -lt "$MIN_FREE_SPACE_MB" ]; then
    echo "${C_RED}❌ 磁盘空间不足(需要${MIN_FREE_SPACE_MB}MB，当前${free_mb}MB)${C_RESET}"
    exit 1
  fi
}

# 从JSON提取字段(健壮型解析，优先使用plutil/jq)
parse_json_field() {
  local json="$1"
  local field="$2"
  
  # 尝试使用macOS原生plutil(最可靠)
  if command -v plutil >/dev/null; then
    echo "$json" | plutil -extract "$field" raw - 2>/dev/null || \
      echo "$json" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)".*/\1/' | head -n 1
  else
    # 回退到grep+sed
    echo "$json" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)".*/\1/' | head -n 1
  fi
}

# 选择下载URL(根据架构优先级匹配)
pick_download_url() {
  local json="$1"
  local pattern="$2"
  echo "$json" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | \
    sed 's/.*"\([^"]*\)".*/\1/' | grep -E "$pattern" | head -n 1
}

# 显示更新日志(GitHub Release内容)
show_release_notes() {
  local json="$1"
  local old_ver="$2"
  local new_ver="$3"
  
  echo ""
  echo "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo "${C_CYAN}📋 版本更新日志: v${old_ver:-无} → v${new_ver}${C_RESET}"
  echo "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  
  # 提取发布说明(body字段，可能包含换行符)
  local release_body=""
  # macOS 原生 plutil 可靠提取 JSON 字段
  if command -v plutil >/dev/null; then
    release_body=$(echo "$json" | plutil -extract "body" raw - 2>/dev/null || echo "")
  fi
  # plutil 失败时回退到 sed（body 是 JSON 最后一个字段，匹配到末尾 "} ）
  if [ -z "$release_body" ]; then
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
  
  echo "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo ""
}

# 安装应用(从指定目录搜索并安装)
install_from_dir() {
  local src_dir="$1"
  local found_app="$(find "$src_dir" -maxdepth 4 -name "${APP_NAME}.app" -print | head -n 1)"

  if [ -z "$found_app" ] || [ ! -d "$found_app" ]; then
    echo "${C_RED}❌ 未在提取目录中找到 ${APP_NAME}.app${C_RESET}"
    echo "   目录内容: $src_dir"
    ls -la "$src_dir" || true
    exit 1
  fi

  echo "${C_GREEN}📁 准备安装至 /Applications...${C_RESET}"
  
  # 步骤1: 复制到临时位置
  local temp_app="${DEFAULT_APP_PATH}.new-$$"
  echo "   复制应用到临时位置..."
  if ! cp -R "$found_app" "$temp_app"; then
    echo "${C_RED}❌ 复制失败，可能磁盘空间不足${C_RESET}"
    rm -rf "$temp_app" 2>/dev/null || true
    exit 1
  fi
  
  # 步骤2: 校验完整性
  echo "   校验应用完整性..."
  if ! validate_app "$temp_app"; then
    echo "${C_RED}❌ 应用完整性校验失败，中止安装${C_RESET}"
    rm -rf "$temp_app"
    exit 1
  fi
  echo "${C_GREEN}   ✓ 完整性校验通过${C_RESET}"
  
  # 步骤3: 原子替换
  local backup_path="${DEFAULT_APP_PATH}.backup-$$"
  if [ -d "$DEFAULT_APP_PATH" ]; then
    echo "   备份旧版本..."
    if ! mv "$DEFAULT_APP_PATH" "$backup_path"; then
      echo "${C_RED}❌ 无法创建备份，中止安装${C_RESET}"
      rm -rf "$temp_app"
      exit 1
    fi
  fi
  
  echo "   安装新版本..."
  if ! mv "$temp_app" "$DEFAULT_APP_PATH"; then
    echo "${C_RED}❌ 安装失败，恢复旧版本...${C_RESET}"
    if [ -d "$backup_path" ]; then
      mv "$backup_path" "$DEFAULT_APP_PATH"
      echo "${C_YELLOW}⚠️  已恢复旧版本${C_RESET}"
    fi
    rm -rf "$temp_app" 2>/dev/null || true
    exit 1
  fi
  
  # 步骤4: 移除隔离标志
  echo "${C_GREEN}🔐 移除隔离标志(可能需要管理员密码)...${C_RESET}"
  sudo xattr -rd com.apple.quarantine "$DEFAULT_APP_PATH" >/dev/null 2>&1 || {
    echo "${C_YELLOW}⚠️  移除隔离失败，首次打开可能需手动允许${C_RESET}"
  }
  
  # 步骤5: 清理备份
  if [ -d "$backup_path" ]; then
    echo "   清理备份..."
    rm -rf "$backup_path"
  fi

  local final_ver="$(read_installed_version "$DEFAULT_APP_PATH")"
  echo ""
  echo "${C_GREEN}✅ 安装完成: v${final_ver}${C_RESET}"
  echo "${C_GREEN}🚀 启动命令: open \"$DEFAULT_APP_PATH\"${C_RESET}"
}

# =============================================================================
# 主逻辑
# =============================================================================

mkdir -p "$TMP_DIR"

# ---------- 1) 获取最新版本信息 ----------
echo "${C_CYAN}🔎 检查 GitHub 最新版本...${C_RESET}"
JSON="$(curl -fsSL --max-time "$CURL_TIMEOUT" --connect-timeout 10 "$API_LATEST" 2>&1)" || {
  echo "${C_RED}❌ 网络请求失败(超时${CURL_TIMEOUT}s)，请检查网络或稍后重试${C_RESET}"
  rm -rf "$TMP_DIR"
  exit 1
}

LATEST_TAG="$(parse_json_field "$JSON" "tag_name")"
if [ -z "$LATEST_TAG" ]; then
  echo "${C_RED}❌ 无法解析 tag_name，API响应异常${C_RESET}"
  echo "响应前500字符:"
  echo "$JSON" | head -c 500
  rm -rf "$TMP_DIR"
  exit 1
fi

LATEST_VER="${LATEST_TAG#v}"
echo "📦 GitHub最新版本: ${C_GREEN}${LATEST_TAG}${C_RESET}"

# ---------- 2) 获取本地已安装版本 ----------
INSTALLED_APP_PATH="$(find_installed_app)"
INSTALLED_VER=""

if [ -n "$INSTALLED_APP_PATH" ]; then
  INSTALLED_VER="$(read_installed_version "$INSTALLED_APP_PATH")"
  if [ -n "$INSTALLED_VER" ]; then
    echo "💻 本地安装版本: ${C_YELLOW}v${INSTALLED_VER}${C_RESET}  (${INSTALLED_APP_PATH})"
  else
    echo "${C_YELLOW}💻 本地应用存在但版本号不可读取: ${INSTALLED_APP_PATH}${C_RESET}"
  fi
else
  echo "💻 本地安装版本: ${C_YELLOW}(未检测到)${C_RESET}"
fi

# ---------- 3) 版本比较与决策 ----------
if [ -n "$INSTALLED_VER" ] && ! ver_gt "$LATEST_VER" "$INSTALLED_VER"; then
  echo ""
  echo "${C_GREEN}✅ 已是最新版本，无需更新${C_RESET}"
  rm -rf "$TMP_DIR"
  trap - EXIT  # 取消错误清理
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

echo "${C_YELLOW}⚠️  即将${action_text}: v${INSTALLED_VER:-无} → v${LATEST_VER}${C_RESET}"
printf "确认${action_text}? (y/N): "
read ANS
case "$ANS" in
  y|Y|yes|YES) ;;
  *) 
    echo "${C_RED}🚫 用户取消${C_RESET}"
    rm -rf "$TMP_DIR"
    trap - EXIT
    exit 0
    ;;
esac

# 检查磁盘空间
check_disk_space

# ---------- 4) 选择下载资源(根据架构适配) ----------
ARCH="$(uname -m)"
echo "🖥️  系统架构: ${ARCH}"

if [ "$ARCH" = "arm64" ]; then
  # Apple Silicon优先级: universal > aarch64
  URL="$(pick_download_url "$JSON" "Antigravity\.Tools_universal\.app\.tar\.gz$")"
  [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity\.Tools_${LATEST_VER}_universal\.dmg$")"
  [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity\.Tools_aarch64\.app\.tar\.gz$")"
  [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity\.Tools_${LATEST_VER}_aarch64\.dmg$")"
else
  # Intel Mac优先级: universal > x64
  URL="$(pick_download_url "$JSON" "Antigravity\.Tools_universal\.app\.tar\.gz$")"
  [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity\.Tools_${LATEST_VER}_universal\.dmg$")"
  [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity\.Tools_x64\.app\.tar\.gz$")"
  [ -z "$URL" ] && URL="$(pick_download_url "$JSON" "Antigravity\.Tools_${LATEST_VER}_x64\.dmg$")"
fi

if [ -z "$URL" ]; then
  echo "${C_RED}❌ 未找到适配当前架构的下载资源${C_RESET}"
  echo "可用资源列表:"
  echo "$JSON" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)".*/\1/'
  rm -rf "$TMP_DIR"
  exit 1
fi

FILE_NAME="$(basename "$URL")"
FILE_PATH="${TMP_DIR}/${FILE_NAME}"

# ---------- 5) 下载文件(带进度条) ----------
echo ""
echo "${C_CYAN}⬇️  下载中: ${FILE_NAME}${C_RESET}"
echo "   URL: $URL"

curl -fL --max-time 600 --connect-timeout 10 --retry 3 --retry-delay 2 \
  --progress-bar "$URL" -o "$FILE_PATH" || {
  echo "${C_RED}❌ 下载失败，请检查网络连接${C_RESET}"
  rm -rf "$TMP_DIR"
  exit 1
}

TYPE="$(file "$FILE_PATH")"
echo "🔎 文件类型: $TYPE"

EXTRACT_DIR="${TMP_DIR}/extracted"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

# ---------- 6) 提取与安装 ----------
# DMG文件判断：file命令可能返回"zlib compressed data"，需结合扩展名判断
if echo "$TYPE" | grep -q "Apple Disk Image" || echo "$FILE_NAME" | grep -iEq '\.dmg$'; then
  # DMG格式
  echo "${C_CYAN}💿 挂载 DMG 镜像...${C_RESET}"
  # 提取挂载点（支持含空格路径）：从最后一行包含/Volumes的输出中提取完整路径
  MOUNT_POINT="$(hdiutil attach -nobrowse "$FILE_PATH" | grep '/Volumes/' | tail -1 | sed -E 's#^.*(\/Volumes\/.*)$#\1#')"
  [ -z "$MOUNT_POINT" ] && {
    echo "${C_RED}❌ DMG 挂载失败${C_RESET}"
    rm -rf "$TMP_DIR"
    exit 1
  }

  install_from_dir "$MOUNT_POINT"

  echo "⏏️  卸载镜像..."
  hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true

else
  # 压缩包格式(tar.gz/zip)
  echo "${C_CYAN}📦 解压安装包...${C_RESET}"
  
  if tar -xzf "$FILE_PATH" -C "$EXTRACT_DIR" >/dev/null 2>&1; then
    :  # tar.gz成功
  elif ditto -x -k "$FILE_PATH" "$EXTRACT_DIR" >/dev/null 2>&1; then
    :  # zip成功
  else
    echo "${C_RED}❌ 解压失败(不支持的格式)${C_RESET}"
    rm -rf "$TMP_DIR"
    exit 1
  fi

  install_from_dir "$EXTRACT_DIR"
fi

# ---------- 7) 清理与完成 ----------
rm -rf "$TMP_DIR"
trap - EXIT  # 取消错误清理

echo ""
echo "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo "${C_GREEN}🎉 ${action_text}成功! 现在可以启动应用${C_RESET}"
echo "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"