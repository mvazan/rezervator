// regnum-lookup — registration numbers of players, from the ČKA member
// register (evidence.kuzelky.cz), remembered in the database so a number is
// looked up once.
//
// Two calls, both by a signed-in member of an alley:
//
//   { mode: "match", match_id, league?: true }
//       The Zápis of a match: the number of every player on its sheet, as
//       { regnums: { "<player name>": "<number>" } } — found ones only. The
//       names are read from the match as the CALLER sees it (RLS), so the
//       function answers for the players of a match the caller may open, never
//       for a name the caller makes up.
//
//   { mode: "profiles" }
//       The numbers of the caller's alley's players that have none yet,
//       written to `profiles.regnum`. { filled, more }: `more` says the budget
//       ran out before every missing number was asked about — call again.
//
// What the register answered is kept in `player_regnums` (found forever, none
// / ambiguous for a week); the register itself is asked at most BUDGET times
// per call, one name at a time. The register's rows carry personal data far
// beyond a number — see _shared/regnum.ts: only name, club and number are read.
//
// Deployed WITHOUT --no-verify-jwt, like kiosk-password: the app calls it
// through functions.invoke and the platform checks the JWT first; inside,
// auth.getUser() rejects a bare anon key.

import { createClient } from "@supabase/supabase-js";

import { foldName, resolveRegnum } from "../_shared/regnum.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

const admin = createClient(
  SUPABASE_URL,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

/** Questions to the register per call. */
const BUDGET = 25;
/** Pause between two questions: the register is somebody's small site. */
const PAUSE_MS = 300;
/** A name the register did not give a number for is asked again after this. */
const RETRY_AFTER_MS = 7 * 24 * 3600e3;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

type Ask = { name: string; club: string };

/** The remembered answers and the new ones for [asks] (found numbers by
 * `foldName(name)|foldName(club)`), asking the register for at most [budget]
 * of them. `more`: some ask was left for lack of budget. */
async function resolveAll(
  asks: Ask[],
  budget: number,
): Promise<{ found: Map<string, string>; more: boolean }> {
  const key = (a: Ask) => `${foldName(a.name)}|${foldName(a.club)}`;
  const unique = new Map<string, Ask>();
  for (const a of asks) {
    // A single word cannot be told from anybody: not worth a question.
    if (foldName(a.name).includes(" ")) unique.set(key(a), a);
  }
  const found = new Map<string, string>();
  if (unique.size === 0) return { found, more: false };

  const { data: cached, error } = await admin
    .from("player_regnums")
    .select("name_key, club_key, regnum, status, looked_up_at")
    .in("name_key", [...new Set([...unique.values()].map((a) => foldName(a.name)))]);
  if (error) throw error;
  const known = new Map(
    (cached ?? []).map((r) => [`${r.name_key}|${r.club_key}`, r]),
  );

  let asked = 0;
  let more = false;
  for (const [k, ask] of unique) {
    const row = known.get(k);
    if (row?.status === "found") {
      found.set(k, row.regnum as string);
      continue;
    }
    if (row && Date.now() - Date.parse(row.looked_up_at) < RETRY_AFTER_MS) {
      continue;
    }
    if (asked >= budget) {
      more = true;
      continue;
    }
    if (asked > 0) await new Promise((r) => setTimeout(r, PAUSE_MS));
    asked++;
    try {
      const answer = await resolveRegnum(ask.name, ask.club);
      const { error: saveError } = await admin.from("player_regnums").upsert({
        name_key: foldName(ask.name),
        club_key: foldName(ask.club),
        regnum: answer.status === "found" ? answer.regnum : null,
        status: answer.status,
        looked_up_at: new Date().toISOString(),
      });
      if (saveError) console.error("regnum-lookup: save failed:", saveError.message);
      if (answer.status === "found") found.set(k, answer.regnum);
    } catch (e) {
      // The register is down or changed: nothing is remembered, the next
      // call tries again.
      console.warn("regnum-lookup: register failed:", (e as Error).message);
    }
  }
  return { found, more };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) return json({ error: "unauthorized" }, 401);

    const asUser = createClient(
      SUPABASE_URL,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authorization } } },
    );
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);

    const body = await request.json().catch(() => ({}));

    if (body?.mode === "match") {
      const matchId = typeof body.match_id === "string" ? body.match_id : null;
      if (!matchId) return json({ error: "missing_match_id" }, 400);
      const league = body.league === true;

      // As the caller: RLS shows a match of the caller's alley and nothing else.
      const { data: match } = await asUser
        .from(league ? "league_matches" : "priority_slots")
        .select("home_team, away_team")
        .eq("id", matchId)
        .maybeSingle();
      if (!match) return json({ error: "not_found" }, 404);
      const { data: players, error } = await asUser
        .from(league ? "league_player_results" : "match_player_results")
        .select("side, player_name")
        .eq("match_id", matchId);
      if (error) throw error;

      const asks: Ask[] = (players ?? []).map((p) => ({
        name: p.player_name as string,
        club: (p.side === "home" ? match.home_team : match.away_team) as string,
      }));
      const { found, more } = await resolveAll(asks, BUDGET);
      const regnums: Record<string, string> = {};
      for (const a of asks) {
        const number = found.get(`${foldName(a.name)}|${foldName(a.club)}`);
        if (number) regnums[a.name] = number;
      }
      return json({ regnums, more });
    }

    if (body?.mode === "profiles") {
      const { data: tenantId } = await asUser.rpc("current_tenant_id");
      if (typeof tenantId !== "string") return json({ error: "not_allowed" }, 403);
      const { data: members, error } = await admin
        .from("profiles")
        .select("id, display_name, club_id")
        .eq("tenant_id", tenantId)
        .eq("status", "approved")
        .neq("role", "kiosk")
        .eq("placeholder", false)
        .is("regnum", null)
        .limit(200);
      if (error) throw error;
      if (!members || members.length === 0) return json({ filled: 0, more: false });

      const clubIds = [...new Set(members.map((m) => m.club_id).filter(Boolean))];
      const clubs = new Map<string, string>();
      if (clubIds.length > 0) {
        const { data } = await admin
          .from("clubs")
          .select("id, name, site_name")
          .in("id", clubIds);
        for (const c of data ?? []) clubs.set(c.id, c.site_name ?? c.name);
      }
      const asks: Ask[] = members.map((m) => ({
        name: m.display_name as string,
        club: m.club_id ? clubs.get(m.club_id) ?? "" : "",
      }));
      const { found, more } = await resolveAll(asks, BUDGET);

      let filled = 0;
      for (const [i, m] of members.entries()) {
        const number = found.get(
          `${foldName(asks[i].name)}|${foldName(asks[i].club)}`,
        );
        if (!number) continue;
        const { error: updateError } = await admin
          .from("profiles")
          .update({ regnum: number })
          .eq("id", m.id)
          .is("regnum", null);
        if (updateError) {
          console.error("regnum-lookup: profile update failed:", updateError.message);
        } else {
          filled++;
        }
      }
      return json({ filled, more });
    }

    return json({ error: "bad_mode" }, 400);
  } catch (error) {
    console.error("regnum-lookup failed:", error);
    return json({ error: "internal" }, 500);
  }
});
