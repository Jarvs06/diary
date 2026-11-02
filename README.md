# Our Diary — a private space for two

A Flutter Android app for exactly two people, Jarvey and Janina. Each signs in
with their own numeric passcode, then you can both keep diary entries (each for
a day, with up to three photos), read each other's, and reply underneath in a
conversation, and like each other's entries. Everything lives in Supabase.

On the phone the app is installed as **Threads** with a Threads-style icon
(see `android/app/src/main/AndroidManifest.xml` and `res/mipmap-*`), so it
doesn't stand out on the home screen. Keep it to your two phones: the name and
logo are Meta's trademarks, so it can't go on Google Play.

```
lib/
  main.dart                  config check, Supabase init (secure session storage), wiring
  app.dart                   MaterialApp, start gate, config-error screen
  core/
    auth/auth_session.dart   who is signed in; Keystore-backed session storage
    config/                  build-time config (refuses secret keys)
    errors/app_failure.dart  every user-facing failure + gentle message
    network/backend_client.dart  Edge Function wrapper + error mapping
    sync/sync_service.dart   Supabase Realtime change notifications
    theme/  utils/  widgets/
  features/
    access/        passcode screen + sign-in
    participants/  the two people
    notes/         feed, profile, entry page, composer (date, drafts, posting, conflicts)
    photos/        picking, uploading and showing up to 3 photos per entry
    replies/       replies under an entry and the reply bar
supabase/
  migrations/                schema, RLS, grants, triggers, passcode + rate limiting
  seed.sql                   placeholder app_content row
  functions/
    sign-in/                 passcode → Supabase Auth session for that person
    update-passcode/         owner-only: create accounts, set/change passcodes
  tests/migrations_test.ts   RLS + database tests in PGlite (no Docker)
test/                        Flutter unit + widget tests
```

## How it works

```
Passcode ──► sign-in function ──► verify_participant_passcode()   bcrypt + rate limit
                │                   (which of the two people is this?)
                └─► issues a normal Supabase Auth session for that person
App ──(session)──► notes / replies / likes ── protected by RLS on auth.uid()
App ──(session)──► diary-images bucket ── Storage policies follow the entry's RLS
App ◄── Realtime (same RLS) ── changes made on the other phone
```

- **Two real accounts, no registration.** You and Janina are Supabase Auth
  users with placeholder emails (`author.secret-diary@example.com`,
  `janina.secret-diary@example.com`). No email is ever sent. The passcode is
  the only thing either of you types.
- **The passcode identifies the person**, so the two passcodes must differ
  (the server refuses a duplicate).
- **Sessions** are stored in the Android Keystore-backed secure storage and
  refresh automatically. **Lock** signs out on that phone.
- **Entries** live in `notes`, each with an `entry_date` (the day it's about,
  chosen in the editor; today by default). Without a title, the day is the heading.
- **Photos**: up to 3 per entry, stored privately in the `diary-images`
  Storage bucket as `<entry id>/<photo id>.jpg|png|webp` and listed in
  `note_images`. The app resizes them to at most 2048 px before uploading.
  Nothing is public: the app downloads each photo with the signed-in session.
- **The original confession letter** was copied once into `notes` as your
  first entry. Edit it from the app now (the pencil icon), not in `app_content`.
  `app_content` still holds the welcome-screen text.

### Security rules (enforced in Postgres, not the app)

| Who | Can |
|---|---|
| Anyone with only the publishable key | read the welcome text — nothing else |
| A signed-in account that isn't one of the two | nothing (RLS returns zero rows) |
| Either participant | read both names, all **published** notes, and replies on them |
| The author of a note | read their own **drafts**; create, edit and **delete** their own notes |
| Either participant | reply to and **like** published notes, as themselves only |
| Either participant | see the photos of any entry they can see |
| The author of an entry | add / remove its photos (at most 3, ≤ 10 MB, jpg/png/webp) |

Also:
- `author_id`, timestamps and `version` can't be set by the app (column-level
  grants + triggers); the server fills them from the session.
