// Who still counts as a member of an alley — 0051's read rule, applied in
// Deno where the service role bypasses the RLS that says it: the react
// function (mayReact) and notify's reaction branch share this one
// predicate.

/// A profile's standing as `profiles` stores it: `status`, `role` and the
/// alley it is in now (`tenant_id`).
export type Membership = { status: string; role: string; tenant_id: string };

/// Whether [profile] is an approved non-kiosk member of [tenantId] — the
/// rule behind can_read_message and message_recipients_update_own (0051).
/// An account later set as the kiosk, back to pending or moved to another
/// alley is not: it reads, reacts to and hears about nothing there any
/// more. A missing profile is no member.
export function isMemberOf(
  profile: Membership | null | undefined,
  tenantId: string,
): boolean {
  return profile != null && profile.status === "approved" &&
    profile.role !== "kiosk" && profile.tenant_id === tenantId;
}
