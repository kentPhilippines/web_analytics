#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 定义项目信息
REPO_URL="https://github.com/kentPhilippines/web_analytics.git"
INSTALL_DIR="/opt/web_analytics"
SCRIPT_DIR="$INSTALL_DIR/analytics-server"
PUBLIC_DIR="$SCRIPT_DIR/public"
STATIC_DIR="$PUBLIC_DIR/static"
DOMAIN=""
PORT=3000

# 检查是否已安装 host 命令
check_host_command() {
    if ! command -v host &> /dev/null; then
        print_info "安装 host 命令..."
        if command -v apt &> /dev/null; then
            sudo apt update
            sudo apt install -y bind9-host
        elif command -v yum &> /dev/null; then
            sudo yum install -y bind-utils
        else
            print_error "无法安装 host 命令，请手动安装"
            exit 1
        fi
    fi
}

# 创建必要的目录
create_directories() {
    print_info "创建必要的目录..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo mkdir -p "$PUBLIC_DIR"
    sudo mkdir -p "$STATIC_DIR"
    sudo mkdir -p "$SCRIPT_DIR/logs"
    
    # 设置目录权限
    sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR"
}

# 修改 clone_repository 函数
clone_repository() {
    print_info "克隆项目代码..."
    
    # 检查 git 是否安装
    if ! command -v git &> /dev/null; then
        print_info "安装 git..."
        if command -v apt &> /dev/null; then
            sudo apt update
            sudo apt install -y git
        elif command -v yum &> /dev/null; then
            sudo yum install -y git
        else
            print_error "无法安装 git，请手动安装"
            exit 1
        fi
    fi
    
    # 如果目录已存在，先备份
    if [ -d "$INSTALL_DIR" ]; then
        BACKUP_DIR="${INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
        print_info "备份现有代码到 $BACKUP_DIR"
        sudo mv "$INSTALL_DIR" "$BACKUP_DIR"
    fi
    
    # 创建目录结构
    create_directories
    
    # 克隆代码
    print_info "从 $REPO_URL 克隆代码..."
    if ! git clone "$REPO_URL" "$INSTALL_DIR"; then
        print_error "代码克隆失败"
        exit 1
    fi
    
    print_info "代码克隆成功"
}

