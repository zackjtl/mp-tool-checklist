const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

const rootDir = path.join(__dirname);

// 自動提供靜態檔案；避免 CDN／瀏覽器長快取 HTML／SVG，否則佈署後仍像舊版
app.use(
  express.static(rootDir, {
    etag: true,
    maxAge: 0,
    setHeaders(res, filePath) {
      const base = path.basename(filePath);
      if (base === 'index.html' || filePath.endsWith('.html')) {
        res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
      } else if (filePath.endsWith('.svg')) {
        res.setHeader('Cache-Control', 'public, max-age=3600, must-revalidate');
      }
    },
  })
);

// 捕捉所有路由並導向 index.html (以利前端處理路徑與網址參數)
app.get('*', (req, res) => {
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
  res.sendFile(path.join(rootDir, 'index.html'));
});

// 當跑在 Vercel 上的時候，它會以外部函式方式引入 app
// 若不是在 Vercel 執行，則正常監聽本機 PORT
if (process.env.NODE_ENV !== 'production' && !process.env.VERCEL) {
  app.listen(PORT, () => {
    console.log(`Server is running at http://localhost:${PORT}`);
  });
}

// 供 Vercel Serverless Function 呼叫
module.exports = app;
