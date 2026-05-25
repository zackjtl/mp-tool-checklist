-- MP Tool Checklist：共用 Supabase 實例專用 schema
-- 用途：Zeabur 自架 Supabase 與其他專案共用同一 Postgres 時，所有本 App 物件放在 mp_checklist。
--
-- 部署前（Zeabur Supabase 環境變數）：
--   PGRST_DB_SCHEMAS=public,mp_checklist   （在既有值後追加 ,mp_checklist）
--
-- 前端需改用：supabase.schema('mp_checklist').from('checklists') ...
--
-- 官方 Supabase 資料匯入：見 supabase/scripts/migrate-data-to-zeabur.ps1

create schema if not exists mp_checklist;

-- ---------------------------------------------------------------------------
-- 1. 資料表
-- ---------------------------------------------------------------------------

create table if not exists mp_checklist.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  nickname text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table mp_checklist.profiles is '本 App 使用者公開資料；與其他專案的 public.profiles 隔離';

create table if not exists mp_checklist.checklists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null,
  is_public boolean not null default false,
  collaboration_enabled boolean not null default false,
  form_columns jsonb not null default '[
    {"id":"tool_version","label":"工具/項目名稱"},
    {"id":"branch","label":"Branch"}
  ]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint checklists_user_id_fkey_profiles
    foreign key (user_id) references mp_checklist.profiles (id) on delete cascade
);

comment on column mp_checklist.checklists.form_columns is '表頭：[{id,label,fieldType?}]；fieldType 可為 text|textarea|date|url|checkbox';
comment on column mp_checklist.checklists.collaboration_enabled is 'true 時協作者可編輯 mp_tool_checklist 列';

create index if not exists idx_checklists_user_id on mp_checklist.checklists (user_id);
create index if not exists idx_checklists_is_public on mp_checklist.checklists (is_public) where is_public = true;

