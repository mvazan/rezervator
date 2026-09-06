// kiosk-password — nastaví kioskovému účtu nové heslo a vrátí ho volajícímu
// správci.
//
// Proč funkce a ne RPC: heslo umí změnit jen Auth admin API, tedy service
// role klíč, a ten v appce být nesmí. Přečíst staré heslo nejde vůbec —
// Supabase drží jen hash — takže "ukaž mi přihlašovací údaje k tabletu"
// znamená v praxi "nastav nová".
//
// Deployed WITHOUT --no-verify-jwt: volá se z appky přes functions.invoke,
// která připojí JWT správce, a platforma ho ověří dřív, než funkce naběhne.
// Uvnitř se ptáme auth.getUser() — bez session přijde jen anon klíč a ten
// žádného uživatele nedá.
//
// Kdo smí, rozhoduje RPC kiosk_password_target (0028), volané JMÉNEM
// VOLAJÍCÍHO: uvidí tedy jeho is_admin() a current_tenant_id(), ne service
// role. Vrací id cíle, takže heslo se nastaví právě tomu účtu, který
// kontrolou prošel — správce cizí kuželny ani běžný hráč se nikam nedostane.
//
// Staré sessions zůstávají platné (Supabase je při změně hesla neruší), takže
// tablet, který je právě přihlášený, běží dál; nové heslo potřebuje až při
// příštím přihlášení.
//
// CORS: appka běží i jako web na rezervator.online, kde je functions.invoke
// cross-origin fetch s preflightem.

import { createClient } from "@supabase/supabase-js";

import { newKioskPassword } from "../_shared/password.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

const admin = createClient(
  SUPABASE_URL,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

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
    const requested = typeof body?.user_id === "string" ? body.user_id : null;
    if (!requested) return json({ error: "missing_user_id" }, 400);

    // The gate, as the caller: an admin of the kiosk's own alley, nobody else.
    const { data: target, error: denied } = await asUser.rpc(
      "kiosk_password_target",
      { p_user_id: requested },
    );
    if (denied || typeof target !== "string") {
      console.warn(`kiosk-password: ${user.id} refused for ${requested}:`, denied?.message);
      return json({ error: "not_allowed" }, 403);
    }

    const password = newKioskPassword();
    const { error } = await admin.auth.admin.updateUserById(target, {
      password,
    });
    if (error) {
      console.error(`kiosk-password: set failed for ${target}:`, error);
      return json({ error: "internal" }, 500);
    }
    console.info(`kiosk-password: ${user.id} set a new password for ${target}`);
    return json({ password });
  } catch (error) {
    console.error("kiosk-password failed:", error);
    return json({ error: "internal" }, 500);
  }
});
