const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

const rootDir = path.join(__dirname);

/** 避免 HTML 被 CDN／瀏覽器用 ETag/304 沿用舊內容（曾出現 Last-Modified 異常仍回 304） */
function setNoStoreHtmlHeaders(res) {
  res.setHeader('Cache-Control', 'private, no-store, no-cache, must-revalidate, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  res.setHeader('CDN-Cache-Control', 'no-store');
  res.setHeader('Vercel-CDN-Cache-Control', 'no-store');
}

// 自動提供靜態檔案；HTML 關閉 etag/lastModified，避免 304 仍顯示舊版
app.use(
  express.static(rootDir, {
    etag: false,
    lastModified: false,
    maxAge: 0,
    setHeaders(res, filePath) {
      if (filePath.endsWith('.html')) {
        setNoStoreHtmlHeaders(res);
      } else if (filePath.endsWith('.svg')) {
        res.setHeader('Cache-Control', 'public, max-age=3600, must-revalidate');
      }
    },
  })
);

// 捕捉所有路由並導向 index.html (以利前端處理路徑與網址參數)
app.get('*', (req, res) => {
  setNoStoreHtmlHeaders(res);
  res.sendFile(path.join(rootDir, 'index.html'), { etag: false, lastModified: false });
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
