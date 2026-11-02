// Exercises every migration + the seed in PGlite (Postgres in WASM, no Docker).
// Supabase's auth schema is simulated just enough for auth.uid() and RLS.
// Run from the project root:
//   deno run -A supabase/tests/migrations_test.ts .
import { PGlite } from "npm:@electric-sql/pglite@0.5.12";
import { pgcrypto } from "npm:@electric-sql/pglite@0.5.12/contrib/pgcrypto";

const root = Deno.args[0] ?? ".";
const db = new PGlite({ extensions: { pgcrypto } });

await db.exec(`
  create schema if not exists extensions;
  create schema auth;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid
  $$;
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  grant usage on schema public, auth to anon, authenticated, service_role;
  grant execute on function auth.uid() to anon, authenticated, service_role;

  -- Just enough of Supabase Storage for the bucket row and object policies.
  create schema storage;
  create table storage.buckets (id text primary key, name text not null, public boolean default false,
                                file_size_limit bigint, allowed_mime_types text[]);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets,
                                name text not null, owner uuid default auth.uid(),
                                owner_id text default auth.uid()::text, unique (bucket_id, name));
  alter table storage.objects enable row level security;
  grant usage on schema storage to anon, authenticated, service_role;
  grant select, insert, delete on storage.objects to anon, authenticated;
`);
const migrations = [...Deno.readDirSync(`${root}/supabase/migrations`)]
  .map((e) => e.name).filter((n) => n.endsWith(".sql")).sort();
for (const f of migrations) {
  await db.exec(await Deno.readTextFile(`${root}/supabase/migrations/${f}`));
}
await db.exec(await Deno.readTextFile(`${root}/supabase/seed.sql`));

