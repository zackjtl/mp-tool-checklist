# Zeabur Migration 接手文件

> 本文件供**另一台可安裝軟體的電腦**接手完成移植。完整技術說明見 [`MIGRATION_ZEABUR.md`](./MIGRATION_ZEABUR.md)。

---

## 背景

**MP Tool Checklist** 目前部署在 Vercel，後端使用**官方 Supabase**（`public` schema）。目標是將資料庫移植到 **Zeabur 自架 Supabase**，使用獨立 schema `mp_checklist`，與其他 App 共用同一 Postgres。

原電腦因**公司政策無法安裝軟體**（缺少 `pg_dump` / `psql`），migration 尚未執行。本 repo 已備妥 SQL baseline 與 PowerShell 腳本，請在可安裝 PostgreSQL client 的機器上繼續。

---

## 目前進度（截至交接時）

| 項目 | 狀態 | 備註 |
|------|------|------|
| Repo 內 migration SQL（`000_mp_checklist_schema.sql`） | ✅ 已備妥 | 尚未確認是否在 Zeabur 執行 |
| 資料匯出／匯入腳本（`migrate-data-to-zeabur.ps1`） | ✅ 已備妥並修正 | 修正 PowerShell 5.1 語法問題 |
| 官方 Supabase 專案 ref | ✅ 可從 code 取得 | 見下方 |
| 官方 DB 密碼 | ⚠️ 需自行取得 | **不在 repo 內** |
| Zeabur `PGRST_DB_SCHEMAS` 設定 | ❓ 待確認 | 步驟一 |
| Zeabur 執行 `000_mp_checklist_schema.sql` | ❓ 待確認 | 步驟二 |
| 業務資料匯入（步驟三） | ✅ 已完成 | |
| Auth 使用者匯入（步驟四） | ❌ 未完成 | Zeabur auth.users 全空，需執行 `migrate-auth-to-zeabur.ps1` |
| 前端切換至 Zeabur | 🟡 程式已備妥 | 設 env + `SUPABASE_DB_SCHEMA=mp_checklist` 後部署；預設仍連官方 `public` |

---

## 已知資訊（可從 code 取得，非機密）

### 官方 Supabase 專案

前端 `index.html` 硬編碼連線至官方 Supabase：

| 項目 | 值 |
|------|-----|
| Project ref | `iotjuquhpqctgsnetmnc` |
| API URL | `https://iotjuquhpqctgsnetmnc.supabase.co` |
| Schema | `public`（目前前端未指定 schema，預設 public） |

### Vercel 部署

- 前端為 Express 靜態伺服器（`server.js`），**Vercel 上無 Supabase 環境變數**
- Supabase URL / anon key 寫死在 `index.html`，非 env 注入

### 官方 DB 連線字串格式（步驟三 SOURCE_DB）

```powershell
$env:SOURCE_DB = "postgresql://postgres.iotjuquhpqctgsnetmnc:[DATABASE_PASSWORD]@db.iotjuquhpqctgsnetmnc.supabase.co:5432/postgres"
```

- 使用 **Direct connection**（port `5432`）
- `[DATABASE_PASSWORD]` 需從 Supabase Dashboard 取得（見下方「取得密碼」）
- 密碼含 `@` 等特殊字元時須 URL 編碼（`@` → `%40`）

---

## 新電腦前置需求

1. **Git**：clone 本 repo 並 `git pull` 最新版
2. **PostgreSQL client**：必須能執行 `pg_dump`、`psql`

   ```powershell
   pg_dump --version
   psql --version
   ```

   下載：https://www.postgresql.org/download/windows/

3. **網路**：
   - 可連線官方 Supabase DB（`db.iotjuquhpqctgsnetmnc.supabase.co:5432`）
   - 可連線 Zeabur Postgres 的**外部** host（見下方陷阱）

4. **權限**：
   - 官方 Supabase Dashboard（Owner/Admin，可 Reset database password）
   - Zeabur 後台（Postgres 外部連線字串、Supabase env、API URL / anon key）

---

## 需自行準備的機密（勿 commit）

