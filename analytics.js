// 统计核心类
class SimpleAnalytics {
    constructor() {
        try {
            this.visits = new Map();
            this.loadFromStorage();
            this.cleanOldData();
        } catch (error) {
            console.warn('Analytics initialization failed:', error);
        }
    }

    // 修改后端API配置
    static config = {
        apiEndpoint: 'https://analytics.nginx-system.com/api/analytics/sync', // 后端同步接口
        retryTimes: 3,   // 失败重试次数
    }

    // 同步数据到服务器
    async syncToServer(visitData, retryCount = 0) {
        try {
            // 优先使用 sendBeacon，它是非阻塞的
            if (navigator.sendBeacon) {
                const blob = new Blob([JSON.stringify(visitData)], {
                    type: 'application/json'
                });
                const success = navigator.sendBeacon(SimpleAnalytics.config.apiEndpoint, blob);
                
                if (success) {
                    visitData.synced = true;
                    this.saveToStorage();
                    return;
                }
            }

            // 如果 sendBeacon 不可用或失败，使用 fetch 的非阻塞方式
            fetch(SimpleAnalytics.config.apiEndpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(visitData),
                // 确保请求不阻塞
                keepalive: true,
                // 设置较短的超时时间
                signal: AbortSignal.timeout(2000)
            }).then(() => {
                visitData.synced = true;
                this.saveToStorage();
            }).catch(error => {
                if (retryCount < SimpleAnalytics.config.retryTimes) {
                    setTimeout(() => {
                        this.syncToServer(visitData, retryCount + 1);
                    }, 1000 * Math.pow(2, retryCount));
                }
            });

        } catch (error) {
            console.warn('Sync to server failed:', error);
        }
    }

    // 修改记录访问方法，使其完全非阻塞
    recordVisit(pageUrl) {
        // 使用 requestIdleCallback 在浏览器空闲时执行
        const task = async () => {
            try {
                const geoData = await this.getGeoLocationNonBlocking();
                
                const visitData = {
                    timestamp: new Date().toISOString(),
                    pageUrl,
                    ...geoData,
                    userAgent: navigator.userAgent,
                    synced: false,
                };

                const dateKey = visitData.timestamp.split('T')[0];
                const key = `${dateKey}:${pageUrl}`;
                
                const existingData = this.visits.get(key) || [];
                existingData.push(visitData);
                this.visits.set(key, existingData);
                
                this.saveToStorage();
                this.syncToServer(visitData);
                
            } catch (error) {
                console.warn('Analytics record failed:', error);
                this.recordBasicVisit(pageUrl);
            }
        };

        // 使用 requestIdleCallback 或 setTimeout 作为降级方案
        if (window.requestIdleCallback) {
            requestIdleCallback(() => task(), { timeout: 2000 });
        } else {
            setTimeout(task, 0);
        }
    }

    // 非阻塞的地理位置获取
    async getGeoLocationNonBlocking() {
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 2000);

            const [ipResponse, geoResponse] = await Promise.all([
                fetch('https://api.ipify.org?format=json', {
                    signal: controller.signal
                }),
                fetch('https://ipapi.co/json/', {
                    signal: controller.signal
                })
            ]);

            clearTimeout(timeoutId);

            if (!ipResponse.ok || !geoResponse.ok) {
                throw new Error('Network response was not ok');
            }

            const [ipData, geoData] = await Promise.all([
                ipResponse.json(),
                geoResponse.json()
            ]);

            return {
                ip: ipData.ip,
                country: geoData.country_name || 'unknown',
                region: geoData.region || 'unknown',
                city: geoData.city || 'unknown'
            };
        } catch (error) {
            console.warn('Geo location fetch failed:', error);
            return {
                ip: 'unknown',
                country: 'unknown',
                region: 'unknown',
                city: 'unknown'
            };
        }
    }

    // 修改基本访问记录方法，使其非阻塞
    recordBasicVisit(pageUrl) {
        setTimeout(() => {
            try {
                const visitData = {
                    timestamp: new Date().toISOString(),
                    pageUrl,
                    ip: 'unknown',
                    country: 'unknown',
                    region: 'unknown',
                    city: 'unknown',
                    userAgent: navigator.userAgent,
                    synced: false,
                };

                const dateKey = visitData.timestamp.split('T')[0];
                const key = `${dateKey}:${pageUrl}`;
                
                const existingData = this.visits.get(key) || [];
                existingData.push(visitData);
                this.visits.set(key, existingData);
                
                this.saveToStorage();
                this.syncToServer(visitData);
            } catch (error) {
                console.warn('Analytics basic record failed:', error);
            }
        }, 0);
    }

    loadFromStorage() {
        try {
            const stored = localStorage.getItem('pageVisits');
            if (stored) {
                this.visits = new Map(Object.entries(JSON.parse(stored)));
            }
        } catch (error) {
            console.warn('Analytics storage load failed:', error);
            this.visits = new Map(); // 重置为空Map
        }
    }

    saveToStorage() {
        try {
            const data = Object.fromEntries(this.visits);
            const compressed = JSON.stringify(data);
            localStorage.setItem('pageVisits', compressed);
        } catch (error) {
            console.warn('Analytics storage save failed:', error);
            this.cleanOldData(); // 尝试清理数据
        }
    }

    async getGeoLocation() {
        try {
            const response = await fetch('https://api.ipify.org?format=json');
            const { ip } = await response.json();
            
            const geoResponse = await fetch(`https://ipapi.co/${ip}/json/`);
            const geoData = await geoResponse.json();
            
            return {
                ip,
                country: geoData.country_name || 'unknown',
                region: geoData.region || 'unknown',
                city: geoData.city || 'unknown'
            };
        } catch (error) {
            console.warn('Analytics geo location failed:', error);
            throw error; // 让上层处理
        }
    }

    // 其他查询方法添加错误处理
    getStatsByDate(date) {
        try {
            const stats = [];
            for (const [key, value] of this.visits) {
                if (key.startsWith(date)) {
                    stats.push(...value);
                }
            }
            return stats;
        } catch (error) {
            console.warn('Analytics stats query failed:', error);
            return [];
        }
    }

    getPageStats(pageUrl) {
        try {
            const stats = [];
            for (const [key, value] of this.visits) {
                if (key.includes(pageUrl)) {
                    stats.push(...value);
                }
            }
            return stats;
        } catch (error) {
            console.warn('Analytics page stats query failed:', error);
            return [];
        }
    }

    getLocationStats() {
        try {
            const locationStats = {};
            for (const visits of this.visits.values()) {
                for (const visit of visits) {
                    const location = `${visit.country}-${visit.city}`;
                    locationStats[location] = (locationStats[location] || 0) + 1;
                }
            }
            return locationStats;
        } catch (error) {
            console.warn('Analytics location stats query failed:', error);
            return {};
        }
    }

    cleanOldData() {
        try {
            const DAYS_TO_KEEP = 30;
            const now = new Date();
            const entries = Array.from(this.visits.entries());
            
            entries.forEach(([key, value]) => {
                const dateStr = key.split(':')[0];
                const date = new Date(dateStr);
                const daysDiff = (now - date) / (1000 * 60 * 60 * 24);
                
                if (daysDiff > DAYS_TO_KEEP) {
                    this.visits.delete(key);
                }
            });
            
            setTimeout(() => this.saveToStorage(), 0);
        } catch (error) {
            console.warn('Analytics cleanup failed:', error);
        }
    }
}

