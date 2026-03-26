const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// 自動提供靜態檔案 (包含 index.html 等)
app.use(express.static(path.join(__dirname)));

// 捕捉所有路由並導向 index.html (以利前端處理路徑與網址參數)
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
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
