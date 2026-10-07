// regnum-lookup — registration numbers of players, from the ČKA member
// register (evidence.kuzelky.cz), remembered in the database so a number is
// looked up once. Who is who is the hard part — see _shared/regnum.ts: a
// match's player is checked against his page on the results service (club and
// age), a profile is filled by itself only when its club leaves one person,
// and otherwise the player picks himself.
//
// Calls, all by a signed-in member of an alley:
//
//   { mode: "match", match_id, league?: true }
//       The Zápis of a match: { regnums: { "<player slug>": "<number>" },
//       more } for its players that are known by a results-service slug,
//       found ones only. The players are read from the match as the CALLER
//       sees it (RLS), so the function answers for a match the caller may
//       open, never for a name the caller makes up. Cached per slug.
//
//   { mode: "profiles" }
//       The alley's approved, non-kiosk, non-placeholder players with no
//       number that were not looked for in the last week (`regnum_checked_at`): those the club leaves one person for get it in
//       `profiles.regnum` — except a name two profiles of the alley bear (a
//       parent and a child): those choose themselves. { filled, more }:
//       `more` says the budget ran out.
//
//   { mode: "profile_candidates" }
//       The caller's OWN profile, when it has no number: the people of that
//       name in the register as { candidates: [{ id, club, category, age }] }
//       — no number, no birth date: the player recognises himself by club and
//       age category („muži, ženy“). `age` is always null since the register
//       stopped publishing ages (October 2026); it stays for older apps.
//
//   { mode: "profile_confirm", candidate_id }
//       The caller says which candidate he is: the number goes to his own
//       profile — { regnum }. The row is looked up again by name, so only a
//       real candidate of the caller's own name is accepted; a number another
//       player of the alley already has is refused (409 regnum_taken).
//
// The register is asked at most BUDGET times per call, one name at a time. Its
// rows carry personal data beyond a number: only id, name, club, age category,
// state and number are read, and only club and category leave this function.
//
// Deployed WITHOUT --no-verify-jwt, like kiosk-password: the app calls it
// through functions.invoke and the platform checks the JWT first; inside,
// auth.getUser() rejects a bare anon key.

import { createClient } from "@supabase/supabase-js";

import {
  foldName,
  isSiteSlug,
  named,
  resolveProfile,
  resolveSitePlayer,
  searchRegister,
  sharedNames,
} from "../_shared/regnum.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

