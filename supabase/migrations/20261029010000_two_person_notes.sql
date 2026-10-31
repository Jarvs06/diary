-- =============================================================================
-- Two-person notes: participants, notes, replies.
--
-- Identity
--   Each person is a real Supabase Auth user. Signing in happens through the
--   sign-in Edge Function: it checks that person's passcode (bcrypt + rate
--   limiting, below) and then issues a normal Supabase session. From then on
--   every query runs as `authenticated` with auth.uid() = that person, and RLS
--   decides what they may see or change.
--
-- Rules (enforced here, not in the app)
--   * Only the two rows in `participants` can read anything.
--   * Published notes are visible to both; drafts only to their author.
--   * Only the author can create or edit their own notes.
--   * Replies can be added only to published notes, and are visible only
--     while their parent note is visible.
--   * `anon` (the publishable key alone) gets nothing from these tables.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- participants: exactly two people, keyed 'author' (you) and 'janina'.
-- ---------------------------------------------------------------------------
create table public.participants (
  id              uuid        primary key references auth.users (id) on delete cascade,
  participant_key text        not null unique
                              check (participant_key in ('author', 'janina')),
  display_name    text        not null
                              check (char_length(btrim(display_name)) between 1 and 60),
  created_at      timestamptz not null default now()
);

comment on table public.participants is
  'The two people who can use the app. Rows are created by the update-passcode Edge Function. display_name may be edited in the Table Editor.';

-- Passcode hashes live apart from participants so they are never readable
-- through the participants SELECT policy.
create table public.participant_credentials (
  participant_id uuid        primary key references public.participants (id) on delete cascade,
  passcode_hash  text        not null
                             check (passcode_hash ~ '^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$'),
  updated_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- notes
-- ---------------------------------------------------------------------------
create table public.notes (
  id               uuid        primary key default gen_random_uuid(),
  author_id        uuid        not null default auth.uid()
                               references public.participants (id) on delete restrict,
  title            text        not null default ''
                               check (char_length(title) <= 200),
  body             text        not null default ''
                               check (char_length(body) <= 100000),
  status           text        not null default 'draft'
                               check (status in ('draft', 'published')),
  -- Bumped on every content change; clients send the version they edited so
  -- a stale editor cannot silently overwrite newer text.
  version          integer     not null default 1,
  -- Set only for the imported original letter (prevents importing twice).
  source_app_key   text        unique,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  published_at     timestamptz,
  -- Latest edit, publish, or reply. Drives the Recents order.
  last_activity_at timestamptz not null default now(),

  constraint notes_published_has_body
    check (status = 'draft' or char_length(btrim(body)) > 0)
);

create index notes_last_activity_idx on public.notes (last_activity_at desc);
create index notes_author_idx on public.notes (author_id);

-- ---------------------------------------------------------------------------
-- replies
-- ---------------------------------------------------------------------------
create table public.replies (
  -- Clients generate the id, so a retried or double-tapped send cannot create
  -- a duplicate (the second insert hits the primary key).
  id         uuid        primary key default gen_random_uuid(),
  note_id    uuid        not null references public.notes (id) on delete cascade,
  author_id  uuid        not null default auth.uid()
                         references public.participants (id) on delete restrict,
  body       text        not null
                         check (char_length(btrim(body)) between 1 and 20000),
  created_at timestamptz not null default now()
);

create index replies_note_created_idx on public.replies (note_id, created_at);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
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
     or new.status is distinct from old.status then
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

create trigger notes_before_write
  before insert or update on public.notes
  for each row execute function public.notes_before_write();

-- A reply counts as activity on its note (for Recents ordering). Runs as the
-- table owner because the replier is usually not the note's author.
create or replace function public.replies_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.notes
     set last_activity_at = greatest(last_activity_at, new.created_at)
   where id = new.note_id;
  return null;
end;
$$;

create trigger replies_after_insert
  after insert on public.replies
  for each row execute function public.replies_after_insert();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
create or replace function public.is_participant()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.participants where id = (select auth.uid()));
$$;

revoke all on function public.is_participant() from public, anon;
grant execute on function public.is_participant() to authenticated, service_role;

alter table public.participants enable row level security;
alter table public.participant_credentials enable row level security;
alter table public.notes enable row level security;
alter table public.replies enable row level security;

create policy "participants can see each other"
  on public.participants for select to authenticated
  using ((select public.is_participant()));

-- participant_credentials: no policies at all (service role only).

create policy "read published notes and own drafts"
  on public.notes for select to authenticated
  using (
    (select public.is_participant())
    and (status = 'published' or author_id = (select auth.uid()))
  );

create policy "create own notes"
  on public.notes for insert to authenticated
  with check (
    (select public.is_participant())
    and author_id = (select auth.uid())
  );

create policy "edit own notes"
  on public.notes for update to authenticated
  using (author_id = (select auth.uid()))
  with check (
    (select public.is_participant())
    and author_id = (select auth.uid())
  );

create policy "read replies of visible notes"
  on public.replies for select to authenticated
  using (
    (select public.is_participant())
    and exists (
      select 1 from public.notes n
       where n.id = note_id
         and (n.status = 'published' or n.author_id = (select auth.uid()))
    )
  );