請在新電腦以**環境變數**或本機記事本保存，**不要寫進 git**：

| 變數 | 說明 | 取得方式 |
|------|------|----------|
| 官方 DB 密碼 | `SOURCE_DB` 用 | Supabase Dashboard → 專案 → **Connect** 按鈕 → Direct connection；密碼忘記則 Reset |
| Zeabur DB 密碼 + host | `TARGET_DB` 用 | Zeabur Postgres 服務 → **External / Public** 連線資訊 |
| Zeabur Supabase URL | 步驟六前端 | Zeabur Supabase 服務 env |
| Zeabur anon key | 步驟六前端 | 同上 |

### 取得官方 DB 密碼（Dashboard 介面可能已改版）

若 Project Settings 側邊欄**沒有 Database** 項目，改找：

1. 專案首頁上方 **Connect** 按鈕 → 選 **Direct connection**
2. 或左側主選單 **Database** → Settings

直接連結（需有權限）：

`https://supabase.com/dashboard/project/iotjuquhpqctgsnetmnc`

### 密碼含 `@` 的處理

```powershell
$pwd = [System.Uri]::EscapeDataString('你的原始密碼')
$env:SOURCE_DB = "postgresql://postgres.iotjuquhpqctgsnetmnc:${pwd}@db.iotjuquhpqctgsnetmnc.supabase.co:5432/postgres"
```

`TARGET_DB` 同理。

---

## 建議執行順序（接手後照做）

詳細說明見 [`MIGRATION_ZEABUR.md`](./MIGRATION_ZEABUR.md)。

### 0. 拉最新 code

```powershell
git clone <repo-url>
cd mp-tool-checklist
git pull
```

### 1. Zeabur：設定 PostgREST schema

```env
PGRST_DB_SCHEMAS=public,mp_checklist
```

（若已有其他 schema，在末尾追加 `,mp_checklist`）→ **重啟 Supabase 服務**

### 2. Zeabur：建立資料庫結構

```powershell
psql "postgresql://postgres:[ZEABUR_PASSWORD]@[ZEABUR_EXTERNAL_HOST]:5432/postgres" `
  -v ON_ERROR_STOP=1 `
  -f supabase/migrations/000_mp_checklist_schema.sql
```

或在 Zeabur Supabase Studio SQL Editor 貼上 `000_mp_checklist_schema.sql` 執行。

### 3. 匯入業務資料（本次中斷點）

```powershell
# 注意：是 $env: 不是 $evn:
$pwdSrc = [System.Uri]::EscapeDataString('官方DB密碼')
$pwdTgt = [System.Uri]::EscapeDataString('Zeabur DB密碼')

$env:SOURCE_DB = "postgresql://postgres.iotjuquhpqctgsnetmnc:${pwdSrc}@db.iotjuquhpqctgsnetmnc.supabase.co:5432/postgres"
$env:TARGET_DB = "postgresql://postgres:${pwdTgt}@[ZEABUR_EXTERNAL_HOST]:5432/postgres"

.\supabase\scripts\migrate-data-to-zeabur.ps1
```

腳本會：

1. 從官方 `public` 匯出四張表
2. 轉成 `mp_checklist` schema
3. 匯入 Zeabur
4. 修正序列、補齊 profiles

暫存檔在 `tmp/migration/`（已加入 `.gitignore`，勿 commit）。

### 4. Auth 使用者（情境 A：Zeabur 全空）

```powershell
$env:SOURCE_DB = "..."   # 同步驟三
$env:TARGET_DB = "..."   # 同步驟三

.\supabase\scripts\migrate-auth-to-zeabur.ps1
```

腳本會：

1. 從官方匯出 `auth.users`、`auth.identities`
2. 使用 `ON CONFLICT DO NOTHING` 安全匯入（可重複執行）
3. 補齊 `mp_checklist.profiles` 缺漏列

> 完成後舊 session JWT 失效，使用者需重新登入。

### 5. Auth 設定（Google OAuth / Magic Link）

見 `MIGRATION_ZEABUR.md` 步驟五。

### 6. 更新前端

程式已改為透過 `/runtime-config.js` 注入（`server.js` 讀環境變數）：

