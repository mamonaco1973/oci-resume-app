/* ========================================================================== */
/* api.js                                                                      */
/* HTTP client for the Resume Scorer backend API.                              */
/* Attaches the Identity Domains id_token as a Bearer header on every request.*/
/* Throws on non-2xx responses using the server-supplied error message.       */
/* ========================================================================== */

import { CONFIG } from "./config.js";
import { getIdToken, isTokenExpired, refreshTokens, clearTokens } from "./auth.js";

const API_BASE_URL = CONFIG.API_BASE_URL;

// -----------------------------------------------------------------------------
// Common request helper
// -----------------------------------------------------------------------------

/* -------------------------------------------------------------------------- */
/* Function: buildHeaders                                                      */
/* Purpose: Construct Authorization + Content-Type headers for a request.    */
/* -------------------------------------------------------------------------- */
function buildHeaders(extraHeaders = {}) {
  const token = getIdToken();
  return {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...extraHeaders
  };
}

/* -------------------------------------------------------------------------- */
/* Function: apiRequest                                                        */
/* Purpose: Send an authenticated fetch request to the backend API.           */
/*          Proactively refreshes the token if expired before sending.        */
/*          On a 401, attempts a silent Cognito token refresh and retries     */
/*          once. If the refresh fails, clears tokens and redirects to the    */
/*          login page so the user is never silently stuck with an expired    */
/*          session.                                                           */
/* -------------------------------------------------------------------------- */
async function apiRequest(path, options = {}, isRetry = false) {
  // Proactively refresh if the token is expired before sending the request.
  if (isTokenExpired(getIdToken())) {
    const refreshed = await refreshTokens();
    if (!refreshed) {
      clearTokens();
      window.location.href = `${CONFIG.WEB_BASE_URL}/index.html`;
      return;
    }
  }

  const response = await fetch(`${API_BASE_URL}${path}`, {
    ...options,
    headers: buildHeaders(options.headers || {})
  });

  // On 401, try a silent token refresh then replay the request once.
  if (response.status === 401 && !isRetry) {
    const refreshed = await refreshTokens();
    if (refreshed) {
      return apiRequest(path, options, true);
    }
    // Refresh token is expired or missing — force re-login.
    clearTokens();
    window.location.href = `${CONFIG.WEB_BASE_URL}/index.html`;
    return;
  }

  let data = null;

  try {
    data = await response.json();
  } catch (_) {
    data = null;
  }

  if (!response.ok) {
    const message = data?.error || `Request failed: ${response.status}`;
    throw new Error(message);
  }

  return data;
}

// -----------------------------------------------------------------------------
// Jobs API
// -----------------------------------------------------------------------------

export async function listJobs() {
  return apiRequest("/jobs", {
    method: "GET"
  });
}

export async function getJob(jobId) {
  return apiRequest(`/jobs/${jobId}`, {
    method: "GET"
  });
}

export async function createJob(payload) {
  return apiRequest("/jobs", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export async function updateJobNotes(jobId, notes) {
  return apiRequest(`/jobs/${jobId}/notes`, {
    method: "PATCH",
    body: JSON.stringify({
      notes: notes
    })
  });
}

export async function deleteJob(jobId) {
  return apiRequest(`/jobs/${jobId}`, {
    method: "DELETE"
  });
}

export async function moveJobToFolder(jobId, folderId) {
  return apiRequest(`/jobs/${jobId}/folder`, {
    method: "PATCH",
    body: JSON.stringify({ folder_id: folderId })
  });
}

// -----------------------------------------------------------------------------
// Registration API
// -----------------------------------------------------------------------------

// Throws with message "user_limit_reached" when the user cap is full
export async function register() {
  return apiRequest("/register", { method: "POST", body: JSON.stringify({}) });
}

// -----------------------------------------------------------------------------
// Usage API
// -----------------------------------------------------------------------------

export async function getUsage() {
  return apiRequest("/usage", { method: "GET" });
}

// -----------------------------------------------------------------------------
// Attachments API
// -----------------------------------------------------------------------------

export async function listAttachments(jobId) {
  return apiRequest(`/jobs/${jobId}/attachments`, { method: "GET" });
}

export async function uploadAttachment(jobId, filename, contentType, base64Data) {
  return apiRequest(`/jobs/${jobId}/attachments`, {
    method: "POST",
    body: JSON.stringify({ filename, content_type: contentType, data: base64Data }),
  });
}

export async function downloadAttachment(jobId, attachmentId) {
  return apiRequest(`/jobs/${jobId}/attachments/${attachmentId}`, { method: "GET" });
}

export async function deleteAttachment(jobId, attachmentId) {
  return apiRequest(`/jobs/${jobId}/attachments/${attachmentId}`, { method: "DELETE" });
}

// -----------------------------------------------------------------------------
// Folders API
// -----------------------------------------------------------------------------

export async function listFolders() {
  return apiRequest("/folders", { method: "GET" });
}

export async function createFolder(payload) {
  return apiRequest("/folders", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export async function deleteFolder(folderId) {
  return apiRequest(`/folders/${folderId}`, { method: "DELETE" });
}

// -----------------------------------------------------------------------------
// Resumes API
// -----------------------------------------------------------------------------

export async function listResumes() {
  return apiRequest("/resumes", {
    method: "GET"
  });
}

export async function getResume(resumeId) {
  return apiRequest(`/resumes/${resumeId}`, {
    method: "GET"
  });
}

export async function createResume(payload) {
  return apiRequest("/resumes", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export async function updateResume(resumeId, payload) {
  return apiRequest(`/resumes/${resumeId}`, {
    method: "PUT",
    body: JSON.stringify(payload)
  });
}

export async function deleteResume(resumeId) {
  return apiRequest(`/resumes/${resumeId}`, {
    method: "DELETE"
  });
}
