#!/usr/bin/env bash
# AnyTLS 一键管理脚本 v0.1.8 (Auto-Deployment Edition)
# 适配：每次运行一键命令均会自动同步到本地 /usr/local/bin/anytls

# ================= 配置区 =================
# 请确保此处的 URL 指向你自己的 GitHub 脚本地址
SCRIPT_RAW_URL="https://raw.githubusercontent.com/connerhsu/Anytls-/main/anytlsgotest1.sh"
# =========================================

CONFIG_DIR="/etc/AnyTLS"
ANYTLS_SERVER="${CONFIG_DIR}/server"
ANYTLS_SERVICE_NAME="anytls.service"
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}"
ANYTLS_CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SHORTCUT_FILE="/usr/local/bin/anytls"

# 颜色
Green="\033[32m"
Red="\033[31m"
Font="\033[0m"
OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"

print_ok() { echo -e "${OK} $1"; }
print_error() { echo -e "${ERROR} $1"; }

# --- 核心修复：处理管道运行并强制同步本地 ---
create_shortcut() {
    # 逻辑：不论从哪运行，都强制从远程下载最新版覆盖到本地 bin 目录
    # 这样可以避开 cp: cannot stat '/proc/.../fd/pipe' 的报错
    curl -fsSL "$SCRIPT_RAW_URL" -o "$SHORTCUT_FILE"
    if [[ $? -eq 0 ]]; then
        chmod +x "$SHORTCUT_FILE"
        # 清理旧路径并刷新缓存
        [[ -f "/usr/bin/anytls" ]] && rm -f "/usr/bin/anytls"
        hash -r
        print_ok "快捷指令 anytls 已成功同步到本地并刷新缓存"
    else
        print_error "同步本地快捷指令失败，请检查网络"
    fi
}

ensure_root() {
    [[ $EUID -ne 0 ]] && echo "Error: 必须使用 root 运行!" && exit 1
}

# --- 简单的菜单演示（请根据需要在此补充完整的 AnyTLS 安装逻辑） ---
main_menu() {
    clear
    echo "------------------------------------------"
    echo "  AnyTLS 一键脚本 - 快捷命令修复版"
    echo "  快捷命令: anytls"
    echo "------------------------------------------"
    echo " 1. 安装/更新 AnyTLS"
    echo " 2. 查看配置"
    echo " 0. 退出"
    echo "------------------------------------------"
    read -p "请输入数字: " choice
    case "${choice}" in
        1) echo "执行安装逻辑...";;
        2) echo "执行查看逻辑...";;
        0) exit 0;;
        *) echo "无效输入";;
    esac
}

# 程序入口
ensure_root
create_shortcut
main_menu