let failures = 0;
function check(name: string, cond: boolean, detail?: unknown) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${cond ? "" : "  -> " + JSON.stringify(detail)}`);
  if (!cond) failures++;
}
async function one(sql: string, params: unknown[] = []) {
  return (await db.query(sql, params)).rows[0] as Record<string, any>;
}
/** Runs SQL as a role, optionally as a signed-in user. */
async function as(role: string, userId: string | null, sql: string, params: unknown[] = []) {
  await db.exec(`set role ${role}`);
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [
    userId ? JSON.stringify({ sub: userId, role }) : "",
  ]);
  try {
    return { rows: (await db.query(sql, params)).rows as Record<string, any>[], error: null as string | null };
  } catch (e) {
    return { rows: null, error: (e as Error).message };
  } finally {
    await db.exec("reset role");
    await db.query(`select set_config('request.jwt.claims', '', false)`);
  }
}
const verify = (client: string, pass: string) =>
  one("select public.verify_participant_passcode($1, $2) as r", [client, pass]).then((x) => x.r);

const ME = "00000000-0000-4000-8000-000000000001";
const JANINA = "00000000-0000-4000-8000-000000000002";
const STRANGER = "00000000-0000-4000-8000-000000000003";

// ---------------------------------------------------------------- welcome / app_content
let r = await as("anon", null, "select * from public.app_content");
check("anon cannot select app_content", r.error !== null, r);
r = await as("anon", null, "select public.get_welcome('janina_letter') as w");
check("anon can read welcome text only", r.error === null &&
  Object.keys(r.rows![0].w).sort().join() === "recipient_name,welcome_message,welcome_title", r);
r = await as("anon", null, "select public.verify_passcode_attempt('janina_letter','x','y')");
check("old shared-passcode function is gone", r.error !== null, r);

// ---------------------------------------------------------------- participants setup
check("not_ready before any passcode", (await verify("c0", "1234")).status === "not_ready");

await db.exec(`insert into auth.users values
  ('${ME}', 'author@example.com'), ('${JANINA}', 'janina@example.com'), ('${STRANGER}', 'x@example.com')`);
await db.exec("update public.app_content set letter_body = E'Dear Janina,\\n\\nThe letter.', is_published = true");
await one(`select public.register_participant('${ME}', 'author', 'Jarvey')`);
await one(`select public.import_original_letter()`);
await one(`select public.import_original_letter()`); // idempotent
await one(`select public.register_participant('${JANINA}', 'janina', 'Janina')`);
r = await as("postgres", null, `select public.register_participant('${STRANGER}', 'janina', 'Imposter')`);
check("a participant slot cannot be taken by another account", r.error !== null, r);
r = await as("postgres", null, `select public.register_participant('${STRANGER}', 'third', 'X')`);
check("only 'author' and 'janina' slots exist", r.error !== null, r);

let row = await one("select count(*)::int as n, min(title) as title, min(status) as status, min(body) as body from public.notes");
check("original letter imported exactly once, as published", row.n === 1 && row.status === "published", row);
check("imported letter includes the signature", row.body.includes("[Your closing line]"), row);

await one("select public.set_participant_passcode('author', '111111')");
await one("select public.set_participant_passcode('janina', '135790')");
r = await as("postgres", null, "select public.set_participant_passcode('janina', '111111')");
check("two people cannot share a passcode", r.error?.includes("passcode_in_use") === true, r);
r = await as("postgres", null, "select public.set_participant_passcode('janina', '12ab')");
check("non-numeric passcode rejected", r.error !== null, r);
r = await as("authenticated", ME, "select public.set_participant_passcode('janina', '999999')");
check("clients cannot set passcodes", r.error !== null, r);
r = await as("authenticated", ME, "select * from public.participant_credentials");
check("participants cannot read passcode hashes", r.error !== null, r);

// ---------------------------------------------------------------- sign-in check
let v = await verify("c1", "135790");
check("Janina's passcode identifies Janina", v.status === "ok" && v.participant_id === JANINA, v);
v = await verify("c1", "111111");
check("author's passcode identifies the author", v.status === "ok" && v.participant_id === ME, v);
v = await verify("c1", "000000");
check("wrong passcode -> invalid, 4 remaining", v.status === "invalid" && v.attempts_remaining === 4, v);
for (let i = 0; i < 4; i++) v = await verify("c1", "000000");
check("5th failure -> locked", v.status === "locked" && v.retry_after_seconds > 290, v);
check("correct passcode refused while locked", (await verify("c1", "135790")).status === "locked");
await one("select public.reset_unlock_lockouts()");
for (let i = 0; i < 20; i++) v = await verify(`rot${i}`, "000000");
check("global limit across rotating clients", v.status === "locked", v);
await one("select public.reset_unlock_lockouts()");

// ---------------------------------------------------------------- participants visibility
r = await as("authenticated", JANINA, "select display_name from public.participants order by display_name");
check("participants see both names", r.rows?.map((x) => x.display_name).join() === "Janina,Jarvey", r);
r = await as("authenticated", STRANGER, "select * from public.participants");
check("signed-in outsider sees no participants", r.error === null && r.rows!.length === 0, r);
r = await as("anon", null, "select * from public.participants");
check("anon cannot read participants", r.error !== null, r);

// ---------------------------------------------------------------- notes
const letterId = (await one("select id from public.notes where source_app_key = 'janina_letter'")).id;
r = await as("authenticated", JANINA, "select title from public.notes");
check("Janina can read the original letter", r.rows?.length === 1, r);

r = await as("authenticated", JANINA,
  "insert into public.notes (title, body, status) values ('Janina draft', 'secret draft', 'draft') returning id, author_id, version");
check("Janina can create a draft; author_id is forced to her", r.rows?.[0]?.author_id === JANINA, r);
const janinaDraft = r.rows![0].id;

r = await as("authenticated", ME, "select id from public.notes where id = $1", [janinaDraft]);
check("author cannot see Janina's draft", r.rows?.length === 0, r);
r = await as("authenticated", ME, "update public.notes set body = 'hijack' where id = $1 returning id", [janinaDraft]);
check("author cannot edit Janina's draft", r.rows?.length === 0, r);

r = await as("authenticated", JANINA,
  `insert into public.notes (title, body, status, author_id) values ('x', 'y', 'draft', '${ME}')`);
check("cannot insert a note as someone else", r.error !== null, r);
r = await as("authenticated", JANINA, "insert into public.notes (title, body, status) values ('Empty', '  ', 'published')");
check("cannot publish an empty note", r.error !== null, r);
r = await as("authenticated", STRANGER, "insert into public.notes (title, body) values ('x', 'y')");
check("outsider cannot create notes", r.error !== null, r);
r = await as("anon", null, "select * from public.notes");
check("anon cannot read notes", r.error !== null, r);

r = await as("authenticated", JANINA,
  "update public.notes set status = 'published', body = 'For you.' where id = $1 and version = 1 returning version, published_at", [janinaDraft]);
check("Janina publishes her note; version bumps", r.rows?.[0]?.version === 2 && r.rows?.[0]?.published_at !== null, r);
r = await as("authenticated", ME, "select title from public.notes where id = $1", [janinaDraft]);
check("author now sees Janina's published note", r.rows?.length === 1, r);

r = await as("authenticated", JANINA,
  "update public.notes set body = 'stale edit' where id = $1 and version = 1 returning id", [janinaDraft]);
check("stale version update changes nothing (conflict detectable)", r.rows?.length === 0, r);
r = await as("authenticated", JANINA, "update public.notes set version = 99 where id = $1", [janinaDraft]);
check("clients cannot set version directly", r.error !== null, r);
r = await as("authenticated", JANINA, "update public.notes set last_activity_at = now() where id = $1", [janinaDraft]);
check("clients cannot set activity timestamps", r.error !== null, r);
r = await as("authenticated", STRANGER, "select * from public.notes");
check("outsider reads zero notes", r.error === null && r.rows!.length === 0, r);

// ---------------------------------------------------------------- replies
const before = (await one("select last_activity_at from public.notes where id = $1", [letterId])).last_activity_at;
r = await as("authenticated", JANINA,
  "insert into public.replies (id, note_id, body) values ('10000000-0000-4000-8000-000000000001', $1, E'Thank you.\\n\\nReally.') returning author_id", [letterId]);
check("Janina replies to the letter as herself", r.rows?.[0]?.author_id === JANINA, r);
r = await as("authenticated", JANINA,
  "insert into public.replies (id, note_id, body) values ('10000000-0000-4000-8000-000000000001', $1, 'dup')", [letterId]);
check("re-sending the same reply id is rejected (no duplicates)", r.error !== null, r);
const after = (await one("select last_activity_at, version from public.notes where id = $1", [letterId]));
check("a reply bumps activity but not the note version",
  new Date(after.last_activity_at) >= new Date(before) && after.version === 1, after);

r = await as("authenticated", ME, "select body, author_id from public.replies where note_id = $1", [letterId]);
check("author reads Janina's reply", r.rows?.length === 1 && r.rows[0].author_id === JANINA, r);
r = await as("authenticated", ME,
  `insert into public.replies (note_id, body, author_id) values ($1, 'as her', '${JANINA}')`, [letterId]);
check("cannot reply as someone else", r.error !== null, r);
r = await as("authenticated", ME, "insert into public.replies (note_id, body) values ($1, '   ')", [letterId]);
check("empty reply rejected", r.error !== null, r);

r = await as("authenticated", ME, "insert into public.notes (title, body) values ('My draft', 'wip') returning id");
const myDraft = r.rows![0].id;
r = await as("authenticated", ME, "insert into public.replies (note_id, body) values ($1, 'hi')", [myDraft]);
check("cannot reply to a draft", r.error !== null, r);
r = await as("authenticated", STRANGER, "insert into public.replies (note_id, body) values ($1, 'hi')", [letterId]);
check("outsider cannot reply", r.error !== null, r);
r = await as("authenticated", STRANGER, "select * from public.replies");
check("outsider reads zero replies", r.error === null && r.rows!.length === 0, r);
r = await as("authenticated", ME, "update public.replies set body = 'edited' returning id");
check("you cannot edit someone else's reply", r.error === null && r.rows!.length === 0, r);
r = await as("authenticated", ME, "delete from public.replies returning id");
check("you cannot delete someone else's reply", r.error === null && r.rows!.length === 0, r);
r = await as("authenticated", JANINA,
  "update public.replies set body = 'Thank you, truly.' where id = '10000000-0000-4000-8000-000000000001' returning body, edited_at");
check("Janina edits her own reply; it's marked edited",
  r.rows?.[0]?.body === "Thank you, truly." && r.rows[0].edited_at !== null, r);
r = await as("authenticated", JANINA,
  "update public.replies set note_id = $1 where id = '10000000-0000-4000-8000-000000000001'", [janinaDraft]);
check("a reply cannot be moved to another entry", r.error !== null, r);
r = await as("authenticated", JANINA,
  "update public.replies set created_at = now() where id = '10000000-0000-4000-8000-000000000001'");
check("a reply's timestamps cannot be set by clients", r.error !== null, r);
r = await as("authenticated", JANINA, "delete from public.notes where id = $1 returning id", [letterId]);
check("only the author can delete an entry", r.rows?.length === 0, r);

// Unpublishing hides the note and its replies from the other person.
await as("authenticated", ME, "update public.notes set status = 'draft' where id = $1", [letterId]);
r = await as("authenticated", JANINA, "select * from public.replies where note_id = $1", [letterId]);
check("replies hidden when parent note goes back to draft", r.rows?.length === 0, r);
await as("authenticated", ME, "update public.notes set status = 'published' where id = $1", [letterId]);

// Recents order follows activity.
await new Promise((res) => setTimeout(res, 15));
await as("authenticated", ME, "insert into public.replies (note_id, body) values ($1, 'newest')", [janinaDraft]);
r = await as("authenticated", JANINA, "select id from public.notes order by last_activity_at desc limit 1");
check("the note with the newest reply is first in Recents", r.rows?.[0]?.id === janinaDraft, r);

// ---------------------------------------------------------------- diary entries
row = await one("select entry_date::text as d, created_at::date::text as c from public.notes where id = $1", [letterId]);
check("existing entries get their creation day as entry_date", row.d === row.c, row);
r = await as("authenticated", JANINA,
  "insert into public.notes (title, body, status, entry_date) values ('Day', 'Text', 'draft', '2026-10-30') returning id, entry_date::text as d, version");
check("an entry can be written for a chosen day", r.rows?.[0]?.d === "2026-10-30", r);
const janinaEntry = r.rows![0].id;
r = await as("authenticated", JANINA,
  "update public.notes set entry_date = '2026-10-29' where id = $1 and version = 1 returning version", [janinaEntry]);
check("changing the day is an edit (version bumps)", r.rows?.[0]?.version === 2, r);

// ---------------------------------------------------------------- photos
const P = (n: number) => `20000000-0000-4000-8000-00000000000${n}`;
const path = (note: string, id: string, ext = "jpg") => `${note}/${id}.${ext}`;
const upload = (user: string, name: string) =>
  as("authenticated", user, "insert into storage.objects (bucket_id, name) values ('diary-images', $1) returning name", [name]);
const addPhoto = (user: string, note: string, id: string, ext = "jpg") =>
  as("authenticated", user, "insert into public.note_images (id, note_id, storage_path) values ($1, $2, $3) returning author_id",
    [id, note, path(note, id, ext)]);
const viewFile = (user: string, name: string) =>
  as("authenticated", user, "select name from storage.objects where name = $1", [name]);

row = await one("select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'diary-images'");
check("photo bucket exists and is private", row?.public === false && Number(row.file_size_limit) === 10485760, row);

// Janina's draft entry with a photo.
r = await upload(JANINA, path(janinaEntry, P(1)));
check("author can upload a photo to her entry", r.error === null && r.rows?.length === 1, r);
r = await addPhoto(JANINA, janinaEntry, P(1));
check("photo row is saved as its author", r.rows?.[0]?.author_id === JANINA, r);
r = await addPhoto(JANINA, janinaEntry, P(1));
check("the same photo id cannot be added twice", r.error !== null, r);

r = await upload(ME, path(janinaEntry, P(2)));
check("cannot upload into someone else's entry", r.error !== null, r);
r = await addPhoto(ME, janinaEntry, P(2));
check("cannot attach a photo to someone else's entry", r.error !== null, r);
r = await upload(JANINA, `${janinaEntry}/../${P(2)}.jpg`);
check("odd file names are refused", r.error !== null, r);
r = await upload(JANINA, path(janinaEntry, P(2), "exe"));
check("only jpg/png/webp names are accepted", r.error !== null, r);
r = await as("authenticated", JANINA,
  "insert into public.note_images (id, note_id, storage_path) values ($1, $2, $3)", [P(2), janinaEntry, path(letterId, P(2))]);
check("a photo row must point inside its own entry's folder", r.error !== null, r);

r = await as("authenticated", ME, "select * from public.note_images where note_id = $1", [janinaEntry]);
check("draft photos are hidden from the other person", r.rows?.length === 0, r);
r = await viewFile(ME, path(janinaEntry, P(1)));
check("draft photo files are hidden from the other person", r.rows?.length === 0, r);
r = await viewFile(JANINA, path(janinaEntry, P(1)));
check("the author can see her own draft photo", r.rows?.length === 1, r);

await as("authenticated", JANINA, "update public.notes set status = 'published' where id = $1", [janinaEntry]);
r = await as("authenticated", ME, "select storage_path from public.note_images where note_id = $1", [janinaEntry]);
check("shared entry photos are visible to the other person", r.rows?.length === 1, r);
r = await viewFile(ME, path(janinaEntry, P(1)));
check("shared photo files can be downloaded by the other person", r.rows?.length === 1, r);
r = await viewFile(STRANGER, path(janinaEntry, P(1)));
check("outsider cannot download photos", r.rows?.length === 0, r);
r = await as("anon", null, "select * from public.note_images");
check("anon cannot read photo rows", r.error !== null, r);
r = await as("authenticated", STRANGER, "select * from public.note_images");
check("outsider reads zero photo rows", r.error === null && r.rows!.length === 0, r);

// Previews ('<photo>.thumb.jpg') follow their photo's rules.
const thumb = (note: string, id: string) => `${note}/${id}.thumb.jpg`;
r = await upload(JANINA, thumb(janinaEntry, P(1)));
check("author can upload a photo's preview", r.error === null && r.rows?.length === 1, r);
r = await upload(ME, thumb(janinaEntry, P(1)));
check("cannot upload a preview into someone else's entry", r.error !== null, r);
r = await upload(JANINA, `${janinaEntry}/${P(1)}.thumb.png`);
check("previews must be .thumb.jpg", r.error !== null, r);
r = await viewFile(ME, thumb(janinaEntry, P(1)));
check("the other person can see a shared photo's preview", r.rows?.length === 1, r);
r = await viewFile(STRANGER, thumb(janinaEntry, P(1)));
check("outsider cannot see previews", r.rows?.length === 0, r);
r = await upload(JANINA, thumb(janinaEntry, P(9)));
r = await viewFile(ME, thumb(janinaEntry, P(9)));
check("a preview without a listed photo stays hidden from the other person", r.rows?.length === 0, r);

await addPhoto(JANINA, janinaEntry, P(2));
await addPhoto(JANINA, janinaEntry, P(3));
r = await addPhoto(JANINA, janinaEntry, P(4));
check("a fourth photo is refused", r.error?.includes("at most 3") === true, r);

r = await as("authenticated", ME, "delete from public.note_images where id = $1 returning id", [P(1)]);
check("the other person cannot remove a photo", r.rows?.length === 0, r);
r = await as("authenticated", ME, "delete from storage.objects where name = $1 returning id", [path(janinaEntry, P(1))]);
check("the other person cannot delete a photo file", r.rows?.length === 0, r);
r = await as("authenticated", JANINA, "update public.note_images set storage_path = storage_path where id = $1", [P(1)]);
check("photo rows cannot be edited", r.error !== null, r);
r = await as("authenticated", JANINA, "delete from public.note_images where id = $1 returning id", [P(1)]);
check("the author can remove a photo", r.rows?.length === 1, r);
r = await as("authenticated", JANINA, "delete from storage.objects where name = $1 returning id", [path(janinaEntry, P(1))]);
check("the author can delete the photo file", r.rows?.length === 1, r);
r = await addPhoto(JANINA, janinaEntry, P(4));
check("after removing one, a new third photo fits", r.error === null, r);

// ---------------------------------------------------------------- likes
r = await as("authenticated", JANINA, "insert into public.note_likes (note_id) values ($1) returning user_id", [letterId]);
check("Janina likes a shared entry as herself", r.rows?.[0]?.user_id === JANINA, r);
r = await as("authenticated", JANINA, "insert into public.note_likes (note_id) values ($1)", [letterId]);
check("the same person cannot like twice", r.error !== null, r);
r = await as("authenticated", JANINA, `insert into public.note_likes (note_id, user_id) values ($1, '${ME}')`, [letterId]);
check("cannot like as someone else", r.error !== null, r);
r = await as("authenticated", ME, "insert into public.note_likes (note_id) values ($1)", [myDraft]);
check("drafts cannot be liked", r.error !== null, r);
r = await as("authenticated", ME, "select user_id from public.note_likes where note_id = $1", [letterId]);
check("the author sees Janina's like", r.rows?.length === 1 && r.rows[0].user_id === JANINA, r);
r = await as("authenticated", STRANGER, "select * from public.note_likes");
check("outsider sees no likes", r.error === null && r.rows!.length === 0, r);
r = await as("authenticated", STRANGER, "insert into public.note_likes (note_id) values ($1)", [letterId]);
check("outsider cannot like", r.error !== null, r);
r = await as("anon", null, "select * from public.note_likes");
check("anon cannot read likes", r.error !== null, r);
r = await as("authenticated", ME, "delete from public.note_likes where note_id = $1 returning user_id", [letterId]);
check("cannot remove someone else's like", r.rows?.length === 0, r);
r = await as("authenticated", JANINA, "delete from public.note_likes where note_id = $1 returning user_id", [letterId]);
check("Janina can unlike", r.rows?.length === 1, r);

// ---------------------------------------------------------------- deleting entries
await as("authenticated", JANINA, "insert into public.note_likes (note_id) values ($1)", [janinaEntry]);
await as("authenticated", ME, "insert into public.note_likes (note_id) values ($1)", [janinaEntry]);
await as("authenticated", ME, "insert into public.replies (note_id, body) values ($1, 'nice')", [janinaEntry]);
r = await upload(JANINA, path(janinaEntry, P(4)));
check("(setup) photo file uploaded", r.error === null, r);

r = await as("authenticated", ME, "delete from public.notes where id = $1 returning id", [janinaEntry]);
check("the other person cannot delete an entry", r.rows?.length === 0, r);
r = await as("authenticated", STRANGER, "delete from public.notes where id = $1 returning id", [janinaEntry]);
check("outsider cannot delete an entry", r.rows?.length === 0 || r.error !== null, r);
r = await as("authenticated", JANINA, "delete from public.notes where id = $1 returning id", [janinaEntry]);
check("the author can delete her entry", r.rows?.length === 1, r);
row = await one(`select (select count(*) from public.replies where note_id = $1)::int as replies,
                        (select count(*) from public.note_images where note_id = $1)::int as photos,
                        (select count(*) from public.note_likes where note_id = $1)::int as likes`, [janinaEntry]);
check("its replies, photo rows and likes go with it", row.replies === 0 && row.photos === 0 && row.likes === 0, row);
r = await as("authenticated", ME, "delete from storage.objects where name = $1 returning id", [path(janinaEntry, P(4))]);
check("the other person cannot delete the leftover file", r.rows?.length === 0, r);
r = await as("authenticated", JANINA, "delete from storage.objects where name = $1 returning id", [path(janinaEntry, P(4))]);
check("the uploader can still delete her file afterwards", r.rows?.length === 1, r);

// ---------------------------------------------------------------- replies: deleting your own
r = await as("authenticated", JANINA,
  "delete from public.replies where id = '10000000-0000-4000-8000-000000000001' returning id");
check("Janina deletes her own reply", r.rows?.length === 1, r);

// ---------------------------------------------------------------- app releases
await one("insert into public.app_releases (version_code, version_name, apk_url) values (2, '1.0.1', 'https://example.com/a.apk')");
r = await as("authenticated", JANINA, "select version_code, apk_url from public.app_releases");
check("participants can read releases", r.rows?.length === 1 && r.rows[0].version_code === 2, r);
r = await as("authenticated", STRANGER, "select * from public.app_releases");
check("outsider reads zero releases", r.error === null && r.rows!.length === 0, r);
r = await as("anon", null, "select * from public.app_releases");
check("anon cannot read releases", r.error !== null, r);
r = await as("authenticated", ME, "insert into public.app_releases (version_code, apk_url) values (3, 'https://x.y/z.apk')");
check("the app cannot add releases", r.error !== null, r);
r = await as("postgres", null, "insert into public.app_releases (version_code, apk_url) values (4, 'http://x.y/z.apk')");
check("download links must be https", r.error !== null, r);

console.log(failures === 0 ? "\nALL SQL CHECKS PASSED" : `\n${failures} SQL CHECK(S) FAILED`);
Deno.exit(failures === 0 ? 0 : 1);
