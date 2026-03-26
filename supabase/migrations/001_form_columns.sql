-- 可自訂表頭：checklists.form_columns、mp_tool_checklist.cells
-- 請在 Supabase SQL Editor 執行，或透過 CLI 套用 migration。

alter table public.checklists
  add column if not exists form_columns jsonb not null default '[
    {"id":"tool_version","label":"工具/項目名稱"},
    {"id":"branch","label":"Branch"}
  ]'::jsonb;

alter table public.mp_tool_checklist
  add column if not exists cells jsonb not null default '{}'::jsonb;

comment on column public.checklists.form_columns is '表頭定義：[{id,label}, ...] 順序即欄位順序';
comment on column public.mp_tool_checklist.cells is '各欄儲存格：{ 欄位id: 字串 }，舊列可仍依賴 tool_version／branch';