# 修改主函数
main() {
    print_info "开始部署统计服务..."
    
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 权限运行此脚本"
        print_info "使用: curl -sSL https://raw.githubusercontent.com/kentPhilippines/web_analytics/main/analytics-server/deploy.sh | sudo bash"
        exit 1
    fi
    
    # 安装基本工具
    check_host_command
    
    # 获取域名
    get_domain
    
    # 克隆代码
    clone_repository
    
    # 进入项目目录
    cd "$SCRIPT_DIR" || exit 1
    
    # 执行部署步骤
    check_requirements
    install_certbot
    install_dependencies
    setup_environment
    setup_analytics_scripts
    setup_nginx
    setup_ssl
    generate_usage_doc
    start_service
    check_service
    
    print_info "部署完成!"
    print_info "请根据 usage.html 中的说明配置统计脚本"
    print_info "SSL 证书将自动续期"
    print_info "项目安装目录: $INSTALL_DIR"
}

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 添加域名输入函数
get_domain() {
    while true; do
        read -p "请输入您的域名 (例如: analytics.yourdomain.com): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            # 验证域名格式
            if [[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                print_error "请输入有效的域名"
            fi
        else
            print_error "域名不能为空"
        fi
    done
}

# 检查必要的命令是否存在
check_requirements() {
    print_info "检查系统要求..."
    
    # 检查 Nginx
    if ! command -v nginx &> /dev/null; then
        print_info "安装 Nginx..."
        if command -v apt &> /dev/null; then
            sudo apt update
            sudo apt install -y nginx
        elif command -v yum &> /dev/null; then
            sudo yum install -y nginx
        else
            print_error "无法安装 Nginx，请手动安装"
            exit 1
        fi
    fi

    # 检查 Node.js
    if ! command -v node &> /dev/null; then
        print_error "未找到 Node.js，正在安装..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm install 14
        nvm use 14
    fi

    # 检查 npm
    if ! command -v npm &> /dev/null; then
        print_error "未找到 npm"
        exit 1
    fi

    # 检查 pm2
    if ! command -v pm2 &> /dev/null; then
        print_info "安装 pm2..."
        npm install -g pm2
    fi
}

# 安装依赖
install_dependencies() {
    print_info "安装项目依赖..."
    npm install
    
    if [ $? -ne 0 ]; then
        print_error "依赖安装失败"
        exit 1
    fi
}

# 配置统计脚本
setup_analytics_scripts() {
    print_info "配置统计脚本..."
    
    # 创建静态资源目录
    mkdir -p "$STATIC_DIR"
    
    # 复制统计脚本到静态目录
    cp "$SCRIPT_DIR/analytics.js" "$STATIC_DIR/"
    
    # 生成统计脚本配置
    cat > "$STATIC_DIR/analytics-config.js" << EOF
window.analyticsConfig = {
    apiEndpoint: '/api/analytics/sync',
    retryTimes: 3
};
EOF

    print_info "统计脚本已安装到: $STATIC_DIR"
}

# 安装 certbot
install_certbot() {
    print_info "安装 certbot..."
    
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y certbot python3-certbot-nginx
    elif command -v yum &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y certbot python3-certbot-nginx
    else
        print_error "无法安装 certbot，请手动安装"
        exit 1
    fi
}

# 配置 SSL 证书
setup_ssl() {
    print_info "配置 SSL 证书..."
    
    # 检查域名解析
    print_info "检查域名解析..."
    if ! host "$DOMAIN" &> /dev/null; then
        print_error "域名 $DOMAIN 解析失败"
        print_error "请确保域名已正确解析到此服务器"
        exit 1
    }

    # 申请证书
    print_info "申请 SSL 证书..."
    if ! sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" --redirect; then
        print_error "SSL 证书申请失败"
        exit 1
    fi

    print_info "SSL 证书配置成功"
}

# 修改 Nginx 配置函数
setup_nginx() {
    print_info "配置 Nginx..."
    
    # 创建 Nginx 配置文件
    sudo cat > /etc/nginx/conf.d/analytics.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # SSL 配置会由 certbot 自动添加

    location / {
        proxy_pass http://localhost:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # 静态文件缓存配置
    location /static/ {
        alias ${STATIC_DIR}/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    # 禁止访问 .git 和其他敏感目录
    location ~ /\. {
        deny all;
    }
}
EOF

    # 测试 Nginx 配置
    sudo nginx -t
    if [ $? -ne 0 ]; then
        print_error "Nginx 配置测试失败"
        exit 1
    fi

    # 重启 Nginx
    sudo systemctl restart nginx
    if [ $? -ne 0 ]; then
        print_error "Nginx 重启失败"
        exit 1
    fi
}

# 修改生成使用说明的函数
generate_usage_doc() {
    print_info "生成使用说明..."
    
    cat > "$PUBLIC_DIR/usage.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>统计脚本使用说明</title>
    <meta charset="UTF-8">
</head>
<body>
    <h1>统计脚本使用说明</h1>
    <h2>安装方法</h2>
    <p>在需要统计的页面添加以下代码：</p>
    <pre>
&lt;script src="https://${DOMAIN}/static/analytics-config.js">&lt;/script>
&lt;script src="https://${DOMAIN}/static/analytics.js">&lt;/script>
    </pre>
    
    <h2>API 使用</h2>
    <pre>
// 手动记录访问
Analytics.trackPage('/custom-page');

// 获取统计数据
const todayStats = Analytics.getTodayStats();
const pageStats = Analytics.getPageStats('/some-page');
const locationStats = Analytics.getLocationStats();
    </pre>
</body>
</html>
EOF
}

# 配置环境
setup_environment() {
    print_info "配置环境..."
    
    # 创建必要的目录
    mkdir -p logs
    
    # 设置环境变量
    export PORT=${PORT:-3000}
    export NODE_ENV=${NODE_ENV:-production}
}

# 启动服务
start_service() {
    print_info "启动服务..."
    
    # 检查是否已经运行
    if pm2 list | grep -q "analytics-server"; then
        print_info "停止旧的服务实例..."
        pm2 delete analytics-server
    fi
    
    # 使用 PM2 启动服务
    pm2 start server.js --name analytics-server \
        --log ./logs/app.log \
        --time \
        --exp-backoff-restart-delay=100 \
        --max-memory-restart 200M
    
    if [ $? -ne 0 ]; then
        print_error "服务启动失败"
        exit 1
    fi
    
    # 保存 PM2 配置
    pm2 save
    
    # 设置开机自启
    pm2 startup
}

# 修改检查服务状态的函数
check_service() {
    print_info "检查服务状态..."
    
    sleep 3
    
    if pm2 list | grep -q "analytics-server.*online"; then
        print_info "服务已成功启动"
        print_info "访问 https://${DOMAIN} 查看统计数据"
        print_info "访问 https://${DOMAIN}/usage.html 查看使用说明"
    else
        print_error "服务可能未正常运行，请检查日志"
        pm2 logs analytics-server --lines 20
    fi
}

# 执行主函数
main