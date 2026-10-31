// POST /functions/v1/sign-in
// Body: { "passcode": "135790" }
//
// 200 { "access_token", "refresh_token", "expires_at", "participant_id" }
// 401 { "error": "invalid_passcode", "attempts_remaining": n }
// 429 { "error": "too_many_attempts", "retry_after_seconds": n }
// 503 { "error": "not_ready" }        -- no passcodes configured yet
//
// Each person has their own passcode, which both identifies and authenticates
// them. On success this issues a normal Supabase Auth session for that person
// (via a single-use magic-link token that is generated and redeemed here, never
// emailed), so every later request is checked by RLS as that user.

import { ConfigError, serviceClient, unlockTokenSecret } from "../_shared/config.ts";
import { errorResponse, json, logInternal, preflight, readJson } from "../_shared/http.ts";
import { sha256Hex } from "../_shared/crypto.ts";

function clientIp(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;

  const body = await readJson(req);
  const passcode = body?.passcode;
  if (typeof passcode !== "string" || !/^[0-9]{1,12}$/.test(passcode)) {
    return errorResponse(400, "bad_request");
  }

  try {
    const admin = serviceClient();
    // Store a salted hash of the IP, not the IP itself.
    const clientKey = await sha256Hex(`${unlockTokenSecret()}:${clientIp(req)}`);

    const { data, error } = await admin.rpc("verify_participant_passcode", {
      p_client_key: clientKey,
      p_passcode: passcode,
    });
    if (error) throw new Error(`verify_participant_passcode failed: ${error.code}`);

    switch (data?.status) {
      case "ok":
        break;
      case "invalid":
        return errorResponse(401, "invalid_passcode", {
          attempts_remaining: data.attempts_remaining,
        });
      case "locked":
        return errorResponse(429, "too_many_attempts", {
          retry_after_seconds: data.retry_after_seconds,
        });
      case "not_ready":
        return errorResponse(503, "not_ready");
      default:
        throw new Error("unexpected verify status");
    }

    const participantId: string = data.participant_id;
    const { data: user, error: userError } = await admin.auth.admin.getUserById(participantId);
    if (userError || !user.user?.email) throw new Error("participant auth user missing");

    const { data: link, error: linkError } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: user.user.email,
    });
    if (linkError || !link.properties?.hashed_token) {
      throw new Error(`generateLink failed: ${linkError?.code ?? "no token"}`);
    }

    const { data: verified, error: otpError } = await serviceClient().auth.verifyOtp({
      type: "magiclink",
      token_hash: link.properties.hashed_token,
    });
    const session = verified?.session;
    if (otpError || !session) throw new Error(`verifyOtp failed: ${otpError?.code ?? "no session"}`);

    return json(200, {
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      expires_at: session.expires_at,
      participant_id: participantId,
    });
  } catch (e) {
    logInternal("sign-in", e);
    return errorResponse(e instanceof ConfigError ? 503 : 500, "server_error");
  }
});
