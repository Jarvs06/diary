-- Placeholder content. Replace every bracketed value in the Supabase Table
-- Editor (or by editing and re-running this script) before publishing.
--
-- No passcode is set here on purpose. After seeding, set one in the SQL Editor:
--   select public.set_passcode('janina_letter', 'YOUR-PASSCODE');
-- Until then, the app shows "The letter isn't ready yet."

insert into public.app_content (
  app_key,
  recipient_name,
  welcome_title,
  welcome_message,
  letter_title,
  letter_body,
  signature,
  is_published
) values (
  'janina_letter',
  'Janina',
  'Hi, Janina.',
  'There''s something I''d like you to read.',
  'For Janina',
  E'[Write the opening of your letter here.]\n\n'
  || E'[Each blank line starts a new paragraph.\nA single line break, like this one, stays on its own line.]\n\n'
  || E'[Write the rest of your letter here.]',
  E'[Your closing line],\n[Your name]',
  false
)
on conflict (app_key) do nothing;
