const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const compression = require('compression');
const path = require('path');
const fs = require('fs');

const app = express();
const port = process.env.PORT || 3000;

// 数据库文件路径
const DB_PATH = path.join(__dirname, 'analytics.db');

// 检查并初始化数据库
function initializeDatabase() {
    const dbExists = fs.existsSync(DB_PATH);
    
    // 创建数据库连接
    const db = new sqlite3.Database(DB_PATH);
    
    if (!dbExists) {
        console.log('Creating new database...');
        // 创建数据表
        db.serialize(() => {
            db.run(`CREATE TABLE IF NOT EXISTS visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT,
                pageUrl TEXT,
                ip TEXT,
                country TEXT,
                region TEXT,
                city TEXT,
                userAgent TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )`, (err) => {
                if (err) {
                    console.error('Error creating database table:', err);
                } else {
                    console.log('Database table created successfully');
                }
            });
        });
    } else {
        console.log('Using existing database');
    }
    
    return db;
}

// 初始化数据库
const db = initializeDatabase();

// 中间件
app.use(compression()); // 启用 gzip 压缩
app.use(express.json());

// 配置 CORS
const corsOptions = {
    origin: '*',
    methods: '*',                // 允许所有方法
    allowedHeaders: [           // 明确列出所有需要的请求头
        'Content-Type',
        'Authorization',
        'X-Requested-With',
        'Referer',
        'sec-ch-ua',
        'sec-ch-ua-mobile',
        'sec-ch-ua-platform',
        'User-Agent',
        'Cache-Control',
        'Accept',
        'Origin',
        'Accept-Language',
        'Accept-Encoding'
    ],
    exposedHeaders: '*',         // 允许所有响应头
    credentials: true,
    maxAge: 86400,
    preflightContinue: true
};

app.use(cors(corsOptions));

// 全局中间件添加 CORS 头
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Methods', '*');
    res.header('Access-Control-Allow-Headers', corsOptions.allowedHeaders.join(', '));
    res.header('Access-Control-Expose-Headers', '*');
    res.header('Access-Control-Allow-Credentials', 'true');
    
    // 处理 OPTIONS 请求
    if (req.method === 'OPTIONS') {
        res.sendStatus(200);
    } else {
        next();
    }
});

// 特别为 /api/analytics/sync 配置 CORS
app.options('/api/analytics/sync', cors(corsOptions)); // 启用 CORS 预检请求
app.post('/api/analytics/sync', cors(corsOptions), async (req, res) => {
    try {
        const visit = req.body;
        
        const stmt = db.prepare(`
            INSERT INTO visits (timestamp, pageUrl, ip, country, region, city, userAgent)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        `);

        stmt.run(
            visit.timestamp,
            visit.pageUrl,
            visit.ip,
            visit.country,
            visit.region,
            visit.city,
            visit.userAgent
        );

        stmt.finalize();
        
        res.status(200).json({ success: true });
    } catch (error) {
        console.error('Error saving visit:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// 获取统计数据
app.get('/api/analytics/stats', async (req, res) => {
    try {
        db.all(`
            SELECT 
                date(timestamp) as date,
                COUNT(*) as visits,
                COUNT(DISTINCT ip) as unique_visitors,
                pageUrl
            FROM visits 
            GROUP BY date(timestamp), pageUrl
            ORDER BY date DESC
            LIMIT 30
        `, (err, rows) => {
            if (err) throw err;
            res.json(rows);
        });
    } catch (error) {
        console.error('Error getting stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// 获取地域统计
app.get('/api/analytics/location-stats', async (req, res) => {
    try {
        db.all(`
            SELECT 
                country,
                city,
                COUNT(*) as visits
            FROM visits 
            GROUP BY country, city
            ORDER BY visits DESC
            LIMIT 100
        `, (err, rows) => {
            if (err) throw err;
            res.json(rows);
        });
    } catch (error) {
        console.error('Error getting location stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// 添加概览统计接口
app.get('/api/analytics/overview', async (req, res) => {
    try {
        db.all(`
            SELECT 
                COUNT(*) as total_visits,
                COUNT(DISTINCT ip) as unique_visitors,
                COUNT(DISTINCT pageUrl) as total_pages,
                COUNT(DISTINCT country) as total_countries
            FROM visits
            WHERE timestamp >= date('now', '-30 days')
        `, (err, rows) => {
            if (err) throw err;
            res.json(rows[0]);
        });
    } catch (error) {
        console.error('Error getting overview stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// 添加按小时统计的接口
app.get('/api/analytics/hourly', async (req, res) => {
    try {
        db.all(`
            SELECT 
                strftime('%H', timestamp) as hour,
                COUNT(*) as visits
            FROM visits
            WHERE date(timestamp) = date('now')
            GROUP BY hour
            ORDER BY hour
        `, (err, rows) => {
            if (err) throw err;
            res.json(rows);
        });
    } catch (error) {
        console.error('Error getting hourly stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// 自动清理旧数据（保留30天）
setInterval(() => {
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    
    db.run(`DELETE FROM visits WHERE timestamp < ?`, 
        thirtyDaysAgo.toISOString(),
        function(err) {
            if (err) {
                console.error('Error cleaning old data:', err);
            } else if (this.changes > 0) {
                console.log(`Cleaned ${this.changes} old records`);
            }
        }
    );
}, 24 * 60 * 60 * 1000); // 每24小时执行一次

// 优雅关闭
process.on('SIGINT', () => {
    db.close((err) => {
        if (err) {
            console.error('Error closing database:', err);
        } else {
            console.log('Database connection closed');
        }
        process.exit(0);
    });
});

// 在现有的中间件配置后添加
app.use(express.static(path.join(__dirname, 'public')));

// 添加根路由，重定向到统计面板
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// 添加使用说明路由
app.get('/usage', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'usage.html'));
});

// 添加 404 处理
app.use((req, res) => {
    res.status(404).sendFile(path.join(__dirname, 'public', '404.html'));
});

// 启动服务器
app.listen(port, () => {
    console.log(`Analytics server running on port ${port}`);
}); 