const admin = createClient(
  SUPABASE_URL,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

/** Questions to the sites per call. */
const BUDGET = 25;
/** Pause between two questions: both sites are somebody's small servers. */
const PAUSE_MS = 300;
/** A name the register did not settle is asked again after this. */
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

type Status = "found" | "none" | "ambiguous";
type Cached = { status: Status; regnum: string | null; looked_up_at: string };

/** Whether a remembered match-player answer settles the matter: a number for
 * good, else until [RETRY_AFTER_MS] is over. */
const settled = (row: Cached | undefined) =>
  row !== undefined &&
  (row.status === "found" ||
    Date.now() - Date.parse(row.looked_up_at) < RETRY_AFTER_MS);

const pause = (asked: number) =>
  asked > 0 ? new Promise((r) => setTimeout(r, PAUSE_MS)) : undefined;

// ---------------------------------------------------------- match players

type SiteAsk = { name: string; slug: string; team: string };

/** The numbers of [asks] by slug, from `site_player_regnums` and — for the
 * ones missing there — from the sites, at most [budget] questions. */
async function resolveSitePlayers(
  asks: SiteAsk[],
  budget: number,
): Promise<{ found: Map<string, string>; more: boolean }> {
  const bySlug = new Map<string, SiteAsk>();
  for (const a of asks) if (isSiteSlug(a.slug)) bySlug.set(a.slug, a);
  const found = new Map<string, string>();
  if (bySlug.size === 0) return { found, more: false };

  const { data: cached, error } = await admin
    .from("site_player_regnums")
    .select("slug, regnum, status, looked_up_at")
    .in("slug", [...bySlug.keys()]);
  if (error) throw error;
  const known = new Map((cached ?? []).map((r) => [r.slug as string, r as Cached & { slug: string }]));

  let asked = 0;
  let more = false;
  for (const [slug, ask] of bySlug) {
    const row = known.get(slug);
    if (row?.status === "found") found.set(slug, row.regnum as string);
    if (settled(row)) continue;
    if (asked >= budget) {
      more = true;
      continue;
    }
    await pause(asked);
    asked++;
    try {
      const answer = await resolveSitePlayer(ask.name, slug, ask.team);
      const { error: saveError } = await admin.from("site_player_regnums").upsert({
        slug,
        regnum: answer.status === "found" ? answer.regnum : null,
        status: answer.status,
        looked_up_at: new Date().toISOString(),
      });
      if (saveError) console.error("regnum-lookup: save failed:", saveError.message);
      if (answer.status === "found") found.set(slug, answer.regnum);
    } catch (e) {
      // A site is down or changed: nothing is remembered, the next call
      // tries again.
      console.warn("regnum-lookup: lookup failed:", (e as Error).message);
    }
  }
  return { found, more };
}

// --------------------------------------------------------------- profiles

/** A profile's name and the club to compare it by (the club's name on the
 * results service when it is linked, else the app's own). */
async function ownProfile(userId: string) {
  const { data: profile } = await admin
    .from("profiles")
    .select("id, display_name, club_id, regnum")
    .eq("id", userId)
    .maybeSingle();
  if (!profile) return null;
  let club = "";
  if (profile.club_id) {
    const { data } = await admin
      .from("clubs")
      .select("name, site_name")
      .eq("id", profile.club_id)
      .maybeSingle();
    club = (data?.site_name ?? data?.name ?? "") as string;
  }
  return {
    id: profile.id as string,
    name: profile.display_name as string,
    club,
    regnum: (profile.regnum ?? null) as string | null,
  };
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
        .select("side, player_name, player_slug")
        .eq("match_id", matchId);
      if (error) throw error;

      const asks: SiteAsk[] = (players ?? [])
        .filter((p) => typeof p.player_slug === "string")
        .map((p) => ({
          name: p.player_name as string,
          slug: p.player_slug as string,
          team: (p.side === "home" ? match.home_team : match.away_team) as string,
        }));
      const { found, more } = await resolveSitePlayers(asks, BUDGET);
      return json({ regnums: Object.fromEntries(found), more });
    }

    if (body?.mode === "profiles") {
      const { data: tenantId } = await asUser.rpc("current_tenant_id");
      if (typeof tenantId !== "string") return json({ error: "not_allowed" }, 403);
      const retryBefore = new Date(Date.now() - RETRY_AFTER_MS).toISOString();
      const { data: members, error } = await admin
        .from("profiles")
        .select("id, display_name, club_id")
        .eq("tenant_id", tenantId)
        .eq("status", "approved")
        .neq("role", "kiosk")
        .eq("placeholder", false)
        .is("regnum", null)
        .or(`regnum_checked_at.is.null,regnum_checked_at.lt.${retryBefore}`)
        .order("regnum_checked_at", { ascending: true, nullsFirst: true })
        .limit(200);
      if (error) throw error;
      if (!members || members.length === 0) return json({ filled: 0, more: false });

      // A name two profiles of the alley bear (a parent and a child) says
      // nothing about which of them the register's one person is: neither is
      // filled in by itself, each picks himself in Můj profil.
      const { data: everyone, error: namesError } = await admin
        .from("profiles")
        .select("display_name")
        .eq("tenant_id", tenantId);
      if (namesError) throw namesError;
      const shared = sharedNames((everyone ?? []).map((p) => p.display_name as string));
      const eligible = members.filter(
        (m) =>
          !shared.has(foldName(m.display_name as string)) &&
          // A single word cannot be told from anybody: not worth a question.
          foldName(m.display_name as string).includes(" "),
      );
      if (eligible.length === 0) return json({ filled: 0, more: false });

      const clubIds = [...new Set(eligible.map((m) => m.club_id).filter(Boolean))];
      const clubs = new Map<string, string>();
      if (clubIds.length > 0) {
        const { data } = await admin
          .from("clubs")
          .select("id, name, site_name")
          .in("id", clubIds);
        for (const c of data ?? []) clubs.set(c.id, c.site_name ?? c.name);
      }

      let filled = 0;
      let asked = 0;
      for (const m of eligible) {
        if (asked >= BUDGET) break;
        await pause(asked);
        asked++;
        try {
          const answer = await resolveProfile(
            m.display_name as string,
            m.club_id ? clubs.get(m.club_id) ?? "" : "",
          );
          // Found: the number. Anything else is remembered as „looked, could
          // not settle“ so the register is not asked again for a week.
          const { error: updateError } = await admin
            .from("profiles")
            .update(
              answer.status === "found"
                ? { regnum: answer.regnum, regnum_checked_at: new Date().toISOString() }
                : { regnum_checked_at: new Date().toISOString() },
            )
            .eq("id", m.id)
            .is("regnum", null);
          if (updateError) {
            // The number is another player's already (profiles_regnum_tenant_idx).
            console.error("regnum-lookup: profile update failed:", updateError.message);
          } else if (answer.status === "found") {
            filled++;
          }
        } catch (e) {
          // A site is down or changed: nothing is remembered, the next call
          // tries again.
          console.warn("regnum-lookup: lookup failed:", (e as Error).message);
        }
      }
      return json({ filled, more: eligible.length > BUDGET });
    }

    if (body?.mode === "profile_candidates") {
      const me = await ownProfile(user.id);
      if (!me) return json({ error: "not_found" }, 404);
      if (me.regnum !== null) return json({ regnum: me.regnum, candidates: [] });
      const candidates = named(await searchRegister(me.name), me.name).map((r) => ({
        id: r.id,
        club: r.club,
        category: r.categoryName,
        age: null,
      }));
      return json({ candidates });
    }

    if (body?.mode === "profile_confirm") {
      const candidateId = typeof body.candidate_id === "string" ? body.candidate_id : "";
      if (candidateId === "") return json({ error: "missing_candidate" }, 400);
      const me = await ownProfile(user.id);
      if (!me) return json({ error: "not_found" }, 404);
      const row = named(await searchRegister(me.name), me.name)
        .find((r) => r.id === candidateId);
      if (!row) return json({ error: "candidate_gone" }, 404);
      const { error } = await admin
        .from("profiles")
        .update({ regnum: row.regnum })
        .eq("id", me.id);
      // One number, one player of the alley (profiles_regnum_tenant_idx).
      if (error?.code === "23505") return json({ error: "regnum_taken" }, 409);
      if (error) throw error;
      return json({ regnum: row.regnum });
    }

    return json({ error: "bad_mode" }, 400);
  } catch (error) {
    console.error("regnum-lookup failed:", error);
    return json({ error: "internal" }, 500);
  }
});
