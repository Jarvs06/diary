import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.58.0";

/** The content row this deployment serves. Override with the APP_KEY secret. */
export const APP_KEY = Deno.env.get("APP_KEY") ?? "janina_letter";

export class ConfigError extends Error {}

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new ConfigError(`Missing secret ${name}`);
  return value;
}

/** Salt for hashing client IPs in the rate limiter (>= 32 chars). */
export function unlockTokenSecret(): string {
  const secret = required("UNLOCK_TOKEN_SECRET");
  if (secret.length < 32) throw new ConfigError("UNLOCK_TOKEN_SECRET is too short");
  return secret;
}

/** Shared secret required by the update-passcode function. */
export function adminSecret(): string {
  const secret = required("ADMIN_SECRET");
  if (secret.length < 24) throw new ConfigError("ADMIN_SECRET is too short");
  return secret;
}

/**
 * Server-side client with service-role privileges. SUPABASE_URL and
 * SUPABASE_SERVICE_ROLE_KEY are injected automatically by Supabase; they exist
 * only inside the Edge Runtime and never reach the mobile app.
 */
export function serviceClient(): SupabaseClient {
  return createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
