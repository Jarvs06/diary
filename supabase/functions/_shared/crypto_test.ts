// Run with:  deno test supabase/functions/_shared/crypto_test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import { secretsEqual, sha256Hex } from "./crypto.ts";

Deno.test("secretsEqual compares exactly", async () => {
  assert(await secretsEqual("same-value", "same-value"));
  assert(!(await secretsEqual("same-value", "same-valuf")));
  assert(!(await secretsEqual("short", "a-much-longer-value")));
  assert(!(await secretsEqual("", "x")));
});

Deno.test("sha256Hex produces a stable lowercase hex digest", async () => {
  assertEquals(
    await sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});
