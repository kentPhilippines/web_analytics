#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 定义项目信息
INSTALL_DIR="/opt/web_analytics"
NGINX_CONF_DIR="/etc/nginx/conf.d"
STATIC_DIR="$INSTALL_DIR/static"
DOMAIN=""

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 获取域名
get_domain() {
    DOMAIN="analytics.nginx-system.com"
    read -p "确认使用域名 $DOMAIN ? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        print_error "部署已取消"
        exit 1
    fi
    print_info "使用域名: $DOMAIN"
}

# 安装依赖
install_dependencies() {
    print_info "安装系统依赖..."
    
    # 检查包管理器
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y wget curl certbot python3-certbot-nginx
    elif command -v yum &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y wget curl certbot python3-certbot-nginx
    else
        print_error "不支持的系统"
        exit 1
    fi
}

# 安装 OpenResty
install_openresty() {
    print_info "安装 OpenResty..."
    
    if command -v apt &> /dev/null; then
        # Ubuntu/Debian
        wget -qO - https://openresty.org/package/pubkey.gpg | sudo apt-key add -
        echo "deb http://openresty.org/package/ubuntu $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/openresty.list
        sudo apt update
        sudo apt install -y openresty
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        wget https://openresty.org/package/centos/openresty.repo -O /etc/yum.repos.d/openresty.repo
        sudo yum install -y openresty
    else
        print_error "不支持的系统"
        exit 1
    fi

    # 创建必要的目录
    sudo mkdir -p /var/log/nginx/analytics
    sudo chown -R openresty:openresty /var/log/nginx/analytics
}

# 创建目录结构
create_directories() {
    print_info "创建目录结构..."
    
    sudo mkdir -p "$INSTALL_DIR"/{nginx,static,public}
    sudo chown -R openresty:openresty "$INSTALL_DIR"
}

# 配置 Nginx
setup_nginx() {
    print_info "配置 OpenResty..."
    
    # 复制 Lua 模块
    sudo cp analytics.lua "$INSTALL_DIR/nginx/"
    
    # 生成 Nginx 配置
    sudo cat > "$NGINX_CONF_DIR/analytics.conf" << EOF
# 加载 Lua 模块
lua_package_path "$INSTALL_DIR/nginx/?.lua;;";
lua_shared_dict analytics_cache 10m;

# 定时任务配置
init_worker_by_lua_block {
    local analytics = require "analytics"
    
    -- 每天凌晨2点清理旧数据
    ngx.timer.every(86400, function()
        if tonumber(ngx.localtime():sub(12,13)) == 2 then
            analytics.cleanup()
        end
    end)
}

server {
    listen 80;
    server_name ${DOMAIN};

    # SSL 配置会由 certbot 自动加载

    # 静态文件
    location /static/ {
        alias ${STATIC_DIR}/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        add_header Access-Control-Allow-Origin "*" always;
    }

    # API 路由
    location = /api/analytics/sync {
        default_type application/json;
        content_by_lua_block {
            local analytics = require "analytics"
            analytics.record_visit()
        }
    }

    location = /api/analytics/stats {
        default_type application/json;
        content_by_lua_block {
            local analytics = require "analytics"
            analytics.get_stats()
        }
    }

    # 前端页面
    location / {
        root $INSTALL_DIR/public;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    # 测试配置
    sudo openresty -t
}

# 配置 SSL
setup_ssl() {
    print_info "配置 SSL..."
    
    sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" --redirect
}

# 生成前端文件
setup_frontend() {
    print_info "生成前端文件..."
    
    # 复制统计脚本
    sudo cp analytics.js "$STATIC_DIR/"
    
    # 生成前端页面
    sudo cat > "$INSTALL_DIR/public/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>访问统计</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .card { background: #f5f5f5; padding: 20px; border-radius: 8px; }
        h2 { margin-top: 0; }
    </style>
</head>
<body>
    <h1>访问统计</h1>
    <div class="stats">
        <div class="card">
            <h2>总览</h2>
            <div id="overview"></div>
        </div>
        <div class="card">
            <h2>页面访问</h2>
            <div id="pages"></div>
        </div>
        <div class="card">
            <h2>地域分布</h2>
            <div id="locations"></div>
        </div>
    </div>
    <script>
        async function loadStats() {
            try {
                const response = await fetch('/api/analytics/stats');
                const stats = await response.json();
                
                document.getElementById('overview').innerHTML = \`
                    <p>总访问量: \${stats.total_visits}</p>
                    <p>独立访客: \${stats.unique_visitors}</p>
                \`;
                
                document.getElementById('pages').innerHTML = Object.entries(stats.pages)
                    .map(([page, count]) => \`<p>\${page}: \${count}次</p>\`)
                    .join('');
                
                document.getElementById('locations').innerHTML = Object.entries(stats.locations)
                    .map(([loc, count]) => \`<p>\${loc}: \${count}次</p>\`)
                    .join('');
            } catch (error) {
                console.error('加载统计数据失败:', error);
            }
        }

        // 每分钟刷新一次
        loadStats();
        setInterval(loadStats, 60000);
    </script>
</body>
</html>
EOF

    # 生成使用说明
    sudo cat > "$INSTALL_DIR/public/usage.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>统计脚本使用说明</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
        pre { background: #f5f5f5; padding: 15px; border-radius: 5px; overflow-x: auto; }
    </style>
</head>
<body>
    <h1>统计脚本使用说明</h1>
    <h2>安装方法</h2>
    <p>在需要统计的页面添加下面的代码：</p>
    <pre>&lt;script src="https://${DOMAIN}/static/analytics.js">&lt;/script></pre>
    
    <h2>API 使用</h2>
    <pre>
// 手动记录访问
Analytics.trackPage('/custom-page');
    </pre>
</body>
</html>
EOF
}

# 主函数
main() {
    print_info "开始部署统计服务..."
    
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    get_domain
    install_dependencies
    install_openresty
    create_directories
    setup_nginx
    setup_ssl
    setup_frontend
    
    # 重启 OpenResty
    sudo systemctl restart openresty
    
    print_info "部署完成!"
    print_info "访问 https://${DOMAIN} 查看统计数据"
    print_info "访问 https://${DOMAIN}/usage.html 查看使用说明"
}

# 执行主函数
main