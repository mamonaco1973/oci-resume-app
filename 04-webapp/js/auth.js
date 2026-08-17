/* ========================================================================== */
/* auth.js                                                                     */
/* OCI IAM Identity Domains OAuth2 helpers: PKCE login, code exchange, token   */
/* storage and refresh.                                                        */
/*                                                                             */
/* Differences from the Cognito version this was ported from:                  */
/*   - PKCE is mandatory. The Identity Domains app is a public client with no  */
/*     secret, so the token endpoint rejects an exchange without a verifier.   */
/*   - Endpoints live under /oauth2/v1/ rather than /oauth2/.                  */
/*   - All URLs derive from CONFIG.WEB_BASE_URL, not window.location.origin,   */
/*     because the site is served under a long Object Storage /o/ path.        */
/* ========================================================================== */

import { CONFIG } from "./config.js";

const DOMAIN_URL = CONFIG.DOMAIN_URL.replace(/\/$/, "");
const CLIENT_ID = CONFIG.CLIENT_ID;
const WEB_BASE = CONFIG.WEB_BASE_URL.replace(/\/$/, "");

const REDIRECT_URI = `${WEB_BASE}/callback.html`;

/* -------------------------------------------------------------------------- */
/* PKCE helpers                                                                */
/* -------------------------------------------------------------------------- */

/* Random URL-safe string used as the PKCE code verifier and the state value. */
function randomUrlSafe(bytes = 32) {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return base64UrlEncode(buf.buffer);
}

function base64UrlEncode(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/* S256 challenge. Requires a secure context — crypto.subtle is undefined over
   plain HTTP, which is one more reason this app is only ever served on HTTPS. */
async function sha256Challenge(verifier) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(verifier)
  );
  return base64UrlEncode(digest);
}

/* -------------------------------------------------------------------------- */
/* Login                                                                       */
/* -------------------------------------------------------------------------- */

/* Builds the authorize URL and stashes the verifier/state for callback.html.
   Async because the challenge is a hash — callers must await it. */
export async function getLoginUrl() {
  const verifier = randomUrlSafe();
  const state = randomUrlSafe(16);
  const challenge = await sha256Challenge(verifier);

  sessionStorage.setItem("pkce_code_verifier", verifier);
  sessionStorage.setItem("oauth_state", state);

  const params = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: "code",
    scope: "openid email profile",
    redirect_uri: REDIRECT_URI,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256"
  });

  return `${DOMAIN_URL}/oauth2/v1/authorize?${params.toString()}`;
}

/* Self-registration page. Identity Domains does not render a "create account"
   link on its stock sign-in page even with the profile marked visible, so the
   SPA links to it directly. */
export function getSignupUrl() {
  return CONFIG.SIGNUP_URL || "";
}

/* -------------------------------------------------------------------------- */
/* Code exchange                                                               */
/* -------------------------------------------------------------------------- */

export async function exchangeCodeForTokens(code) {
  const verifier = sessionStorage.getItem("pkce_code_verifier");
  if (!verifier) {
    throw new Error(
      "Missing PKCE code verifier. Login must be started from the app."
    );
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: CLIENT_ID,
    code,
    redirect_uri: REDIRECT_URI,
    code_verifier: verifier
  });

  const response = await fetch(`${DOMAIN_URL}/oauth2/v1/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString()
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Token exchange failed: ${response.status} ${errorText}`);
  }

  return response.json();
}

/* -------------------------------------------------------------------------- */
/* Token storage                                                               */
/* -------------------------------------------------------------------------- */

export function storeTokens(tokens) {
  localStorage.setItem("id_token", tokens.id_token || "");
  localStorage.setItem("access_token", tokens.access_token || "");
  localStorage.setItem("refresh_token", tokens.refresh_token || "");

  /* One-shot values; leaving them behind would let a stale verifier be reused
     against a later authorization code. */
  sessionStorage.removeItem("pkce_code_verifier");
  sessionStorage.removeItem("oauth_state");
}

export function getIdToken() {
  return localStorage.getItem("id_token") || "";
}

export function getAccessToken() {
  return localStorage.getItem("access_token") || "";
}

export function getRefreshToken() {
  return localStorage.getItem("refresh_token") || "";
}

/* -------------------------------------------------------------------------- */
/* JWT helpers — decode payload and check expiration without a library         */
/* -------------------------------------------------------------------------- */

function decodeJwtPayload(token) {
  try {
    const base64 = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(base64));
  } catch (_) {
    return null;
  }
}

/* Returns true if the token is missing or within 30 seconds of expiring. */
export function isTokenExpired(token) {
  if (!token) return true;
  const payload = decodeJwtPayload(token);
  if (!payload || !payload.exp) return true;
  return Date.now() / 1000 >= payload.exp - 30;
}

/* -------------------------------------------------------------------------- */
/* Silent refresh                                                              */
/* Identity Domains DOES rotate the refresh token, unlike Cognito, so the new  */
/* one has to be stored or the next refresh fails.                             */
/* -------------------------------------------------------------------------- */

export async function refreshTokens() {
  const refreshToken = getRefreshToken();
  if (!refreshToken) return false;

  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: CLIENT_ID,
    refresh_token: refreshToken,
    scope: "openid email profile"
  });

  try {
    const response = await fetch(`${DOMAIN_URL}/oauth2/v1/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString()
    });

    if (!response.ok) return false;

    const tokens = await response.json();
    localStorage.setItem("id_token", tokens.id_token || "");
    localStorage.setItem("access_token", tokens.access_token || "");
    if (tokens.refresh_token) {
      localStorage.setItem("refresh_token", tokens.refresh_token);
    }
    return true;
  } catch (_) {
    return false;
  }
}

/* -------------------------------------------------------------------------- */
/* Session helpers                                                             */
/* -------------------------------------------------------------------------- */

/* Checks both presence and expiration; does not attempt an async refresh. */
export function isLoggedIn() {
  const token = getIdToken();
  return Boolean(token) && !isTokenExpired(token);
}

export function clearTokens() {
  localStorage.removeItem("id_token");
  localStorage.removeItem("access_token");
  localStorage.removeItem("refresh_token");
}

export function getPostLoginRedirectUrl() {
  return `${WEB_BASE}/index.html`;
}

/* Identity Domains implements OIDC RP-initiated logout, which identifies the
   session by `id_token_hint`. It does NOT accept `client_id` here — that is the
   Cognito shape (client_id + logout_uri) and it is rejected outright with
   "Invalid logout request".

   Order matters: the hint is read BEFORE clearing local storage. Wiping tokens
   first leaves nothing to identify the session with, producing the same
   rejection even once the parameter name is right.

   Tokens are still cleared before returning, so the app is signed out locally
   even if the domain endpoint is unreachable or the redirect never completes. */
export function getLogoutUrl() {
  const idToken = getIdToken();

  const params = new URLSearchParams({
    post_logout_redirect_uri: `${WEB_BASE}/index.html`
  });

  if (idToken) params.set("id_token_hint", idToken);

  clearTokens();

  return `${DOMAIN_URL}/oauth2/v1/userlogout?${params.toString()}`;
}
