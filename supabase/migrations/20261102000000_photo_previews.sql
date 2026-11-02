-- =============================================================================
-- Small preview copies of photos, for a faster feed.
--
-- Next to each photo '<note id>/<photo id>.<ext>' the app also uploads a
-- preview '<note id>/<photo id>.thumb.jpg' (at most 900 px). The feed shows
-- previews; the full photo is loaded only when it's opened.
--
-- Previews follow exactly the same rules as their photo:
--   * only the entry's author can upload or remove them;
--   * you can see a preview only if you can see that photo (it must be
--     listed in note_images for an entry visible to you).
-- =============================================================================

-- The entry id from a photo or preview name, or null for any other name.
create or replace function public.diary_image_note_id(p_name text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.(jpg|png|webp)|\.thumb\.jpg)$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;

-- True when the file is a listed photo (or that photo's preview) of an entry
-- the person can see.
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
        where (
                i.storage_path = p_name
                or (
                  p_name like '%.thumb.jpg'
                  and i.note_id = public.diary_image_note_id(p_name)
                  and i.id::text = split_part(split_part(p_name, '/', 2), '.', 1)
                )
              )
          and (n.status = 'published' or n.author_id = (select auth.uid()))
     );
$$;
