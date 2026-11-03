-- =============================================================================
-- Likes on replies, "Seen" on posts, pinned posts, and cleaning up reply
-- photos left behind.
--
-- Reply likes
--   * One like per person per reply, always as yourself, on replies you can
--     see. Visible to both people while the reply is.
--
-- Seen
--   * When you read the other person's shared post, the app records it once
--     (note_views). The author sees "Seen". You can only record yourself,
--     only for shared posts you can see, and it can't be changed or removed.
--
-- Pins
--   * Each person pins posts for themselves (their own or the other's); they
--     show on top in "Pinned" on the profile. Your pins are private to you.
--
-- Reply photo cleanup
--   * Deleting a post or a reply also deletes its replies/answers, which can
--     leave their photo files behind (invisible to everyone). A participant
--     may list and remove such leftover files, and only those.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Reply likes
-- ---------------------------------------------------------------------------
create table public.reply_likes (
  reply_id   uuid        not null references public.replies (id) on delete cascade,
  user_id    uuid        not null default auth.uid()
                         references public.participants (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (reply_id, user_id)
);

alter table public.reply_likes enable row level security;

-- True when the person can see the reply (its post is shared, or theirs).
create or replace function public.can_view_reply(p_reply uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_participant()
     and exists (
       select 1
         from public.replies r
         join public.notes n on n.id = r.note_id
        where r.id = p_reply
          and (n.status = 'published' or n.author_id = (select auth.uid()))
     );
$$;

revoke all on function public.can_view_reply(uuid) from public, anon;
grant execute on function public.can_view_reply(uuid) to authenticated, service_role;

create policy "read likes of visible replies"
  on public.reply_likes for select to authenticated
  using (public.can_view_reply(reply_id));

create policy "like visible replies as yourself"
  on public.reply_likes for insert to authenticated
  with check (user_id = (select auth.uid()) and public.can_view_reply(reply_id));

create policy "remove your own reply like"
  on public.reply_likes for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.reply_likes from public, anon, authenticated;
grant select, delete on table public.reply_likes to authenticated;
grant insert (reply_id) on table public.reply_likes to authenticated;
grant all on table public.reply_likes to service_role;

-- ---------------------------------------------------------------------------
-- Seen
-- ---------------------------------------------------------------------------
create table public.note_views (
  note_id uuid        not null references public.notes (id) on delete cascade,
  user_id uuid        not null default auth.uid()
                      references public.participants (id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

alter table public.note_views enable row level security;

create policy "read views of visible entries"
  on public.note_views for select to authenticated
  using (
    (select public.is_participant())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and (n.status = 'published' or n.author_id = (select auth.uid()))
    )
  );

create policy "record seeing the other person's shared entry"
  on public.note_views for insert to authenticated
  with check (
    (select public.is_participant())
    and user_id = (select auth.uid())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and n.status = 'published'
         and n.author_id <> (select auth.uid())
    )
  );

revoke all on table public.note_views from public, anon, authenticated;
grant select on table public.note_views to authenticated;
grant insert (note_id) on table public.note_views to authenticated;
grant all on table public.note_views to service_role;

-- ---------------------------------------------------------------------------
-- Pins
-- ---------------------------------------------------------------------------
create table public.note_pins (
  note_id    uuid        not null references public.notes (id) on delete cascade,
  user_id    uuid        not null default auth.uid()
                         references public.participants (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

alter table public.note_pins enable row level security;

create policy "read your own pins"
  on public.note_pins for select to authenticated
  using ((select public.is_participant()) and user_id = (select auth.uid()));

create policy "pin entries you can see"
  on public.note_pins for insert to authenticated
  with check (
    (select public.is_participant())
    and user_id = (select auth.uid())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and (n.status = 'published' or n.author_id = (select auth.uid()))
    )
  );

create policy "unpin your own pins"
  on public.note_pins for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.note_pins from public, anon, authenticated;
grant select, delete on table public.note_pins to authenticated;
grant insert (note_id) on table public.note_pins to authenticated;
grant all on table public.note_pins to service_role;

-- ---------------------------------------------------------------------------
-- Realtime: reply likes and "Seen" reach the other phone right away.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.reply_likes, public.note_views;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reply photo cleanup
-- ---------------------------------------------------------------------------
-- True for a reply photo file whose reply no longer exists.
create or replace function public.is_orphan_reply_image(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_participant()
     and not exists (select 1 from public.replies r where r.image_path = p_name);
$$;

-- Names of leftover reply photo files, for the app to remove.
create or replace function public.orphan_reply_images()
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
    from storage.objects o
   where public.is_participant()
     and o.bucket_id = 'reply-images'
     and not exists (select 1 from public.replies r where r.image_path = o.name)
   limit 100;
$$;

revoke all on function public.is_orphan_reply_image(text), public.orphan_reply_images() from public, anon;
grant execute on function public.is_orphan_reply_image(text), public.orphan_reply_images()
  to authenticated, service_role;

-- Postgres only deletes rows the user can also select, so leftovers must be
-- visible to be removed.
drop policy "reply photos: read visible" on storage.objects;
create policy "reply photos: read visible"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'reply-images'
    and (
      public.can_view_reply_image(name)
      or owner_id = (select auth.uid())::text
      or public.is_orphan_reply_image(name)
    )
  );

drop policy "reply photos: author removes" on storage.objects;
create policy "reply photos: author removes"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'reply-images'
    and (
      public.owns_reply_image(name)
      or owner_id = (select auth.uid())::text
      or public.is_orphan_reply_image(name)
    )
  );
