-- 同一進度表可有多筆資料列，空白的「工具/項目名稱」不應在全域唯一。
-- 否則第二筆 insert 會觸發 duplicate key (mp_tool_checklist_tool_version_key)。

alter table public.mp_tool_checklist
  drop constraint if exists mp_tool_checklist_tool_version_key;
