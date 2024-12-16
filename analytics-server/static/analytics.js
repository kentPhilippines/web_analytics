// 统计核心类
class SimpleAnalytics {
    constructor() {
        this.config = {
            apiEndpoint: 'https://analytics.nginx-system.com/api/analytics/sync',
            retryTimes: 3,
            retryDelay: 1000
        };
    }

    async recordVisit(pageUrl = window.location.pathname) {
        try {
            const visitData = {
                timestamp: new Date().toISOString(),
                pageUrl: pageUrl,
                referrer: document.referrer,
                screenResolution: `${window.screen.width}x${window.screen.height}`,
                language: navigator.language,
                platform: navigator.platform,
                userAgent: navigator.userAgent,
                origin: window.location.origin
            };

            // 优先使用 sendBeacon
            if (navigator.sendBeacon) {
                const blob = new Blob([JSON.stringify(visitData)], {
                    type: 'application/json'
                });
                if (navigator.sendBeacon(this.config.apiEndpoint, blob)) {
                    return;
                }
            }

            // 降级到 fetch
            const response = await fetch(this.config.apiEndpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Requested-With': 'XMLHttpRequest'
                },
                body: JSON.stringify(visitData),
                keepalive: true,
                mode: 'cors',
                credentials: 'omit'
            });

            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
        } catch (error) {
            console.warn('Analytics record failed:', error);
            // 静默失败，不影响主站点功能
        }
    }

    // 监听路由变化（用于 SPA）
    setupRouteListener() {
        // 监听 popstate 事件
        window.addEventListener('popstate', () => {
            this.recordVisit();
        });

        // 监听 pushState 和 replaceState
        const originalPushState = history.pushState;
        const originalReplaceState = history.replaceState;

        history.pushState = (...args) => {
            originalPushState.apply(history, args);
            this.recordVisit();
        };

        history.replaceState = (...args) => {
            originalReplaceState.apply(history, args);
            this.recordVisit();
        };
    }
}

// 初始化
window.addEventListener('load', () => {
    try {
        window.analytics = new SimpleAnalytics();
        window.analytics.recordVisit();
        window.analytics.setupRouteListener();
    } catch (error) {
        console.warn('Analytics initialization failed:', error);
    }
});

// 导出全局 API
window.Analytics = {
    trackPage: (pageUrl) => {
        if (window.analytics) {
            window.analytics.recordVisit(pageUrl);
        }
    }
}; 