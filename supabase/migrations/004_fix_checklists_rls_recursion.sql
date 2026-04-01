-- 修正：checklists（協作者 SELECT）↔ checklist_collaborators（擁有者 policy 查 checklists）造成
-- infinite recursion detected in policy for relation "checklists"
--
-- 作法：以 SECURITY DEFINER 函式讀取 checklists／join，略過 RLS，打斷循環。
-- mp_tool_checklist 的協作者 SELECT 改為只查 checklist_collaborators（不需再 join checklists）。

-- 1. 擁有者檢查（供 checklist_collaborators 的 policy 使用，避免 policy 內直接 SELECT checklists）
create or replace function public.checklist_owned_by_user(p_checklist_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.checklists c
    where c.id = p_checklist_id
      and c.user_id is not distinct from p_user_id
  );
$$;

comment on function public.checklist_owned_by_user(uuid, uuid) is 'RLS 輔助：是否為進度表擁有者；略過 checklists RLS 以避免與協作者 policy 遞迴';

-- 2. 協作者可否編輯列（需 collaboration_enabled；內部讀取 checklists + checklist_collaborators 均略過 RLS）
create or replace function public.collaborator_may_edit_mp_rows(p_checklist_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.checklists c
    inner join public.checklist_collaborators cc on cc.checklist_id = c.id
    where c.id = p_checklist_id
      and c.collaboration_enabled is true
      and cc.user_id is not distinct from p_user_id
  );
$$;

comment on function public.collaborator_may_edit_mp_rows(uuid, uuid) is 'RLS 輔助：協作者且已開啟共同編輯時可改 mp_tool_checklist 列';

revoke all on function public.checklist_owned_by_user(uuid, uuid) from public;
revoke all on function public.collaborator_may_edit_mp_rows(uuid, uuid) from public;
grant execute on function public.checklist_owned_by_user(uuid, uuid) to authenticated, anon;
grant execute on function public.collaborator_may_edit_mp_rows(uuid, uuid) to authenticated, anon;

-- 3. 重寫 checklist_collaborators 擁有者 policies（改為呼叫函式）
drop policy if exists "checklist_collaborators_owner_select" on public.checklist_collaborators;
create policy "checklist_collaborators_owner_select" on public.checklist_collaborators
  for select using (
    public.checklist_owned_by_user(checklist_collaborators.checklist_id, (select auth.uid()))
  );

drop policy if exists "checklist_collaborators_owner_insert" on public.checklist_collaborators;
create policy "checklist_collaborators_owner_insert" on public.checklist_collaborators
  for insert with check (
    public.checklist_owned_by_user(checklist_collaborators.checklist_id, (select auth.uid()))
  );

drop policy if exists "checklist_collaborators_owner_delete" on public.checklist_collaborators;
create policy "checklist_collaborators_owner_delete" on public.checklist_collaborators
  for delete using (
    public.checklist_owned_by_user(checklist_collaborators.checklist_id, (select auth.uid()))
  );

-- 4. mp_tool_checklist：協作者 SELECT 僅查協作者表（不再 join checklists，避免觸發 checklists RLS）
drop policy if exists "mp_tool_checklist_collab_select" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_select" on public.mp_tool_checklist
  for select using (
    exists (
      select 1 from public.checklist_collaborators cc
      where cc.checklist_id = mp_tool_checklist.checklist_id
        and cc.user_id = (select auth.uid())
    )
  );

drop policy if exists "mp_tool_checklist_collab_insert" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_insert" on public.mp_tool_checklist
  for insert with check (
    public.collaborator_may_edit_mp_rows(mp_tool_checklist.checklist_id, (select auth.uid()))
  );

drop policy if exists "mp_tool_checklist_collab_update" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_update" on public.mp_tool_checklist
  for update using (
    public.collaborator_may_edit_mp_rows(mp_tool_checklist.checklist_id, (select auth.uid()))
  );

drop policy if exists "mp_tool_checklist_collab_delete" on public.mp_tool_checklist;
create policy "mp_tool_checklist_collab_delete" on public.mp_tool_checklist
  for delete using (
    public.collaborator_may_edit_mp_rows(mp_tool_checklist.checklist_id, (select auth.uid()))
  );