// 修改初始化方式，确保不阻塞页面加载
window.addEventListener('load', () => {
    setTimeout(() => {
        try {
            window.pageAnalytics = window.pageAnalytics || new SimpleAnalytics();
            window.pageAnalytics.recordVisit(window.location.pathname);
        } catch (error) {
            console.warn('Analytics initialization failed:', error);
        }
    }, 0);
});

// 安全的初始化函数
async function initAnalytics() {
    if (!window.pageAnalytics) return;
    
    try {
        await window.pageAnalytics.recordVisit(window.location.pathname);
    } catch (error) {
        console.warn('Analytics initialization failed:', error);
    }
}

// 安全的全局API
window.Analytics = {
    trackPage: async (pageUrl) => {
        try {
            if (!window.pageAnalytics) return;
            await window.pageAnalytics.recordVisit(pageUrl || window.location.pathname);
        } catch (error) {
            console.warn('Analytics track failed:', error);
        }
    },

    getTodayStats: () => {
        try {
            if (!window.pageAnalytics) return [];
            const today = new Date().toISOString().split('T')[0];
            return window.pageAnalytics.getStatsByDate(today);
        } catch (error) {
            console.warn('Analytics today stats failed:', error);
            return [];
        }
    },

    getPageStats: (pageUrl) => {
        try {
            if (!window.pageAnalytics) return [];
            return window.pageAnalytics.getPageStats(pageUrl);
        } catch (error) {
            console.warn('Analytics page stats failed:', error);
            return [];
        }
    },

    getLocationStats: () => {
        try {
            if (!window.pageAnalytics) return {};
            return window.pageAnalytics.getLocationStats();
        } catch (error) {
            console.warn('Analytics location stats failed:', error);
            return {};
        }
    }
};

// 安全的初始化监听
try {
    document.addEventListener('DOMContentLoaded', initAnalytics);
} catch (error) {
    console.warn('Analytics listener setup failed:', error);
} 