// FCM HTTP v1 client (lifted from Termínátor), shared so notify stays about
// *what* to send. Dormant until the FIREBASE_SERVICE_ACCOUNT secret is set.
//
// The service-account JSON is parsed lazily, on the first firebaseConfigured()
// call, and the verdict memoised for the isolate's lifetime: a missing, empty
// or malformed secret means "no push" (notify falls back to e-mail) instead of
// a crash at module load that would take every notification down with it.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { base64urlEncode } from "./cancel_token.ts";

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

// undefined = not looked at yet; null = not configured.
let serviceAccount: ServiceAccount | null | undefined;

function loadServiceAccount(): ServiceAccount | null {
  if (serviceAccount !== undefined) return serviceAccount;
  serviceAccount = null;
  const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    // Same test as before: a usable account has a client_email.
    if (parsed?.client_email) serviceAccount = parsed as ServiceAccount;
  } catch (error) {
    console.error(`FIREBASE_SERVICE_ACCOUNT is not valid JSON: ${error}`);
  }
  return serviceAccount;
}

/// True when FIREBASE_SERVICE_ACCOUNT holds a usable service account.
export function firebaseConfigured(): boolean {
  return loadServiceAccount() !== null;
}

let cachedToken: { token: string; expiresAt: number } | null = null;

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function getAccessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt > now + 60) {
    return cachedToken.token;
  }

  const header = base64urlEncode(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64urlEncode(JSON.stringify({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const key = await importPrivateKey(account.private_key);
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  ));
  const jwt = `${header}.${claims}.${base64urlEncode(signature)}`;

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!response.ok) {
    throw new Error(`OAuth token failed: ${await response.text()}`);
  }
  const json = await response.json();
  cachedToken = { token: json.access_token, expiresAt: now + 3500 };
  return json.access_token;
}

/// Sends one push. An UNREGISTERED / INVALID_ARGUMENT answer from FCM means
/// the device token is dead: it is cleared from profiles.fcm_token so the
/// next notification goes by e-mail instead.
export async function sendPush(
  supabase: SupabaseClient,
  userId: string,
  token: string,
  title: string,
  body: string,
  data: Record<string, string> = {},
): Promise<void> {
  const account = loadServiceAccount();
  if (!account) throw new Error("FIREBASE_SERVICE_ACCOUNT is not configured");
  const accessToken = await getAccessToken(account);
  const url =
    `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token,
        notification: { title, body },
        data,
        android: { priority: "HIGH" },
      },
    }),
  });
  if (!response.ok) {
    const text = await response.text();
    console.error(`FCM send failed for ${userId}: ${text}`);
    if (text.includes("UNREGISTERED") || text.includes("INVALID_ARGUMENT")) {
      await supabase.from("profiles").update({ fcm_token: null })
        .eq("id", userId);
    }
  }
}