| 環境變數 | 說明 |
|----------|------|
| `SUPABASE_URL` | Zeabur Supabase API URL |
| `SUPABASE_ANON_KEY` | Zeabur anon key |
| `SUPABASE_DB_SCHEMA` | 設為 `mp_checklist`（未設則預設 `public`，仍連官方） |

所有 DB 操作已改為 `db().from(...)` / `db().rpc(...)`（`db()` = `supabase.schema(DB_SCHEMA)`）。

### 7. 驗收

依 `MIGRATION_ZEABUR.md` 步驟七 checklist 逐項測試。

---

## 原電腦已遇到的問題（避免重踩）

| 問題 | 原因 | 解法 |
|------|------|------|
| `找不到 pg_dump` | 未安裝 PostgreSQL client | 新電腦先裝再跑 |
| `$evn:TARGET_DB` 報錯 | 拼字錯誤 | 正確為 `$env:` |
| `migrate-data-to-zeabur.ps1` 語法錯誤 | 舊版 here-string 在 PS 5.1 解析失敗 | 已修正，請用最新 code |
| `postgresql.zeabur.internal` 連不上 | Zeabur **內網** host，本機無法解析 | 改用 **External / Public** host |
| Project Settings 沒有 Database | Dashboard UI 改版 | 用 **Connect** 或左側 **Database** |
| 密碼含 `@` 連線失敗 | URI 分隔符衝突 | URL 編碼 `%40` 或用 `EscapeDataString` |
| 官方 `db.*.supabase.co` 無法解析／連不上 | 僅有 IPv6，本機無 IPv6 路由 | Dashboard → **Connect** → **Session pooler** URI 作為 `SOURCE_DB` |
| `TARGET` 用 Supabase API 網域 | `jerrysupabase.zeabur.app` 是 API，非 Postgres | Zeabur **Postgres** 服務 → **External** 連線字串 |
| `password authentication failed for user "postgres"` | 主機／埠正確，密碼錯 | 用 **Postgres 服務** 的 `POSTGRES_PASSWORD`，不是 anon key／JWT |
| 外部埠 | 公有網路轉送 | 用 **30206** 等外部埠，不是容器內 5432 |
| `pg_dump: no matching tables were found` | `SOURCE_DB` 連到**別的** Supabase 專案 | 使用者須為 `postgres.iotjuquhpqctgsnetmnc`，pooler 主機從**該專案** Connect 複製 |
| `host "postgresql" not known` | `SOURCE_DB` 重複 `postgresql://` | 只保留一個前綴，勿 `postgresql://postgresql://...` |
| `transaction_timeout` unrecognized | pg_dump 18 vs 舊版 Zeabur Postgres | 腳本已自動過濾；更新後重跑 migration |

---

## Repo 相關檔案

| 檔案 | 用途 |
|------|------|
| `supabase/HANDOFF_ZEABUR_MIGRATION.md` | 本文件（接手用） |
| `supabase/MIGRATION_ZEABUR.md` | 完整 migration 指南 |
| `supabase/migrations/000_mp_checklist_schema.sql` | Zeabur baseline（schema + RLS + 函式） |
| `supabase/migrations/001`～`004` | 官方 public 歷史增量（已併入 000，Zeabur 不必再跑） |
| `supabase/scripts/migrate-data-to-zeabur.ps1` | 資料匯出／轉換／匯入 |
| `index.html` | 前端（仍連官方 Supabase，移植後需改） |

---

## 完成後

- [ ] 確認 Zeabur 上資料正確
- [ ] 更新 `index.html` 並部署（Vercel 或其他）
- [ ] 驗收 checklist 全過
- [ ] 考慮是否保留官方 Supabase 作為備份，確認無問題後再停用

---

## 聯絡／決策備忘

- 官方 Supabase 若無 Dashboard 權限，需向當初建立專案的人要 **database password** 或 **Admin 邀請**
- 共用 Zeabur Supabase 時，`auth.users` 為全域；各 App 靠 schema + RLS 隔離
- 切換後舊 JWT session 失效，使用者需重新登入