create policy "reply to published notes"
  on public.replies for insert to authenticated
  with check (
    (select public.is_participant())
    and author_id = (select auth.uid())
    and exists (
      select 1 from public.notes n
       where n.id = note_id and n.status = 'published'
    )
  );

-- ---------------------------------------------------------------------------
-- Privileges. Column-level grants keep clients from setting author_id,
-- timestamps or version themselves.
-- ---------------------------------------------------------------------------
revoke all on table public.participants, public.participant_credentials,
                    public.notes, public.replies
  from public, anon, authenticated;

grant select on table public.participants to authenticated;
grant select on table public.notes to authenticated;
grant insert (id, title, body, status) on table public.notes to authenticated;
grant update (title, body, status) on table public.notes to authenticated;
grant select on table public.replies to authenticated;
grant insert (id, note_id, body) on table public.replies to authenticated;

grant all on table public.participants, public.participant_credentials,
                   public.notes, public.replies
  to service_role;

-- ---------------------------------------------------------------------------
-- Realtime: push note and reply changes to the other device. Realtime applies
-- the same RLS policies, so drafts are never broadcast to the other person.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notes, public.replies;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Server-side helpers (service role only).
-- ---------------------------------------------------------------------------

-- Creates or renames a participant row for an existing auth user.
create or replace function public.register_participant(
  p_user_id uuid,
  p_participant_key text,
  p_display_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing uuid;
begin
  select id into v_existing from public.participants where participant_key = p_participant_key;
  if v_existing is not null and v_existing <> p_user_id then
    raise exception 'participant % is already linked to another account', p_participant_key
      using errcode = '23505';
  end if;

  insert into public.participants (id, participant_key, display_name)
  values (p_user_id, p_participant_key, btrim(p_display_name))
  on conflict (id) do update set display_name = excluded.display_name;
end;
$$;

-- Copies the original confession letter from app_content into notes, once,
-- authored by the 'author' participant. Keeps its publication state.
create or replace function public.import_original_letter(p_app_key text default 'janina_letter')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author uuid;
begin
  select id into v_author from public.participants where participant_key = 'author';
  if v_author is null then
    return;
  end if;

  insert into public.notes (
    author_id, title, body, status, source_app_key,
    created_at, updated_at, last_activity_at, published_at
  )
  select v_author,
         left(coalesce(nullif(btrim(c.letter_title), ''), 'For ' || c.recipient_name), 200),
         coalesce(c.letter_body, '')
           || case when coalesce(btrim(c.signature), '') <> ''
                   then E'\n\n' || c.signature else '' end,
         case when c.is_published and btrim(coalesce(c.letter_body, '')) <> ''
              then 'published' else 'draft' end,
         c.app_key,
         c.created_at, c.updated_at, c.updated_at,
         case when c.is_published then c.updated_at end
    from public.app_content c
   where c.app_key = p_app_key
  on conflict (source_app_key) do nothing;
end;
$$;

-- Sets one participant's passcode (bcrypt, cost 12). Two people may not share
-- a passcode, because the passcode is what identifies who is signing in.
create or replace function public.set_participant_passcode(
  p_participant_key text,
  p_passcode text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_passcode is null or p_passcode !~ '^[0-9]{4,12}$' then
    raise exception 'Passcode must be 4 to 12 digits.' using errcode = '22023';
  end if;

  select id into v_id from public.participants where participant_key = p_participant_key;
  if v_id is null then
    raise exception 'No participant %', p_participant_key using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.participant_credentials c
     where c.participant_id <> v_id
       and extensions.crypt(p_passcode, c.passcode_hash) = c.passcode_hash
  ) then
    raise exception 'passcode_in_use' using errcode = '23505';
  end if;

  insert into public.participant_credentials (participant_id, passcode_hash, updated_at)
  values (v_id, extensions.crypt(p_passcode, extensions.gen_salt('bf', 12)), now())
  on conflict (participant_id) do update
    set passcode_hash = excluded.passcode_hash, updated_at = now();

  delete from public.unlock_attempts where client_key is not null;
end;
$$;

-- Checks a passcode against both participants with the same lockout rules as
-- before (per client: 5 / 15 min, doubling; global: 20 / 60 min, doubling).
--
-- Returns jsonb:
--   {"status":"ok", "participant_id": uuid}
--   {"status":"invalid", "attempts_remaining": n}
--   {"status":"locked", "retry_after_seconds": n}
--   {"status":"not_ready"}
create or replace function public.verify_participant_passcode(
  p_client_key text,
  p_passcode   text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_client_max    constant integer  := 5;
  c_client_window constant interval := interval '15 minutes';
  c_client_base   constant interval := interval '5 minutes';
  c_client_cap    constant interval := interval '24 hours';
  c_global_key    constant text     := '__global__';
  c_global_max    constant integer  := 20;
  c_global_window constant interval := interval '60 minutes';
  c_global_base   constant interval := interval '15 minutes';
  c_global_cap    constant interval := interval '6 hours';
  c_level_decay   constant interval := interval '24 hours';

  v_now     timestamptz := now();
  v_client  public.unlock_attempts;
  v_global  public.unlock_attempts;
  v_match   uuid;
  v_lock    timestamptz;
begin
  if p_client_key is null or p_client_key = c_global_key then
    raise exception 'invalid client key' using errcode = '22023';
  end if;

  insert into public.unlock_attempts (client_key)
  values (p_client_key), (c_global_key)
  on conflict (client_key) do nothing;

  select * into v_global from public.unlock_attempts where client_key = c_global_key for update;
  select * into v_client from public.unlock_attempts where client_key = p_client_key for update;

  v_lock := greatest(coalesce(v_client.locked_until, '-infinity'),
                     coalesce(v_global.locked_until, '-infinity'));
  if v_lock > v_now then
    return jsonb_build_object(
      'status', 'locked',
      'retry_after_seconds', ceil(extract(epoch from (v_lock - v_now)))::integer
    );
  end if;

  if not exists (select 1 from public.participant_credentials) then
    return jsonb_build_object('status', 'not_ready');
  end if;

  if p_passcode is not null and char_length(p_passcode) between 1 and 64 then
    select c.participant_id into v_match
      from public.participant_credentials c
     where extensions.crypt(p_passcode, c.passcode_hash) = c.passcode_hash
     limit 1;
  end if;

  if v_match is not null then
    update public.unlock_attempts
       set failed_count = 0, window_started_at = v_now, locked_until = null,
           lockout_level = 0, updated_at = v_now
     where client_key in (p_client_key, c_global_key);
    return jsonb_build_object('status', 'ok', 'participant_id', v_match);
  end if;

  -- Wrong passcode: record the failure.
  if v_client.locked_until is not null and v_client.locked_until < v_now - c_level_decay then
    v_client.lockout_level := 0;
  end if;
  if v_global.locked_until is not null and v_global.locked_until < v_now - c_level_decay then
    v_global.lockout_level := 0;
  end if;
  if v_client.window_started_at < v_now - c_client_window then
    v_client.failed_count := 0;
    v_client.window_started_at := v_now;
  end if;
  if v_global.window_started_at < v_now - c_global_window then
    v_global.failed_count := 0;
    v_global.window_started_at := v_now;
  end if;

  v_client.failed_count := v_client.failed_count + 1;
  v_global.failed_count := v_global.failed_count + 1;

  if v_client.failed_count >= c_client_max then
    v_client.locked_until := v_now + least(c_client_base * power(2, v_client.lockout_level), c_client_cap);
    v_client.lockout_level := least(v_client.lockout_level + 1, 16);
    v_client.failed_count := 0;
    v_client.window_started_at := v_now;
  end if;
  if v_global.failed_count >= c_global_max then
    v_global.locked_until := v_now + least(c_global_base * power(2, v_global.lockout_level), c_global_cap);
    v_global.lockout_level := least(v_global.lockout_level + 1, 16);
    v_global.failed_count := 0;
    v_global.window_started_at := v_now;
  end if;

  update public.unlock_attempts
     set failed_count = v_client.failed_count, window_started_at = v_client.window_started_at,
         locked_until = v_client.locked_until, lockout_level = v_client.lockout_level,
         updated_at = v_now
   where client_key = p_client_key;
  update public.unlock_attempts
     set failed_count = v_global.failed_count, window_started_at = v_global.window_started_at,
         locked_until = v_global.locked_until, lockout_level = v_global.lockout_level,
         updated_at = v_now
   where client_key = c_global_key;

  v_lock := greatest(coalesce(v_client.locked_until, '-infinity'),
                     coalesce(v_global.locked_until, '-infinity'));
  if v_lock > v_now then
    return jsonb_build_object(
      'status', 'locked',
      'retry_after_seconds', ceil(extract(epoch from (v_lock - v_now)))::integer
    );
  end if;

  return jsonb_build_object(
    'status', 'invalid',
    'attempts_remaining', c_client_max - v_client.failed_count
  );
end;
$$;

revoke all on function public.register_participant(uuid, text, text) from public, anon, authenticated;
revoke all on function public.import_original_letter(text) from public, anon, authenticated;
revoke all on function public.set_participant_passcode(text, text) from public, anon, authenticated;
revoke all on function public.verify_participant_passcode(text, text) from public, anon, authenticated;
grant execute on function public.register_participant(uuid, text, text) to service_role;
grant execute on function public.import_original_letter(text) to service_role;
grant execute on function public.set_participant_passcode(text, text) to service_role;
grant execute on function public.verify_participant_passcode(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Retire the single shared-passcode flow. app_content stays (it still holds
-- the welcome-screen text and the original letter's source).
-- ---------------------------------------------------------------------------
drop function if exists public.verify_passcode_attempt(text, text, text);
drop function if exists public.set_passcode(text, text);

comment on column public.app_content.passcode_hash is
  'Deprecated: passcodes now live in participant_credentials (one per person).';
comment on column public.app_content.letter_body is
  'Source of the original letter. It is copied into notes once; edit the note in the app afterwards.';