- Only the author can delete an entry; its replies, likes and photo rows go
  with it, and the app then removes the photo files. You can edit or delete
  only your own replies (only their text can change, and an edit is marked).
  One like per person per entry; you can only remove your own.
- `app_releases` (update notices) is readable by the two participants only and
  can't be written from the app.
- If a note goes back to draft, its replies are hidden from the other person too.
- Passcode hashes are in `participant_credentials`, which no client can read.
- Publishing an empty note is rejected by a check constraint.
- The 3-photo limit is a database trigger (it locks the entry, so two uploads
  at once can't both become the third). Photo ids come from the phone, so a
  retried upload never adds a photo twice.
- A new entry shared with photos stays a draft until every photo has
  uploaded; if one fails, the editor keeps it and **Share** retries.
- Edits carry the version they started from; a stale edit changes nothing and
  the app offers **Load latest** or **Keep mine** instead of overwriting.
- Replies and new notes get their id on the phone, so a retried or double-tapped
  Send can never create a duplicate.

Rate limiting on sign-in (unchanged from before): per device 5 wrong tries /
15 min → 5-minute pause, doubling; globally 20 wrong tries / hour → 15-minute
pause, doubling. `select public.reset_unlock_lockouts();` clears them.

### Limitations

- 6-digit passcodes are short. The lockouts make random guessing take decades,
  but someone who knows a meaningful date can guess it directly. A passcode that
  looks like a date is easier to guess.
- Changing a passcode does **not** sign out phones that are already signed in.
  To force that, also tap **Lock** on that phone (or delete the user's sessions
  in Dashboard → Authentication → Users → … → Sign out user).
- Entries and photos aren't end-to-end encrypted: anyone with access to your
  Supabase project can see them in the Dashboard.
- Removing a photo deletes its row first, then its file. If the file delete
  fails, an orphan file is left behind that nobody can see from the app.

---

## 1. Supabase setup

Already done for the **Secret Diary** project. To set up a fresh project:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push --include-seed            # schema, RLS, Realtime, photo bucket, placeholder row

umask 077 && {
  echo "UNLOCK_TOKEN_SECRET=$(openssl rand -base64 48 | tr -d '\n')"
  echo "ADMIN_SECRET=$(openssl rand -base64 36 | tr -d '\n')"
  echo "APP_KEY=janina_letter"
} > supabase/functions/.env && supabase secrets set --env-file supabase/functions/.env

supabase functions deploy sign-in update-passcode
```

(`UNLOCK_TOKEN_SECRET` is now only used as a salt for the rate limiter.)

### Recommended Dashboard setting

**Authentication → Sign In / Providers → turn off "Allow new users to sign up".**
Nobody can use the app without being one of the two participants anyway, but
this stops strangers creating empty accounts.

Realtime needs no Dashboard change: the migrations add `notes`, `replies`,
`note_images` and `note_likes` to the `supabase_realtime` publication. The `diary-images`
bucket and its policies are created by the migration too (Dashboard →
Storage shows it as a private bucket).

## 2. Accounts and passcodes

Both accounts are created and passcodes changed with the `update-passcode`
function. It reads the admin secret from `supabase/functions/.env`:

```bash
ADMIN="$(grep ^ADMIN_SECRET= supabase/functions/.env | cut -d= -f2-)"
URL=https://xqlhfxnswojlxetutevt.supabase.co/functions/v1/update-passcode

# Your passcode (first time also creates your account; display_name optional later)
curl -sS -X POST "$URL" -H "x-admin-secret: $ADMIN" -H "Content-Type: application/json" \
  -d '{"participant":"author","display_name":"Jarvey","new_passcode":"YOUR-DIGITS"}'

# Janina's passcode
curl -sS -X POST "$URL" -H "x-admin-secret: $ADMIN" -H "Content-Type: application/json" \
  -d '{"participant":"janina","new_passcode":"HER-DIGITS"}'
```

Passcodes are 4–12 digits. Replies: `{"ok":true,...}`, or
`{"error":"passcode_in_use"}` if it's the other person's passcode.

Rename someone: edit `display_name` in Table Editor → `participants`.

## 3. Run and build

```bash
cp .env.example .env    # SUPABASE_URL + SUPABASE_PUBLISHABLE_KEY (public values)
flutter run --dart-define-from-file=.env

# Signed release (needs android/key.properties, see below)
flutter build apk --release --split-per-abi --dart-define-from-file=.env
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  (send this one)
```

Release signing uses `android/key.properties` (git-ignored) pointing at
`~/letter-release.jks`. Keep both the keystore and its password: every future
APK must be signed with the same key to install over the old one.

### Handing out an update

1. Raise the build number in `pubspec.yaml` (`version: 1.0.1+2`: the number
   after `+` must go up every release) and build the APK as above.
2. Upload the APK somewhere with an https link (e.g. a private Google Drive
   file shared with "anyone with the link").
3. In Dashboard → Table Editor → `app_releases`, add a row: `version_code` = the
   new build number, `version_name` = e.g. `1.0.1`, `apk_url` = the link.

Phones on an older build then see "Version 1.0.1 is available · Update" at the
top of the feed.

### Keeping the project awake

Free Supabase projects pause after about a week without requests. While at
least one phone is signed in, its background check (about every 15 minutes)
keeps the project active. If you both lock the app for a long time, un-pause
it from the Dashboard.

## 3b. Web version (GitHub Pages, for iPhone)

The same app also builds as a website, so either of you can read and write
from an iPhone or a computer. It uses the same accounts, passcodes and data.

```bash
flutter build web --release --wasm --dart-define-from-file=.env   # → build/web
```

Differences from the Android app:
- It's called **Our Diary** with the Diary logo, not Threads. A public website
  that looks like Threads with a login box would look like phishing and could
  be flagged or taken down.
- No phone notifications or background checks (browsers don't offer them
  without a push server). Instead of the fingerprint lock, the website asks for
  your passcode again when it opens and after 2 minutes away; the server checks
  it with the usual wrong-try limits, and only your own passcode unlocks it.
- Built with Flutter's WebAssembly renderer for smoother scrolling (browsers
  that can't run it get the regular JavaScript version automatically), and
  without the bottom bar's blur, which made Safari stutter. Safari limits web
  pages to 60 fps, so ProMotion's 120 Hz is only available to native apps.
- Photos from an iPhone: pick them as usual. Safari hands the app JPEG copies;
  they're resized to at most 2048 px before uploading.
- On an iPhone, open the site in Safari → Share → **Add to Home Screen** to get
  an app-like icon.

**Publishing with GitHub Pages** (`.github/workflows/deploy-web.yml`):
1. Create a GitHub repository and push this project to its `main` branch.
   `.env`, `supabase/functions/.env`, the keystore and the original photos in
   the project root are git-ignored and stay on your computer.
2. Repository → Settings → Pages → Source: **GitHub Actions**.
3. Settings → Secrets and variables → Actions → **Variables**: add
   `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `APP_KEY` with the same values
   as `.env` (they're public by design; RLS protects the data).
4. Every push to `main` runs the tests, builds the site and publishes it at
   `https://<your-username>.github.io/<repository>/`.

Note that the published site's files (including the two profile photos in
`assets/avatars/`) can be downloaded by anyone who has the link, and a public
repository shows its code to everyone. The diary itself stays protected by the
passcodes and the database rules. GitHub Pages from a private repository needs
a paid GitHub plan.

## 4. Using it

The layout is minimal and Threads-like. The theme follows the phone: black in
dark mode; in light mode cream paper (#FEFAF3) with carnation pink (#FFA6C9)
accents. There's a feed and a
floating bottom bar with **Home · + · Profile**. The bar is slightly
see-through and shrinks while you scroll down; it comes back when you scroll
up. Fonts (bundled, SIL Open Font License): Google Sans for text, Google Sans
Flex for names and headings, Momo Signature for the "Diary" logo. Each person's
avatar has its own colour, since both names start with J.

- **Feed (Home):** both people's shared entries, newest first by the entry's
  date (for a backdated entry, the day Jarvey picked), with name, that date, text, photos (swipe sideways), likes and replies. Long text is
  cut to 6 lines (2 when there are photos) with **See more**. Pull down to
  refresh; tap Home again to jump to the top.
- **Read an entry:** tap it to open its page with all replies underneath.
  Tap a photo to see it full screen (swipe between them, pinch to zoom).
- **Like:** tap the heart (again to unlike). Both of you see the count.
- **Reply:** tap the speech bubble (or open the entry) and type in "Reply to …".
  If sending fails, your text stays in the box and it says *Not sent*. ··· on
  your own reply → Edit / Delete.
- **Write:** **+** opens the composer as a sheet over the feed → optional title
  → text → photo or camera icon (up to 3) → (Jarvey only) tap the date beside
  your name to change the day → **Post** (both of you see it) or **Save draft** (only you).
  Cancel, back, or tapping outside with unsaved work asks: Save draft /
  Discard / Keep writing. A new entry's text is also kept on the phone as you
  type, so it's still there if the app is closed before you post.
- **New since last time:** the other person's entries posted since you last
  opened the feed have a small dot until you open them.
- **Calendar:** the calendar icon at the top of the feed shows a month with a
  dot on every day that has entries; tap a day to list them. On a day that has
  entries from earlier years, an **On this day** card appears in the feed.
- **Offline:** without a connection the feed shows the copy saved on the phone
  (newest 100 entries, without photos) with a notice.
- **Your entries and drafts:** Profile → **Entries** / **Drafts**. The header
  scrolls away as you read; pull down to refresh. Tap a draft to keep writing
  it. **Lock** signs out on this phone.
- **Edit or delete your own entry:** ··· on the post → Edit / Delete. Deleting
  asks first and removes it, its photos and its replies for both of you.
- **Sync:** the other phone updates within a second or two via Realtime, and
  also whenever the app is reopened or refreshed.
- **Notifications:** when the other person shares an entry, replies, or likes
  one of your entries, you get a phone notification ("Janina shared a new
  post", "Janina replied", "Janina liked your post"); tapping it opens the
  entry.
  With the app in the background it arrives within a second or two; when the
  app is fully closed, Android checks about every 15 minutes (WorkManager, no
  Firebase). The lock screen only shows that there's something new, not the
  text. Your own entries and anything you've already seen on screen are never
  announced. After **Lock**, the phone stops checking until you log in again.
  On phones that stop background apps to save battery, Profile shows **Allow
  notifications in the background**.
- **Export (Jarvey only):** Profile → **Export diary** makes one `.zip` with
  `diary.html` (open it in any browser to read everything), `diary.json` (all
  the data) and the full photos, then opens the share sheet so you can save it
  to Files or Google Drive. Supabase's free plan has no backups, so export now
  and then.
- **Photo previews:** each photo is also saved as a small preview (at most
  900 px); the feed shows previews and the full photo loads when you open it.
  Photos added before previews existed keep using the full image.
- **App lock:** if the phone has a screen lock, the app asks for it
  (fingerprint, face, PIN or pattern) when it opens and when you come back
  after 2 minutes away. The diary is also hidden in the recent-apps preview,
  and screenshots of the app are blocked.

Rendering: the app draws with OpenGL (Impeller is turned off in the manifest)
because Impeller's Vulkan backend froze on the emulator and can on some older
phones.

## 5. Tests

```bash
flutter test                                          # 133 unit + widget tests
deno test supabase/functions/_shared/crypto_test.ts   # helper crypto
deno run -A supabase/tests/migrations_test.ts .       # 108 RLS / database / storage checks
```

The database tests run the real migrations in PGlite (Postgres in WebAssembly)
with Supabase's `auth.uid()` and the `storage` tables simulated, and check each rule above as Jarvey, as
Janina, as an outside signed-in account, and as `anon`.

