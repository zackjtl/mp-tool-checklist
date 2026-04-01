-- 協作者：以 Email 邀請已註冊使用者共同編輯（需搭配下方 RLS）
-- 若專案已在 checklists / mp_tool_checklist 啟用 RLS，請確認新 policy 與既有規則相容（多條 policy 為 OR 合併）。

-- 1. 開關：啟用後，列在 checklist_collaborators 的成員可編輯列資料
alter table public.checklists
  add column if not exists collaboration_enabled boolean not null default false;

comment on column public.checklists.collaboration_enabled is 'true 時，協作者可編輯 mp_tool_checklist 列（擁有者不受影響）';

-- 2. 協作者表
create table if not exists public.checklist_collaborators (
  id uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references public.checklists (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  invited_email text not null,
  created_at timestamptz not null default now(),
  unique (checklist_id, user_id)
);

create index if not exists idx_checklist_collaborators_checklist_id on public.checklist_collaborators (checklist_id);
create index if not exists idx_checklist_collaborators_user_id on public.checklist_collaborators (user_id);

comment on table public.checklist_collaborators is '進度表協作者；invited_email 為邀請時輸入的 email（小寫）';

alter table public.checklist_collaborators enable row level security;

-- 擁有者：讀寫自己表單下的所有協作者列
drop policy if exists "checklist_collaborators_owner_select" on public.checklist_collaborators;
create policy "checklist_collaborators_owner_select" on public.checklist_collaborators
  for select using (
    exists (
      select 1 from public.checklists c
      where c.id = checklist_collaborators.checklist_id and c.user_id = (select auth.uid())
    )
  );

drop policy if exists "checklist_collaborators_owner_insert" on public.checklist_collaborators;
create policy "checklist_collaborators_owner_insert" on public.checklist_collaborators
  for insert with check (
    exists (
      select 1 from public.checklists c
      where c.id = checklist_collaborators.checklist_id and c.user_id = (select auth.uid())
    )
  );

drop policy if exists "checklist_collaborators_owner_delete" on public.checklist_collaborators;
create policy "checklist_collaborators_owner_delete" on public.checklist_collaborators
  for delete using (
    exists (
      select 1 from public.checklists c
      where c.id = checklist_collaborators.checklist_id and c.user_id = (select auth.uid())
    )
  );

-- 成員：可讀取自己在該表的成員列（用於判斷是否為協作者）
drop policy if exists "checklist_collaborators_member_select_self" on public.checklist_collaborators;
create policy "checklist_collaborators_member_select_self" on public.checklist_collaborators
  for select using (user_id = (select auth.uid()));

-- 3. checklists：協作者可讀取被加入的私人表單（檢視）
drop policy if exists "checklists_select_collaborator" on public.checklists;
create policy "checklists_select_collaborator" on public.checklists
  for select using (
    exists (
      select 1 from public.checklist_collaborators cc
      where cc.checklist_id = checklists.id and cc.user_id = (select auth.uid())
    )
  );

-- 4. mp_tool_checklist：協作者在 collaboration_enabled 時可讀寫列
drop policy if exists "mp_tool_checklist_collab_select" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_select" on public.mp_tool_checklist
  for select using (
    exists (
      select 1
      from public.checklists c
      join public.checklist_collaborators cc on cc.checklist_id = c.id
      where c.id = mp_tool_checklist.checklist_id
        and cc.user_id = (select auth.uid())
    )
  );

drop policy if exists "mp_tool_checklist_collab_insert" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_insert" on public.mp_tool_checklist
  for insert with check (
    exists (
      select 1
      from public.checklists c
      join public.checklist_collaborators cc on cc.checklist_id = c.id
      where c.id = mp_tool_checklist.checklist_id
        and c.collaboration_enabled = true
        and cc.user_id = (select auth.uid())
    )
  );

drop policy if exists "mp_tool_checklist_collab_update" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_update" on public.mp_tool_checklist
  for update using (
    exists (
      select 1
      from public.checklists c
      join public.checklist_collaborators cc on cc.checklist_id = c.id
      where c.id = mp_tool_checklist.checklist_id
        and c.collaboration_enabled = true
        and cc.user_id = (select auth.uid())
    )
  );

drop policy if exists "mp_tool_checklist_collab_delete" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_delete" on public.mp_tool_checklist
  for delete using (
    exists (
      select 1
      from public.checklists c
      join public.checklist_collaborators cc on cc.checklist_id = c.id
      where c.id = mp_tool_checklist.checklist_id
        and c.collaboration_enabled = true
        and cc.user_id = (select auth.uid())
    )
  );

-- 5. 以 Email 新增協作者（查 auth.users，僅擁有者可呼叫）
create or replace function public.add_checklist_collaborator_by_email(p_checklist_id uuid, p_email text)
returns json
language plpgsql
security definer
set search_path = public
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

  select user_id into v_owner from public.checklists where id = p_checklist_id;
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

  insert into public.checklist_collaborators (checklist_id, user_id, invited_email)
  values (p_checklist_id, v_uid, v_norm)
  on conflict (checklist_id, user_id) do update set invited_email = excluded.invited_email;

  return json_build_object('ok', true);
end;
$$;

revoke all on function public.add_checklist_collaborator_by_email(uuid, text) from public;
grant execute on function public.add_checklist_collaborator_by_email(uuid, text) to authenticated;
