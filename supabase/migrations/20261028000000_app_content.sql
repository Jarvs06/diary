-- =============================================================================
-- app_content: the single source of truth for every piece of editable text.
--
-- Access model
--   * RLS is enabled and NO policies are defined, so the `anon` and
--     `authenticated` roles (i.e. anyone holding the publishable key) cannot
--     read or write this table through the Data API.
--   * Table privileges are additionally revoked from those roles.
--   * Only the Edge Functions (running with the service role, server-side)
--     read the letter, and only after a passcode has been verified.
--   * The welcome-screen text is exposed through a narrow SECURITY DEFINER
--     function (`get_welcome`) that returns non-sensitive columns only.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

create table public.app_content (
  id               uuid        primary key default gen_random_uuid(),
  app_key          text        not null unique,
  recipient_name   text        not null default '',
  welcome_title    text        not null default '',
  welcome_message  text        not null default '',
  -- bcrypt hash produced by public.set_passcode(). Never store a plain passcode.
  passcode_hash    text,
  -- Incremented automatically whenever passcode_hash changes. Unlock sessions
  -- carry this number, so changing the passcode invalidates every session.
  passcode_version integer     not null default 0,
  letter_title     text        not null default '',
  letter_body      text        not null default '',
  signature        text        not null default '',
  is_published     boolean     not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint app_content_app_key_format
    check (app_key ~ '^[a-z0-9_]{1,64}$'),
  -- Guards against someone pasting a plain-text passcode into this column in
  -- the Table Editor. Only bcrypt hashes ($2a$/$2b$/$2y$) are accepted.
  constraint app_content_passcode_hash_is_bcrypt
    check (passcode_hash is null or passcode_hash ~ '^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$')
);

comment on table public.app_content is
  'Editable app text. Edit rows in the Supabase Table Editor. Change the passcode only via public.set_passcode() or the update-passcode Edge Function.';
comment on column public.app_content.passcode_hash is
  'bcrypt hash. Do not edit by hand: run  select public.set_passcode(''janina_letter'', ''NEW-PASSCODE'');';
comment on column public.app_content.letter_body is
  'Plain text. Blank lines separate paragraphs; single line breaks are preserved.';

-- Keep updated_at and passcode_version current on every change. ---------------
create or replace function public.app_content_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if new.passcode_hash is distinct from old.passcode_hash then
    new.passcode_version := old.passcode_version + 1;
  end if;
  return new;
end;
$$;

create trigger app_content_before_update
  before update on public.app_content
  for each row execute function public.app_content_before_update();

-- Lock the table down. ---------------------------------------------------------
alter table public.app_content enable row level security;
-- (Intentionally no policies: anon/authenticated get zero rows.)

revoke all on table public.app_content from public, anon, authenticated;
grant select, insert, update, delete on table public.app_content to service_role;

-- Public, non-sensitive welcome text. -----------------------------------------
create or replace function public.get_welcome(p_app_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'recipient_name',  c.recipient_name,
    'welcome_title',   c.welcome_title,
    'welcome_message', c.welcome_message
  )
  from public.app_content c
  where c.app_key = p_app_key;
$$;

revoke all on function public.get_welcome(text) from public;
grant execute on function public.get_welcome(text) to anon, authenticated, service_role;
