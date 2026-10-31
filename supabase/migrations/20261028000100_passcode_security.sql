-- =============================================================================
-- Passcode hashing, verification and rate limiting.
--
-- All functions here are SECURITY DEFINER and executable ONLY by service_role
-- (the Edge Functions) and the database owner (the Dashboard SQL Editor).
-- The mobile app can never call them directly.
-- =============================================================================

-- Failed-attempt bookkeeping. One row per client (a salted hash of the caller's
-- IP address, computed in the Edge Function) plus one global row '__global__'
-- that caps total failures across all clients, so rotating IP addresses does
-- not allow unlimited guessing.
create table public.unlock_attempts (
  client_key        text        primary key,
  failed_count      integer     not null default 0,
  window_started_at timestamptz not null default now(),
  locked_until      timestamptz,
  lockout_level     integer     not null default 0,
  updated_at        timestamptz not null default now()
);

alter table public.unlock_attempts enable row level security;
revoke all on table public.unlock_attempts from public, anon, authenticated;
grant select, insert, update, delete on table public.unlock_attempts to service_role;

-- -----------------------------------------------------------------------------
-- set_passcode: hash and store a new passcode (bcrypt, cost 12).
-- Changing the hash bumps passcode_version (trigger), which invalidates every
-- existing unlock session, and clears all lockouts.
-- -----------------------------------------------------------------------------
create or replace function public.set_passcode(p_app_key text, p_passcode text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_passcode is null or char_length(p_passcode) < 4 or char_length(p_passcode) > 64 then
    raise exception 'Passcode must be between 4 and 64 characters.'
      using errcode = '22023';
  end if;

  update public.app_content
     set passcode_hash = extensions.crypt(p_passcode, extensions.gen_salt('bf', 12))
   where app_key = p_app_key;

  if not found then
    raise exception 'No app_content row with app_key %', p_app_key
      using errcode = 'P0002';
  end if;

  delete from public.unlock_attempts;
end;
$$;

revoke all on function public.set_passcode(text, text) from public, anon, authenticated;
grant execute on function public.set_passcode(text, text) to service_role;

-- -----------------------------------------------------------------------------
-- verify_passcode_attempt: atomically check lockouts, verify, and record.
--
-- Returns jsonb:
--   {"status":"ok", "passcode_version": n}
--   {"status":"invalid", "attempts_remaining": n}
--   {"status":"locked", "retry_after_seconds": n}
--   {"status":"not_ready"}      -- no row or no passcode configured yet
--
-- Limits:
--   per client : 5 failures within 15 min -> lock 5 min, doubling on each
--                repeat lockout (5, 10, 20 ... capped at 24 h)
--   global     : 20 failures within 60 min -> lock 15 min, doubling
--                (capped at 6 h)
-- -----------------------------------------------------------------------------
create or replace function public.verify_passcode_attempt(
  p_app_key    text,
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
  c_client_max      constant integer  := 5;
  c_client_window   constant interval := interval '15 minutes';
  c_client_base     constant interval := interval '5 minutes';
  c_client_cap      constant interval := interval '24 hours';
  c_global_key      constant text     := '__global__';
  c_global_max      constant integer  := 20;
  c_global_window   constant interval := interval '60 minutes';
  c_global_base     constant interval := interval '15 minutes';
  c_global_cap      constant interval := interval '6 hours';
  c_level_decay     constant interval := interval '24 hours';

  v_now     timestamptz := now();
  v_client  public.unlock_attempts;
  v_global  public.unlock_attempts;
  v_hash    text;
  v_version integer;
  v_lock    timestamptz;
begin
  if p_client_key is null or p_client_key = c_global_key then
    raise exception 'invalid client key' using errcode = '22023';
  end if;

  insert into public.unlock_attempts (client_key)
  values (p_client_key), (c_global_key)
  on conflict (client_key) do nothing;

  -- Row locks serialise concurrent guesses so counters cannot be raced.
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

  select passcode_hash, passcode_version
    into v_hash, v_version
    from public.app_content
   where app_key = p_app_key;

  if v_hash is null then
    return jsonb_build_object('status', 'not_ready');
  end if;

  if p_passcode is not null
     and char_length(p_passcode) between 1 and 64
     and extensions.crypt(p_passcode, v_hash) = v_hash then
    update public.unlock_attempts
       set failed_count = 0, window_started_at = v_now, locked_until = null,
           lockout_level = 0, updated_at = v_now
     where client_key in (p_client_key, c_global_key);
    return jsonb_build_object('status', 'ok', 'passcode_version', v_version);
  end if;

  -- ---- Wrong passcode: record the failure. ----
  -- Forget old lockout escalation after a long quiet period.
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
     set failed_count = v_client.failed_count,
         window_started_at = v_client.window_started_at,
         locked_until = v_client.locked_until,
         lockout_level = v_client.lockout_level,
         updated_at = v_now
   where client_key = p_client_key;

  update public.unlock_attempts
     set failed_count = v_global.failed_count,
         window_started_at = v_global.window_started_at,
         locked_until = v_global.locked_until,
         lockout_level = v_global.lockout_level,
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

revoke all on function public.verify_passcode_attempt(text, text, text) from public, anon, authenticated;
grant execute on function public.verify_passcode_attempt(text, text, text) to service_role;

-- -----------------------------------------------------------------------------
-- reset_unlock_lockouts: escape hatch if Janina gets locked out.
--   select public.reset_unlock_lockouts();
-- -----------------------------------------------------------------------------
create or replace function public.reset_unlock_lockouts()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.unlock_attempts;
$$;

revoke all on function public.reset_unlock_lockouts() from public, anon, authenticated;
grant execute on function public.reset_unlock_lockouts() to service_role;
