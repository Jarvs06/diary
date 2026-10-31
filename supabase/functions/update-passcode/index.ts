// POST /functions/v1/update-passcode        (owner only — not used by the app)
// Header: x-admin-secret: <ADMIN_SECRET>
// Body:   { "participant": "author" | "janina",
//           "new_passcode": "4–12 digits",
//           "display_name": "Jarvey" }       -- required the first time
//
// 200 { "ok": true, "participant_id": "..." }
// 400 { "error": "bad_request" }
// 401 { "error": "unauthorized" }
// 409 { "error": "passcode_in_use" }        -- the other person already uses it
//
// The first call for a participant creates their Supabase Auth account (no
// email is ever sent; the address is a placeholder) and their participant row.
// Creating the 'author' also imports the original letter as their first note.

import { adminSecret, APP_KEY, ConfigError, serviceClient } from "../_shared/config.ts";
import { errorResponse, json, logInternal, preflight, readJson } from "../_shared/http.ts";
import { secretsEqual } from "../_shared/crypto.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.58.0";

const KEYS = ["author", "janina"] as const;
type ParticipantKey = typeof KEYS[number];

/** Placeholder login address. example.com is reserved, so nothing is ever delivered. */
const emailFor = (key: ParticipantKey) => `${key}.secret-diary@example.com`;

async function findOrCreateAuthUser(admin: SupabaseClient, key: ParticipantKey): Promise<string> {
  const email = emailFor(key);
  const created = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    // Never used: sign-in goes through the passcode, not a password.
    password: crypto.randomUUID() + crypto.randomUUID(),
    user_metadata: { participant_key: key },
  });
  if (created.data.user) return created.data.user.id;

  // Already exists (e.g. a re-run): look it up.
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 });
    if (error) throw new Error(`listUsers failed: ${error.code}`);
    const match = data.users.find((u) => u.email === email);
    if (match) return match.id;
    if (data.users.length < 100) break;
  }
  throw new Error(`createUser failed: ${created.error?.code ?? "unknown"}`);
}

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;

  try {
    const provided = req.headers.get("x-admin-secret") ?? "";
    if (!(await secretsEqual(provided, adminSecret()))) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      return errorResponse(401, "unauthorized");
    }

    const body = await readJson(req);
    const key = body?.participant as ParticipantKey;
    const newPasscode = body?.new_passcode;
    const displayName = typeof body?.display_name === "string" ? body.display_name.trim() : "";
    if (
      !KEYS.includes(key) ||
      typeof newPasscode !== "string" || !/^[0-9]{4,12}$/.test(newPasscode) ||
      displayName.length > 60
    ) {
      return errorResponse(400, "bad_request");
    }

    const admin = serviceClient();
    const { data: existing, error: lookupError } = await admin
      .from("participants")
      .select("id, display_name")
      .eq("participant_key", key)
      .maybeSingle();
    if (lookupError) throw new Error(`participants lookup failed: ${lookupError.code}`);

    let participantId = existing?.id as string | undefined;
    if (!participantId || displayName) {
      if (!participantId && !displayName) return errorResponse(400, "bad_request");
      participantId ??= await findOrCreateAuthUser(admin, key);
      const { error } = await admin.rpc("register_participant", {
        p_user_id: participantId,
        p_participant_key: key,
        p_display_name: displayName || existing!.display_name,
      });
      if (error) throw new Error(`register_participant failed: ${error.code}`);
    }

    if (key === "author") {
      const { error } = await admin.rpc("import_original_letter", { p_app_key: APP_KEY });
      if (error) throw new Error(`import_original_letter failed: ${error.code}`);
    }

    const { error } = await admin.rpc("set_participant_passcode", {
      p_participant_key: key,
      p_passcode: newPasscode,
    });
    if (error) {
      if (error.message?.includes("passcode_in_use")) return errorResponse(409, "passcode_in_use");
      throw new Error(`set_participant_passcode failed: ${error.code}`);
    }

    return json(200, { ok: true, participant_id: participantId });
  } catch (e) {
    logInternal("update-passcode", e);
    return errorResponse(e instanceof ConfigError ? 503 : 500, "server_error");
  }
});
