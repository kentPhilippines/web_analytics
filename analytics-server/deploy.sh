#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 定义项目信息
REPO_URL="https://github.com/kentPhilippines/web_analytics.git"
INSTALL_DIR="/opt/web_analytics"
SERVER_DIR="$INSTALL_DIR/analytics-server"  # 服务器代码目录
PUBLIC_DIR="$SERVER_DIR/public"
STATIC_DIR="$PUBLIC_DIR/static"
DOMAIN=""
PORT=3000

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 修改域名输入函数
get_domain() {
    DOMAIN="analytics.nginx-system.com"
    read -p "确认使用域名 $DOMAIN ? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        print_error "部署已取消"
        exit 1
    fi
    print_info "使用域名: $DOMAIN"
}

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
    # 设置目录权限
    sudo chown -R $(whoami):$(whoami) "$INSTALL_DIR"
}

# 克隆代码
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
    
    # 如果目录已存在
    if [ -d "$INSTALL_DIR" ]; then
        print_info "目录 $INSTALL_DIR 已存在"
        
        # 检查是否是git仓库
        if [ -d "$INSTALL_DIR/.git" ]; then
            print_info "更新已存在的代码..."
            cd "$INSTALL_DIR"
            
            # 保存本地修改
            git stash
            
            # 拉取最新代码
            if git pull origin main; then
                print_info "代码更新成功"
                return 0
            else
                print_error "代码更新失败"
                
                # 如果更新失败，尝试强制重新克隆
                print_info "尝试重新克隆..."
                cd ..
                BACKUP_DIR="${INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                sudo mv "$INSTALL_DIR" "$BACKUP_DIR"
            fi
        else
            # 如果不是git仓库，备份并重新克隆
            BACKUP_DIR="${INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
            print_info "备份现有目录到 $BACKUP_DIR"
            sudo mv "$INSTALL_DIR" "$BACKUP_DIR"
        fi
    fi
    
    
    # 克隆代码
    print_info "从 $REPO_URL 克隆代码..."
    if ! git clone "$REPO_URL" "$INSTALL_DIR"; then
        print_error "代码克隆失败"
        
        # 如果有备份，恢复备份
        if [ -d "$BACKUP_DIR" ]; then
            print_info "恢复备份..."
            sudo rm -rf "$INSTALL_DIR"
            sudo mv "$BACKUP_DIR" "$INSTALL_DIR"
            print_info "备份已恢复"
            return 0
        fi
        
        exit 1
    fi
    
    print_info "代码克隆成功"
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
    
    # 进入服务器目录
    cd "$SERVER_DIR" || exit 1
    
    if [ ! -f "package.json" ]; then
        print_error "在 $SERVER_DIR 中未找到 package.json"
        exit 1
    fi
    
    npm install
    
    if [ $? -ne 0 ]; then
        print_error "依赖安装失败"
        exit 1
    fi
}

# 配置环境
setup_environment() {
    print_info "配置环境..."
    
    # 创建必要的目录
    mkdir -p "$SERVER_DIR/logs"
    mkdir -p "$PUBLIC_DIR"
    mkdir -p "$STATIC_DIR"
    
    # 设置环境变量
    export PORT=${PORT:-3000}
    export NODE_ENV=${NODE_ENV:-production}

    # 创建 404 页面
    cat > "$PUBLIC_DIR/404.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>404 - 页面未找到</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        h1 { color: #333; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>404 - 页面未找到</h1>
    <p>抱歉，您请求的页面不存在。</p>
    <p><a href="/">返回首页</a> | <a href="/usage">查看使用说明</a></p>
</body>
</html>
EOF
}

# 配置统计脚本
setup_analytics_scripts() {
    print_info "配置统计脚本..."
    
    # 创建静态资源目录
    mkdir -p "$STATIC_DIR"
    
    # 复制统计脚本
    cp "$INSTALL_DIR/analytics.js" "$STATIC_DIR/" || {
        print_error "复制 analytics.js 失败"
        exit 1
    }

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
    fi

    # 申请证书
    print_info "申请 SSL 证书..."
    if ! sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" --redirect; then
        print_error "SSL 证书申请失败"
        exit 1
    fi

    print_info "SSL 证书配置成功"
}

# 配置 Nginx
setup_nginx() {
    print_info "配置 Nginx..."
    
    # 创建 Nginx 配置文件
    sudo cat > /etc/nginx/conf.d/analytics.conf << EOF
# CORS 预设配置
map \$request_method \$cors_method {
    OPTIONS 11;
    GET 1;
    POST 1;
    default 0;
}

server {
    listen 80;
    server_name ${DOMAIN};

    # SSL 配置会由 certbot 自动加载

    # CORS 预检请求处理
    if (\$cors_method = 11) {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
        add_header 'Access-Control-Max-Age' 1728000;
        add_header 'Content-Type' 'text/plain charset=UTF-8';
        add_header 'Content-Length' 0;
        return 204;
    }

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

        # CORS 头部
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
    }

    # API 路径特别配置
    location /api/ {
        proxy_pass http://localhost:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # CORS 头部
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
    }

    # 静态文件缓存配置
    location /static/ {
        alias ${STATIC_DIR}/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        
        # CORS 头部
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
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

# 生成用说明
generate_usage_doc() {
    print_info "生成使用说明..."
    
    cat > "$PUBLIC_DIR/usage.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>统计脚本使用说明</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
        pre { background: #f5f5f5; padding: 15px; border-radius: 5px; overflow-x: auto; }
        .nav { margin-bottom: 20px; }
        .nav a { color: #007bff; text-decoration: none; margin-right: 15px; }
        .nav a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="nav">
        <a href="/">返回统计面板</a>
    </div>
    <h1>统计脚本使用说明</h1>
    <h2>安装方法</h2>
    <p>在需要统计的页面添加下代码：</p>
    <pre>
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

# 启动服务
start_service() {
    print_info "启动服务..."
    
    # 检查是否已经运行
    if pm2 list | grep -q "analytics-server"; then
        print_info "停止旧的服务实例..."
        pm2 delete analytics-server
    fi
    
    # 进入服务器目录
    cd "$SERVER_DIR" || exit 1
    
    if [ ! -f "server.js" ]; then
        print_error "在 $SERVER_DIR 中未找到 server.js"
        exit 1
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

# 检查服务状态
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

# 主函数
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
    cd "$SERVER_DIR" || exit 1
    
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
    
    print_info "部署���成!"
    print_info "请根据 usage.html 中的说明配置统计脚本"
    print_info "SSL 证书将自动续期"
    print_info "项目安装目录: $INSTALL_DIR"
}

# 执行主函数
main