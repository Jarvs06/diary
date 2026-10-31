-- Supabase enables pg-safeupdate for Data API sessions, which rejects DELETE
-- statements without a WHERE clause. set_passcode() is called through the API
-- (from the update-passcode function), so give its delete an explicit WHERE.

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

  delete from public.unlock_attempts where client_key is not null;
end;
$$;

create or replace function public.reset_unlock_lockouts()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.unlock_attempts where client_key is not null;
$$;

-- create or replace keeps existing grants; restated here for clarity.
revoke all on function public.set_passcode(text, text) from public, anon, authenticated;
grant execute on function public.set_passcode(text, text) to service_role;
revoke all on function public.reset_unlock_lockouts() from public, anon, authenticated;
grant execute on function public.reset_unlock_lockouts() to service_role;