create table if not exists mp_checklist.mp_tool_checklist (
  id bigint generated always as identity primary key,
  checklist_id uuid not null references mp_checklist.checklists (id) on delete cascade,
  tool_version text not null default '',
  branch text not null default '',
  status text not null default '未完成',
  checked boolean not null default false,
  cells jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column mp_checklist.mp_tool_checklist.cells is '各欄儲存格：{ 欄位id: 字串 }';

create index if not exists idx_mp_tool_checklist_checklist_id on mp_checklist.mp_tool_checklist (checklist_id);

create table if not exists mp_checklist.checklist_collaborators (
  id uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references mp_checklist.checklists (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  invited_email text not null,
  created_at timestamptz not null default now(),
  unique (checklist_id, user_id)
);

create index if not exists idx_checklist_collaborators_checklist_id on mp_checklist.checklist_collaborators (checklist_id);
create index if not exists idx_checklist_collaborators_user_id on mp_checklist.checklist_collaborators (user_id);

comment on table mp_checklist.checklist_collaborators is '進度表協作者；invited_email 為邀請時輸入的 email（小寫）';

-- ---------------------------------------------------------------------------
-- 2. 新使用者 → profiles（僅寫入 mp_checklist.profiles，不動其他專案表）
-- ---------------------------------------------------------------------------

create or replace function mp_checklist.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = mp_checklist, public
as $$
begin
  insert into mp_checklist.profiles (id, email, nickname)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', null)
  )
  on conflict (id) do update
    set email = excluded.email,
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_mp_checklist on auth.users;
create trigger on_auth_user_created_mp_checklist
  after insert on auth.users
  for each row execute function mp_checklist.handle_new_user();

-- ---------------------------------------------------------------------------
-- 3. RLS 輔助函式（SECURITY DEFINER，避免 policy 遞迴）
-- ---------------------------------------------------------------------------

create or replace function mp_checklist.checklist_owned_by_user(p_checklist_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = mp_checklist, public
stable
as $$
  select exists (
    select 1 from mp_checklist.checklists c
    where c.id = p_checklist_id
      and c.user_id is not distinct from p_user_id
  );
$$;

comment on function mp_checklist.checklist_owned_by_user(uuid, uuid) is 'RLS 輔助：是否為進度表擁有者';

create or replace function mp_checklist.collaborator_may_edit_mp_rows(p_checklist_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = mp_checklist, public
stable
as $$
  select exists (
    select 1
    from mp_checklist.checklists c
    inner join mp_checklist.checklist_collaborators cc on cc.checklist_id = c.id
    where c.id = p_checklist_id
      and c.collaboration_enabled is true
      and cc.user_id is not distinct from p_user_id
  );
$$;

comment on function mp_checklist.collaborator_may_edit_mp_rows(uuid, uuid) is 'RLS 輔助：協作者且已開啟共同編輯';

create or replace function mp_checklist.add_checklist_collaborator_by_email(p_checklist_id uuid, p_email text)
returns json
language plpgsql
security definer
set search_path = mp_checklist, public
as $$
declare
  v_owner uuid;
  v_uid uuid;
  v_norm text;
begin
  if (select auth.uid()) is null then
    return json_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  v_norm := lower(trim(p_email));
  if v_norm = '' or position('@' in v_norm) < 2 then
    return json_build_object('ok', false, 'error', 'invalid_email');
  end if;

  select user_id into v_owner from mp_checklist.checklists where id = p_checklist_id;
  if v_owner is null then
    return json_build_object('ok', false, 'error', 'checklist_not_found');
  end if;
  if v_owner <> (select auth.uid()) then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;

  select id into v_uid from auth.users where lower(trim(email)) = v_norm limit 1;
  if v_uid is null then
    return json_build_object('ok', false, 'error', 'user_not_found');
  end if;
  if v_uid = v_owner then
    return json_build_object('ok', false, 'error', 'cannot_invite_self');
  end if;

  insert into mp_checklist.checklist_collaborators (checklist_id, user_id, invited_email)
  values (p_checklist_id, v_uid, v_norm)
  on conflict (checklist_id, user_id) do update set invited_email = excluded.invited_email;

  return json_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

alter table mp_checklist.profiles enable row level security;
alter table mp_checklist.checklists enable row level security;
alter table mp_checklist.mp_tool_checklist enable row level security;
alter table mp_checklist.checklist_collaborators enable row level security;

-- profiles
drop policy if exists "profiles_select_all" on mp_checklist.profiles;
create policy "profiles_select_all" on mp_checklist.profiles
  for select using (true);

drop policy if exists "profiles_update_self" on mp_checklist.profiles;
create policy "profiles_update_self" on mp_checklist.profiles
  for update using (id = (select auth.uid()));

drop policy if exists "profiles_insert_self" on mp_checklist.profiles;
create policy "profiles_insert_self" on mp_checklist.profiles
  for insert with check (id = (select auth.uid()));

-- checklists：擁有者
drop policy if exists "checklists_owner_select" on mp_checklist.checklists;
create policy "checklists_owner_select" on mp_checklist.checklists
  for select using (user_id = (select auth.uid()));

drop policy if exists "checklists_owner_insert" on mp_checklist.checklists;
create policy "checklists_owner_insert" on mp_checklist.checklists
  for insert with check (user_id = (select auth.uid()));

drop policy if exists "checklists_owner_update" on mp_checklist.checklists;
create policy "checklists_owner_update" on mp_checklist.checklists
  for update using (user_id = (select auth.uid()));

drop policy if exists "checklists_owner_delete" on mp_checklist.checklists;
create policy "checklists_owner_delete" on mp_checklist.checklists
  for delete using (user_id = (select auth.uid()));

-- checklists：公開（含未登入訪客）
drop policy if exists "checklists_select_public" on mp_checklist.checklists;
create policy "checklists_select_public" on mp_checklist.checklists
  for select using (is_public = true);

-- checklists：協作者
drop policy if exists "checklists_select_collaborator" on mp_checklist.checklists;
create policy "checklists_select_collaborator" on mp_checklist.checklists
  for select using (
    exists (
      select 1 from mp_checklist.checklist_collaborators cc
      where cc.checklist_id = checklists.id and cc.user_id = (select auth.uid())
    )
  );

-- mp_tool_checklist：擁有者
drop policy if exists "mp_tool_checklist_owner_all" on mp_checklist.mp_tool_checklist;
create policy "mp_tool_checklist_owner_all" on mp_checklist.mp_tool_checklist
  for all using (
    mp_checklist.checklist_owned_by_user(checklist_id, (select auth.uid()))
  )
  with check (
    mp_checklist.checklist_owned_by_user(checklist_id, (select auth.uid()))
  );

-- mp_tool_checklist：公開 checklist 的列（訪客可讀）
drop policy if exists "mp_tool_checklist_select_public" on mp_checklist.mp_tool_checklist;
create policy "mp_tool_checklist_select_public" on mp_checklist.mp_tool_checklist
  for select using (
    exists (
      select 1 from mp_checklist.checklists c
      where c.id = mp_tool_checklist.checklist_id and c.is_public = true
    )
  );

-- mp_tool_checklist：協作者
drop policy if exists "mp_tool_checklist_collab_select" on mp_checklist.mp_tool_checklist;
create policy "mp_tool_checklist_collab_select" on mp_checklist.mp_tool_checklist
  for select using (
    exists (
      select 1 from mp_checklist.checklist_collaborators cc
      where cc.checklist_id = mp_tool_checklist.checklist_id
        and cc.user_id = (select auth.uid())
    )
  );

drop policy if exists "mp_tool_checklist_collab_insert" on mp_checklist.mp_tool_checklist;
create policy "mp_tool_checklist_collab_insert" on mp_checklist.mp_tool_checklist
  for insert with check (
    mp_checklist.collaborator_may_edit_mp_rows(checklist_id, (select auth.uid()))
  );

drop policy if exists "mp_tool_checklist_collab_update" on mp_checklist.mp_tool_checklist;
create policy "mp_tool_checklist_collab_update" on mp_checklist.mp_tool_checklist
  for update using (
    mp_checklist.collaborator_may_edit_mp_rows(checklist_id, (select auth.uid()))
  );

drop policy if exists "mp_tool_checklist_collab_delete" on mp_checklist.mp_tool_checklist;
create policy "mp_tool_checklist_collab_delete" on mp_checklist.mp_tool_checklist
  for delete using (
    mp_checklist.collaborator_may_edit_mp_rows(checklist_id, (select auth.uid()))
  );

-- checklist_collaborators
drop policy if exists "checklist_collaborators_owner_select" on mp_checklist.checklist_collaborators;
create policy "checklist_collaborators_owner_select" on mp_checklist.checklist_collaborators
  for select using (
    mp_checklist.checklist_owned_by_user(checklist_id, (select auth.uid()))
  );

drop policy if exists "checklist_collaborators_owner_insert" on mp_checklist.checklist_collaborators;
create policy "checklist_collaborators_owner_insert" on mp_checklist.checklist_collaborators
  for insert with check (
    mp_checklist.checklist_owned_by_user(checklist_id, (select auth.uid()))
  );

drop policy if exists "checklist_collaborators_owner_delete" on mp_checklist.checklist_collaborators;
create policy "checklist_collaborators_owner_delete" on mp_checklist.checklist_collaborators
  for delete using (
    mp_checklist.checklist_owned_by_user(checklist_id, (select auth.uid()))
  );

drop policy if exists "checklist_collaborators_member_select_self" on mp_checklist.checklist_collaborators;
create policy "checklist_collaborators_member_select_self" on mp_checklist.checklist_collaborators
  for select using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 5. 權限（PostgREST / API role）
-- ---------------------------------------------------------------------------

grant usage on schema mp_checklist to anon, authenticated, service_role;

grant select, insert, update, delete on all tables in schema mp_checklist to anon, authenticated;
grant all on all tables in schema mp_checklist to service_role;

grant usage, select on all sequences in schema mp_checklist to anon, authenticated, service_role;

revoke all on function mp_checklist.checklist_owned_by_user(uuid, uuid) from public;
revoke all on function mp_checklist.collaborator_may_edit_mp_rows(uuid, uuid) from public;
revoke all on function mp_checklist.add_checklist_collaborator_by_email(uuid, text) from public;

grant execute on function mp_checklist.checklist_owned_by_user(uuid, uuid) to anon, authenticated;
grant execute on function mp_checklist.collaborator_may_edit_mp_rows(uuid, uuid) to anon, authenticated;
grant execute on function mp_checklist.add_checklist_collaborator_by_email(uuid, text) to authenticated;

alter default privileges in schema mp_checklist
  grant select, insert, update, delete on tables to anon, authenticated;
alter default privileges in schema mp_checklist
  grant all on tables to service_role;
alter default privileges in schema mp_checklist
  grant usage, select on sequences to anon, authenticated, service_role;
