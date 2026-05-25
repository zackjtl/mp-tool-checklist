# 移植至 Zeabur 共用 Supabase

本文件說明如何將 **MP Tool Checklist** 從官方 Supabase（`public` schema）移植到 **Zeabur 自架 Supabase**，且與其他專案共用同一 Postgres 實例。

## 架構概覽

Zeabur 上若有多個 App 共用一個 Supabase，本專案使用獨立 schema **`mp_checklist`**，避免與其他專案的 `public.profiles`、`public.checklists` 等表名衝突。

```
Zeabur Supabase（共用）
├── auth.users                 ← 所有 App 共用登入帳號
├── public                     ← 其他專案
└── mp_checklist               ← 本 App 專用
    ├── profiles
    ├── checklists
    ├── mp_tool_checklist
    └── checklist_collaborators
```

| 項目 | 官方 Supabase | Zeabur 共用 Supabase |
|------|---------------|----------------------|
| Schema | `public` | `mp_checklist` |
| 登入 | 獨立 `auth.users` | 與其他 App 共用 `auth.users` |
| 使用者資料 | `public.profiles` | `mp_checklist.profiles` |
| API 存取 | `.from('checklists')` | `.schema('mp_checklist').from('checklists')` |

---

## 前置需求

- [ ] 已安裝 [PostgreSQL client](https://www.postgresql.org/download/)（含 `pg_dump`、`psql`）
- [ ] 可連線至 **官方 Supabase** Database（Direct connection，port `5432`）
- [ ] 可連線至 **Zeabur Supabase** Postgres
- [ ] 已取得 Zeabur Supabase 的 **API URL** 與 **anon key**
- [ ] 本 repo 已包含：
  - `supabase/migrations/000_mp_checklist_schema.sql` — 建立 schema、表、RLS、函式
  - `supabase/scripts/migrate-data-to-zeabur.ps1` — 資料匯出／匯入腳本

> **注意：** 請使用 Database 的 **Direct connection** URI 做 migration，不要用 Session pooler（port `6543`）。

---

## 步驟一：在 Zeabur 設定 PostgREST Schema

在 Zeabur Supabase 服務的環境變數中，將 `mp_checklist` **追加**到 PostgREST 暴露的 schema 列表。

```env
# 若原本只有 public
PGRST_DB_SCHEMAS=public,mp_checklist

# 若已有其他專案 schema，在末尾追加即可
PGRST_DB_SCHEMAS=public,other_app,mp_checklist
```

修改後**重啟 Supabase 相關服務**，否則 API 無法存取 `mp_checklist` 下的表。

---

## 步驟二：建立資料庫結構

在 Zeabur Postgres 執行 baseline migration：

```powershell
psql "postgresql://postgres:[密碼]@[zeabur-host]:5432/postgres" `
  -v ON_ERROR_STOP=1 `
  -f supabase/migrations/000_mp_checklist_schema.sql
```

或在 Supabase Studio / SQL Editor 貼上該檔內容執行。

此步驟會建立：

- `mp_checklist` schema 及四張資料表
- RLS policies（含協作者、公開列表）
- 輔助函式（`checklist_owned_by_user`、`collaborator_may_edit_mp_rows`、`add_checklist_collaborator_by_email`）
- 新使用者 trigger（寫入 `mp_checklist.profiles`，不影響其他專案）

---

## 步驟三：匯入業務資料

### 3.1 使用自動化腳本（建議）

在專案根目錄執行：

```powershell
$env:SOURCE_DB = "postgresql://postgres.[官方ref]:[密碼]@db.[官方ref].supabase.co:5432/postgres"
$env:TARGET_DB = "postgresql://postgres:[密碼]@[zeabur-host]:5432/postgres"

.\supabase\scripts\migrate-data-to-zeabur.ps1
```

腳本會：

1. 從官方 `public` 匯出四張表的資料
2. 將 `public.` 替換為 `mp_checklist.`
3. 匯入 Zeabur（暫停 FK/trigger 檢查）
4. 修正 `mp_tool_checklist.id` 序列
5. 補齊缺少的 `profiles` 列

匯出的暫存檔會放在 `tmp/migration/`（已在 `.gitignore` 建議忽略此目錄）。

### 3.2 手動匯出／匯入

若無法使用 PowerShell 腳本，可手動操作：

```powershell
# 匯出（官方）
pg_dump $env:SOURCE_DB `
  --data-only --column-inserts --no-owner --no-privileges `
  --table=public.profiles `
  --table=public.checklists `
  --table=public.mp_tool_checklist `
  --table=public.checklist_collaborators `
  -f tmp/migration/data.sql

# 編輯 data.sql：將 public. 全部改為 mp_checklist.

# 匯入（Zeabur）
psql $env:TARGET_DB -v ON_ERROR_STOP=1 -c "SET session_replication_role = replica;"
psql $env:TARGET_DB -v ON_ERROR_STOP=1 -f tmp/migration/data.sql
psql $env:TARGET_DB -v ON_ERROR_STOP=1 -c "SET session_replication_role = DEFAULT;"
```

### 3.3 匯入順序

資料表有外鍵依賴，必須依序匯入：

1. `profiles`
2. `checklists`
3. `mp_tool_checklist`
4. `checklist_collaborators`

腳本已依此順序處理。

---

## 步驟四：處理 Auth 使用者

`auth.users` 在共用 Supabase 上是**全域**的，與業務 schema 分開。

### 情境 A：Zeabur 上尚無本 App 使用者

需從官方 Supabase 一併匯出 auth 資料（需 service role 或直接 DB 權限）：

```powershell
pg_dump $env:SOURCE_DB `
  --data-only --column-inserts --no-owner --no-privileges `
  --table=auth.users `
  --table=auth.identities `
  -f tmp/migration/auth_users.sql

psql $env:TARGET_DB -v ON_ERROR_STOP=1 -c "SET session_replication_role = replica;"
psql $env:TARGET_DB -v ON_ERROR_STOP=1 -f tmp/migration/auth_users.sql
psql $env:TARGET_DB -v ON_ERROR_STOP=1 -c "SET session_replication_role = DEFAULT;"
```

匯入後確認 `mp_checklist.profiles` 有對應列；若缺少，執行 baseline 中的 backfill SQL 或重新跑資料腳本第 4 步。

### 情境 B：使用者已在 Zeabur 註冊過（例如用過其他 App）

- **不必**匯出 `auth.users`
- 只需匯入 `mp_checklist.*` 業務資料
- 前提：官方與 Zeabur 的 `user_id`（UUID）一致；若 Zeabur 是全新 auth，UUID 不同，checklist 的 `user_id` 會對不上，需另行對應或請使用者重新建立

### JWT Secret 不同

Zeabur 自架的 JWT secret 與官方不同時，**舊 session 全部失效**，使用者需重新登入（可接受則無需額外處理）。

---

## 步驟五：設定 Auth（Google OAuth / Magic Link）

在 Zeabur Supabase / GoTrue 設定：

| 項目 | 說明 |
|------|------|
| `SITE_URL` | 前端正式網址，例如 `https://your-app.zeabur.app` |
| `ADDITIONAL_REDIRECT_URLS` | 本機、staging、正式網址（逗號分隔） |
| Google OAuth | 在 [Google Cloud Console](https://console.cloud.google.com/) 新增 Authorized redirect URI |
| SMTP | Magic Link 需設定寄信（Resend、SendGrid 等） |

Google OAuth callback 通常為：

```
https://<zeabur-supabase-host>/auth/v1/callback
```

並在 Google Console 的 **Authorized redirect URIs** 加入上述 URL。

前端 Magic Link / OAuth 的 `redirectTo` 必須在 GoTrue 允許的 redirect URL 列表內。

---

## 步驟六：更新前端

目前 `index.html` 連線官方 Supabase 且使用預設 `public` schema。切換至 Zeabur 後需修改兩處。

### 6.1 更新連線資訊

```javascript
const SUPABASE_URL = 'https://<zeabur-supabase-host>';
const SUPABASE_KEY = '<zeabur-anon-key>';
```

建議改為從部署環境變數注入，避免 key 寫死在 repo。

### 6.2 指定 schema

所有資料庫操作改為透過 `mp_checklist` schema：

```javascript
const DB_SCHEMA = 'mp_checklist';
const db = () => supabase.schema(DB_SCHEMA);

// 查詢
await db().from('checklists').select('...');

// RPC
await db().rpc('add_checklist_collaborator_by_email', { ... });
```

需修改的位置包含所有 `.from('profiles'|'checklists'|'mp_tool_checklist'|'checklist_collaborators')` 及 `.rpc('add_checklist_collaborator_by_email', ...)`。

---

## 步驟七：驗收測試

切換正式流量前，請逐項確認：

- [ ] **未登入**：首頁可載入公開進度表
- [ ] **Google 登入**：成功建立 session，可登出
- [ ] **Email Magic Link**：收信、點連結可登入
- [ ] **建立 / 編輯 / 刪除** checklist 與列資料
- [ ] **自訂欄位**（`form_columns`、`cells`）正常
- [ ] **公開 / 私人**切換正常
- [ ] **協作者邀請**（`add_checklist_collaborator_by_email`）正常
- [ ] **協作者 RLS**：僅在 `collaboration_enabled = true` 時可編輯
- [ ] **舊資料**：既有 checklist 仍顯示正確 owner 與內容
- [ ] **不影響其他 App**：其他專案 `public` schema 資料未被改動

---

## 共用實例注意事項

1. **表名隔離**  
   本 App 所有表在 `mp_checklist`，不要改回 `public`，以免與其他專案衝突。

2. **`auth.users` 共用**  
   同一 Supabase 註冊的使用者，在其他 App 也會存在；各 App 靠各自 schema 的 RLS 保護資料。

3. **Trigger 可共存**  
   `on_auth_user_created_mp_checklist` 只寫入 `mp_checklist.profiles`，不會修改其他專案的 `public.profiles`。

4. **備份策略**  
   備份時只 dump 本 App schema：

   ```powershell
   pg_dump $env:TARGET_DB --schema=mp_checklist -f backup_mp_checklist.sql
   ```

5. **還原時**  
   還原 `mp_checklist` schema 不應影響 `public` 或其他 schema。

6. **連線數**  
   多 App 共用同一 Postgres 時，注意 connection limit；前端使用 anon key 即可，避免濫用 service role。

---

## 相關檔案

| 檔案 | 用途 |
|------|------|
| `supabase/migrations/000_mp_checklist_schema.sql` | Zeabur 完整 baseline（schema + RLS + 函式） |
| `supabase/migrations/001_form_columns.sql` | 官方 `public` 增量（已併入 000） |
| `supabase/migrations/002_drop_mp_tool_checklist_tool_version_unique.sql` | 官方 `public` 增量（000 未含該 unique） |
| `supabase/migrations/003_checklist_collaborators.sql` | 官方 `public` 增量（已併入 000） |
| `supabase/migrations/004_fix_checklists_rls_recursion.sql` | 官方 `public` 增量（已併入 000） |
| `supabase/scripts/migrate-data-to-zeabur.ps1` | 資料匯出／轉換／匯入腳本 |

> `001`～`004` 為當初在**官方 Supabase `public` schema** 上逐步套用的 migration。移植至 Zeabur 共用實例時，只需執行 **`000_mp_checklist_schema.sql`**，不必再跑 001～004。

---

## 常見問題

### Q：執行 000 後 API 回 404 / schema not found？

確認 `PGRST_DB_SCHEMAS` 已包含 `mp_checklist`，且 Supabase 服務已重啟。

### Q：匯入後 checklist 看得到但 owner 顯示異常？

檢查 `mp_checklist.profiles` 是否有對應 `user_id` 列；執行資料腳本第 4 步 backfill，或手動 insert。

### Q：協作者邀請回 `user_not_found`？

被邀請者必須已在**同一 Zeabur Supabase** 的 `auth.users` 註冊過（可在本 App 或其他 App 登入一次）。

### Q：出現 `infinite recursion detected in policy for relation "checklists"`？

表示 RLS 未使用 000 中的 SECURITY DEFINER 函式版本；請重新執行 000 中函式與 policy 段落，或確認未混用舊版 003 的 policy。

### Q：能否與其他專案共用 `public.profiles`？

不建議。欄位結構、RLS、trigger 容易衝突；維持 `mp_checklist.profiles` 隔離較安全。

---

## 建議執行順序（摘要）

1. 設定 `PGRST_DB_SCHEMAS` 並重啟 Zeabur Supabase
2. 執行 `000_mp_checklist_schema.sql`
3. 視需要匯出／匯入 `auth.users`（情境 A）
4. 執行 `migrate-data-to-zeabur.ps1` 匯入業務資料
5. 設定 Google OAuth、SMTP、Redirect URLs
6. 更新前端 URL、KEY、`schema('mp_checklist')`
7. 完成驗收測試後切換正式流量
