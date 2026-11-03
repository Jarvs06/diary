-- =============================================================================
-- Answering a reply, and a photo in a reply.
--
-- Answers
--   * A reply can answer another reply on the same entry (parent_id).
--   * One level only, like Facebook: you can't answer an answer; the app
--     files it under the same reply instead.
--   * Deleting a reply deletes its answers.
--   * Which reply it answers is fixed once sent (no update grant).
--
-- Photos
--   * A reply can carry one photo, stored in the private `reply-images`
--     bucket as '<reply id>.jpg' (image_path). With a photo the text may be
--     empty.
--   * Only the reply's author can upload or remove the file; you can see it
--     only if you can see the reply (same rules as the entry).
-- =============================================================================

alter table public.replies
  add column parent_id  uuid references public.replies (id) on delete cascade,
  add column image_path text,
  add constraint replies_image_path_check
    check (image_path is null or image_path = id::text || '.jpg');

create index replies_parent_idx on public.replies (parent_id) where parent_id is not null;

-- Text is still required, unless the reply has a photo.
alter table public.replies drop constraint replies_body_check;
alter table public.replies add constraint replies_body_check check (
  char_length(body) <= 20000
  and (char_length(btrim(body)) >= 1 or image_path is not null)
);

-- An answer must be to a top-level reply on the same entry.
create or replace function public.replies_check_parent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  parent public.replies%rowtype;
begin
  if new.parent_id is null then
    return new;
  end if;
  select * into parent from public.replies where id = new.parent_id;
  if not found or parent.note_id <> new.note_id or parent.parent_id is not null then
    raise exception 'A reply can only answer a top-level reply on the same post.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

revoke all on function public.replies_check_parent() from public, anon, authenticated;

create trigger replies_check_parent
  before insert on public.replies
  for each row execute function public.replies_check_parent();

grant insert (id, note_id, body, parent_id, image_path) on table public.replies to authenticated;

-- ---------------------------------------------------------------------------
-- Storage: reply photos
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('reply-images', 'reply-images', false, 10485760, array['image/jpeg'])
on conflict (id) do nothing;

-- True when the file belongs to a reply the person wrote.
create or replace function public.owns_reply_image(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_participant()
     and exists (
       select 1 from public.replies r
        where r.image_path = p_name
          and r.author_id = (select auth.uid())
     );
$$;

-- True when the file belongs to a reply on an entry the person can see.
create or replace function public.can_view_reply_image(p_name text)
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
        where r.image_path = p_name
          and (n.status = 'published' or n.author_id = (select auth.uid()))
     );
$$;

revoke all on function public.owns_reply_image(text), public.can_view_reply_image(text)
  from public, anon;
grant execute on function public.owns_reply_image(text), public.can_view_reply_image(text)
  to authenticated, service_role;

create policy "reply photos: read visible"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'reply-images'
    and (public.can_view_reply_image(name) or owner_id = (select auth.uid())::text)
  );

-- The reply is saved first, then its photo is uploaded.
create policy "reply photos: author uploads"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'reply-images' and public.owns_reply_image(name));

-- After the reply is deleted, its uploader can still clean the file up.
create policy "reply photos: author removes"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'reply-images'
    and (public.owns_reply_image(name) or owner_id = (select auth.uid())::text)
  );
