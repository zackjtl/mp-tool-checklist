const express = require('express');
const fs = require('fs');
const path = require('path');

/** 本機開發：讀取 repo 根目錄 .env（不覆寫已存在的 process.env） */
function loadDotEnv() {
  const envPath = path.join(__dirname, '.env');
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 1) continue;
    const key = trimmed.slice(0, eq).trim();
    const val = trimmed.slice(eq + 1).trim();
    if (process.env[key] === undefined) process.env[key] = val;
  }
}
loadDotEnv();

const app = express();
const PORT = process.env.PORT || 3000;

const rootDir = path.join(__dirname);

function setNoStoreHtmlHeaders(res) {
  res.setHeader('Cache-Control', 'private, no-store, no-cache, must-revalidate, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  res.setHeader('CDN-Cache-Control', 'no-store');
  res.setHeader('Vercel-CDN-Cache-Control', 'no-store');
}

/** 前端執行期設定（Zeabur / Vercel 以環境變數注入，勿 commit 機密） */
function runtimeConfigJs() {
  const url =
    process.env.SUPABASE_URL || 'https://iotjuquhpqctgsnetmnc.supabase.co';
  const key = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_KEY || '';
  const dbSchema = process.env.SUPABASE_DB_SCHEMA || 'public';
  const body = `window.__MP_RUNTIME__=${JSON.stringify({
    supabaseUrl: url,
    supabaseAnonKey: key,
    dbSchema,
  })};`;
  return body;
}

app.get('/runtime-config.js', (_req, res) => {
  res.type('application/javascript');
  setNoStoreHtmlHeaders(res);
  res.send(runtimeConfigJs());
});

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
  const server = app.listen(PORT, () => {
    console.log(`Server is running at http://localhost:${PORT}`);
  });
  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
      console.error(
        `Port ${PORT} is already in use. Stop the other process or run: $env:PORT=3001; npm start`
      );
    }
    throw err;
  });
}

// 供 Vercel Serverless Function 呼叫
module.exports = app;
