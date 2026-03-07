cat > /usr/local/bin/anytls << 'EOF'
#!/bin/bash
# AnyTLS-Go 极致管理面板 (Connor 定制版)
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; PLAIN='\033[0m'
CONFIG_FILE="/etc/anytls/server.conf"

# 1. 随机混淆生成器 (核心逻辑)
gen_pad() {
    local s=$((8 + RANDOM % 10))
    local r1=$((100 + RANDOM % 100)); local r2=$((500 + RANDOM % 300))
    echo "[\"stop=${s}\",\"0=$((10+RANDOM%30))-$((50+RANDOM%40))\",\"1=${r1}-$((r1+200))\",\"2=${r2}-$((r2+200)),c,700-1000,c,700-1100\",\"3=20-40\",\"4=300-800\",\"5=500-1000\"]"
}

# 2. 保存配置并修复 Systemd (严格匹配你的 help 参数)
save_at() {
    local p=$(gen_pad)
    mkdir -p /etc/anytls
    echo "PORT=\"$1\"; PASS=\"$2\"; PAD='$p'" > $CONFIG_FILE
    
    cat > /etc/systemd/system/anytls.service <<EOF2
[Unit]
Description=AnyTLS-Go Service
After=network.target
[Service]
Type=simple
User=root
# 修复点：仅使用 -l, -p, -padding-scheme，移除不支持的 --sni
ExecStart=/opt/anytls/anytls-server -l 0.0.0.0:$1 -p "$2" -padding-scheme '$p'
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF2

    systemctl daemon-reload && systemctl restart anytls
}

# 3. 菜单面板逻辑
show_menu() {
    clear
    local status="${RED}● 停止${PLAIN}"
    systemctl is-active --quiet anytls && status="${GREEN}● 运行中${PLAIN}"
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "      AnyTLS 极致版 (BBR + 每日 3 点换肤)"
    echo -e " 状态: $status"
    echo -e "----------------------------------------"
    echo -e " 1. ${GREEN}安装/重置 (包含定时刷新 & BBR)${PLAIN}"
    echo -e " 2. 查看当前配置/分享信息"
    echo -e " 3. ${YELLOW}立即手动随机换指纹${PLAIN}"
    echo -e " 9. ${RED}完全卸载${PLAIN}"
    echo -e " 0. 退出"
    read -p " 选择 [0-9]: " n
    
    case "$n" in
        1)
            # 安装 cron 依赖
            apt-get install -y cron || yum install -y crontabs
            systemctl enable --now cron || systemctl enable --now crond
            # 开启 BBR
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            # 配置参数
            read -p "端口 [8443]: " pt; pt=${pt:-8443}
            read -p "密码: " ps; ps=${ps:-$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)}
            save_at "$pt" "$ps"
            # 写入定时任务 (凌晨 3:00)
            (crontab -l 2>/dev/null | grep -v "anytls --refresh"; echo "0 3 * * * /usr/local/bin/anytls --refresh > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}部署完成！已修复参数并添加定时任务。${PLAIN}"
            ;;
        2)
            if [ -f $CONFIG_FILE ]; then
                source $CONFIG_FILE
                echo -e "${GREEN}地址:${PLAIN} $(curl -s4 ip.sb):$PORT"
                echo -e "${GREEN}密码:${PLAIN} $PASS"
                echo -e "${GREEN}指纹:${PLAIN} $PAD"
            else
                echo -e "${RED}未安装！${PLAIN}"
            fi
            read -p "按回车返回..." ;;
        3)
            if [ -f $CONFIG_FILE ]; then
                source $CONFIG_FILE && save_at "$PORT" "$PASS"
                echo -e "${GREEN}指纹已更新并重启！${PLAIN}"
                sleep 2
            fi ;;
        9)
            systemctl stop anytls; systemctl disable anytls; rm -rf /etc/anytls /usr/local/bin/anytls /etc/systemd/system/anytls.service
            crontab -l | grep -v "anytls" | crontab -
            echo "已卸载"; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# 4. 判断是定时触发还是手动运行
if [[ "$1" == "--refresh" ]]; then
    if [ -f $CONFIG_FILE ]; then
        source $CONFIG_FILE && save_at "$PORT" "$PASS"
    fi
else
    show_menu
fi
EOF

# 赋予执行权限并立即运行
chmod +x /usr/local/bin/anytls
anytls
