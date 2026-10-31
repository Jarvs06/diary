-- =============================================================================
-- Editing and deleting your own replies, and published app versions.
--
-- Replies
--   * The author of a reply can change its text or delete it. Nothing else
--     about a reply can change (column grant), and an edit records edited_at.
--   * You can only edit a reply while its entry is still visible to you.
--
-- App releases
--   * One row per APK you hand out. The app compares its own build number
--     with the newest row and offers the download link when it's behind.
--   * Only the two participants can read it; rows are added in the Dashboard
--     (or SQL editor) by the owner.
-- =============================================================================

alter table public.replies add column edited_at timestamptz;

create or replace function public.replies_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.body is distinct from old.body then
    new.edited_at := now();
  end if;
  return new;
end;
$$;

create trigger replies_before_update
  before update on public.replies
  for each row execute function public.replies_before_update();

create policy "edit own replies"
  on public.replies for update to authenticated
  using (author_id = (select auth.uid()))
  with check (
    (select public.is_participant())
    and author_id = (select auth.uid())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and (n.status = 'published' or n.author_id = (select auth.uid()))
    )
  );

create policy "delete own replies"
  on public.replies for delete to authenticated
  using (
    (select public.is_participant())
    and author_id = (select auth.uid())
  );

grant update (body) on table public.replies to authenticated;
grant delete on table public.replies to authenticated;

-- ---------------------------------------------------------------------------
-- App releases
-- ---------------------------------------------------------------------------
create table public.app_releases (
  version_code integer     primary key check (version_code > 0),
  version_name text        not null default '',
  apk_url      text        not null check (apk_url ~ '^https://'),
  notes        text        not null default '',
  created_at   timestamptz not null default now()
);

alter table public.app_releases enable row level security;

create policy "participants read releases"
  on public.app_releases for select to authenticated
  using ((select public.is_participant()));

revoke all on table public.app_releases from public, anon, authenticated;
grant select on table public.app_releases to authenticated;
grant all on table public.app_releases to service_role;
