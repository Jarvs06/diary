-- =============================================================================
-- Diary entries with photos.
--
--   * Each note is now a diary entry for a calendar day (`entry_date`).
--   * An entry can have up to three photos. Files live in the private
--     `diary-images` Storage bucket under `<note id>/<photo id>.<ext>`; the
--     `note_images` table lists them and is what the app reads.
--
-- Photo rules (enforced here, not in the app)
--   * Photos follow their entry: visible to both people once the entry is
--     shared, only to its author while it is a draft.
--   * Only the entry's author can add or remove its photos.
--   * At most three photos per entry; jpg/png/webp only, 10 MB each.
--   * `anon` gets nothing.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- notes.entry_date
-- ---------------------------------------------------------------------------
alter table public.notes add column entry_date date;
update public.notes set entry_date = created_at::date where entry_date is null;
alter table public.notes
  alter column entry_date set not null,
  alter column entry_date set default current_date;

grant insert (entry_date) on table public.notes to authenticated;
grant update (entry_date) on table public.notes to authenticated;

-- Same as before, plus: changing the date counts as an edit.
create or replace function public.notes_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'published' and new.published_at is null then
      new.published_at := new.created_at;
    end if;
    return new;
  end if;

  -- UPDATE
  new.id := old.id;
  new.author_id := old.author_id;
  new.created_at := old.created_at;
  new.source_app_key := old.source_app_key;

  if new.title is distinct from old.title
     or new.body is distinct from old.body
     or new.status is distinct from old.status
     or new.entry_date is distinct from old.entry_date then
    new.version := old.version + 1;
    new.updated_at := now();
    new.last_activity_at := now();
    if new.status = 'published' and old.published_at is null then
      new.published_at := now();
    else
      new.published_at := old.published_at;
    end if;
  else
    new.version := old.version;
    new.updated_at := old.updated_at;
    new.published_at := old.published_at;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- note_images
-- ---------------------------------------------------------------------------
create table public.note_images (
  -- Generated on the phone, so a retried upload cannot add the photo twice.
  id           uuid        primary key,
  note_id      uuid        not null references public.notes (id) on delete cascade,
  author_id    uuid        not null default auth.uid()
                           references public.participants (id) on delete restrict,
  storage_path text        not null unique,
  created_at   timestamptz not null default now(),

  constraint note_images_path_matches
    check (storage_path ~ ('^' || note_id::text || '/' || id::text || '\.(jpg|png|webp)$'))
);

create index note_images_note_created_idx on public.note_images (note_id, created_at);

-- Three photos per entry. Locks the entry row so two uploads at once can't
-- both squeeze in as the third.
create or replace function public.note_images_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.notes where id = new.note_id for update;
  if (select count(*) from public.note_images where note_id = new.note_id) >= 3 then
    raise exception 'An entry can have at most 3 photos' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger note_images_before_insert
  before insert on public.note_images
  for each row execute function public.note_images_before_insert();

-- Adding or removing a photo counts as activity on the entry (Recents order).
create or replace function public.note_images_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.notes
     set last_activity_at = greatest(last_activity_at, now())
   where id = coalesce(new.note_id, old.note_id);
  return null;
end;
$$;

create trigger note_images_after_change
  after insert or delete on public.note_images
  for each row execute function public.note_images_after_change();

alter table public.note_images enable row level security;

create policy "read photos of visible entries"
  on public.note_images for select to authenticated
  using (
    (select public.is_participant())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and (n.status = 'published' or n.author_id = (select auth.uid()))
    )
  );

create policy "add photos to own entries"
  on public.note_images for insert to authenticated
  with check (
    (select public.is_participant())
    and author_id = (select auth.uid())
    and exists (
      select 1 from public.notes n
       where n.id = note_id and n.author_id = (select auth.uid())
    )
  );

create policy "remove photos from own entries"
  on public.note_images for delete to authenticated
  using (
    (select public.is_participant())
    and exists (
      select 1 from public.notes n
       where n.id = note_id and n.author_id = (select auth.uid())
    )
  );

revoke all on table public.note_images from public, anon, authenticated;
grant select, delete on table public.note_images to authenticated;
grant insert (id, note_id, storage_path) on table public.note_images to authenticated;
grant all on table public.note_images to service_role;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.note_images;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Storage: private bucket + policies on storage.objects
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('diary-images', 'diary-images', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The entry id from '<note id>/<photo id>.<ext>', or null for any other name.
create or replace function public.diary_image_note_id(p_name text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;

-- True when the signed-in person wrote the entry this file belongs to.
create or replace function public.owns_diary_image(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_participant()
     and exists (
       select 1 from public.notes n
        where n.id = public.diary_image_note_id(p_name)
          and n.author_id = (select auth.uid())
     );
$$;

-- True when the file is a listed photo of an entry the person can see.
create or replace function public.can_view_diary_image(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_participant()
     and exists (
       select 1
         from public.note_images i
         join public.notes n on n.id = i.note_id
        where i.storage_path = p_name
          and (n.status = 'published' or n.author_id = (select auth.uid()))
     );
$$;

revoke all on function public.diary_image_note_id(text),
                       public.owns_diary_image(text),
                       public.can_view_diary_image(text)
  from public, anon;
grant execute on function public.diary_image_note_id(text),
                          public.owns_diary_image(text),
                          public.can_view_diary_image(text)
  to authenticated, service_role;

create policy "diary photos: read visible"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'diary-images'
    and (public.can_view_diary_image(name) or public.owns_diary_image(name))
  );

create policy "diary photos: author uploads"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'diary-images' and public.owns_diary_image(name));

create policy "diary photos: author removes"
  on storage.objects for delete to authenticated
  using (bucket_id = 'diary-images' and public.owns_diary_image(name));
