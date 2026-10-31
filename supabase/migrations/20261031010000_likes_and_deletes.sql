-- =============================================================================
-- Likes, and deleting your own entries.
--
-- Likes
--   * One like per person per entry (primary key), always as yourself.
--   * You can like only entries you can see that are shared (not drafts).
--   * Likes are visible to both people while the entry is visible.
--
-- Deleting
--   * The author can delete their own entry. Its replies, likes and photo rows
--     go with it (on delete cascade).
--   * The photo files are removed by the app through the Storage API. So that
--     cleanup still works after the entry row is gone, the uploader may always
--     delete their own files in the diary bucket.
-- =============================================================================

create table public.note_likes (
  note_id    uuid        not null references public.notes (id) on delete cascade,
  user_id    uuid        not null default auth.uid()
                         references public.participants (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

alter table public.note_likes enable row level security;

create policy "read likes of visible entries"
  on public.note_likes for select to authenticated
  using (
    (select public.is_participant())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and (n.status = 'published' or n.author_id = (select auth.uid()))
    )
  );

create policy "like shared entries as yourself"
  on public.note_likes for insert to authenticated
  with check (
    (select public.is_participant())
    and user_id = (select auth.uid())
    and exists (
      select 1 from public.notes n
       where n.id = note_id and n.status = 'published'
    )
  );

create policy "remove your own like"
  on public.note_likes for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.note_likes from public, anon, authenticated;
grant select, delete on table public.note_likes to authenticated;
grant insert (note_id) on table public.note_likes to authenticated;
grant all on table public.note_likes to service_role;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.note_likes;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Deleting your own entries
-- ---------------------------------------------------------------------------
create policy "delete own notes"
  on public.notes for delete to authenticated
  using (
    (select public.is_participant())
    and author_id = (select auth.uid())
  );

grant delete on table public.notes to authenticated;

-- Photo files: the uploader can always remove their own files, even after
-- the entry they belonged to is gone.
drop policy "diary photos: author removes" on storage.objects;
create policy "diary photos: author removes"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'diary-images'
    and (public.owns_diary_image(name) or owner_id = (select auth.uid())::text)
  );

-- Postgres only deletes rows the user can also select, so the uploader must
-- be able to see their own files for that cleanup to work.
drop policy "diary photos: read visible" on storage.objects;
create policy "diary photos: read visible"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'diary-images'
    and (
      public.can_view_diary_image(name)
      or public.owns_diary_image(name)
      or owner_id = (select auth.uid())::text
    )
  );
