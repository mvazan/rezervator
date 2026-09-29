import { assertEquals } from "jsr:@std/assert@1";
import { isMemberOf } from "./membership.ts";

const profile = (status: string, role: string, tenant = "t1") => ({
  status, role, tenant_id: tenant,
});

Deno.test("isMemberOf: an approved player or admin of the alley", () => {
  assertEquals(isMemberOf(profile("approved", "player"), "t1"), true);
  assertEquals(isMemberOf(profile("approved", "admin"), "t1"), true);
});

Deno.test("isMemberOf: the kiosk, a pending account, another alley or no profile is not", () => {
  assertEquals(isMemberOf(profile("approved", "kiosk"), "t1"), false);
  assertEquals(isMemberOf(profile("pending", "player"), "t1"), false);
  assertEquals(isMemberOf(profile("approved", "player", "t2"), "t1"), false);
  assertEquals(isMemberOf(null, "t1"), false);
  assertEquals(isMemberOf(undefined, "t1"), false);
});
