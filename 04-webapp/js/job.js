/* ========================================================================== */
/* job.js                                                                      */
/* Job detail page: loads a single job record by URL query param and renders  */
/* all fields. Also handles inline notes saving.                               */
/* ========================================================================== */

import { getJob, updateJobNotes,
         listAttachments, uploadAttachment,
         downloadAttachment, deleteAttachment,
         listFolders } from "./api.js";

// SVG icons used in the attachment list
const ICON_CLIP     = `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>`;
const ICON_DOWNLOAD = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>`;
const ICON_TRASH    = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>`;

document.addEventListener("DOMContentLoaded", async () => {
  const jobId = getJobIdFromUrl();

  if (!jobId) {
    renderError("Missing job ID.");
    return;
  }

  bindNotesHandler(jobId);
  bindUploadHandler(jobId);

  try {
    const [job, folders] = await Promise.all([getJob(jobId), listFolders()]);
    renderJob(job, folders);
    await refreshAttachments(jobId);
  } catch (error) {
    renderError(`Failed to load job: ${error.message}`);
  }
});

/* -------------------------------------------------------------------------- */
/* Function: getJobIdFromUrl                                                   */
/* Purpose: Read the job ID from the "id" query parameter of the current URL. */
/* -------------------------------------------------------------------------- */
function getJobIdFromUrl() {
  const params = new URLSearchParams(window.location.search);
  return params.get("id")?.trim() || "";
}

/* -------------------------------------------------------------------------- */
/* Function: renderJob                                                         */
/* Purpose: Populate every field in the job detail view from the API response */
/*          object, then reveal the content panel and hide the loading state. */
/* -------------------------------------------------------------------------- */
function renderJob(job, folders = []) {
  const titleParts = [job.job_title, job.company].filter(Boolean);
  if (titleParts.length) document.title = titleParts.join(" | ");

  setText("job-title", job.job_title || "—");
  setText("job-company", job.company || "—");
  setText("job-status", job.status || "—");
  setText("job-status-message", job.status_message || "—");
  setText("job-score", formatScore(job.score));
  setText("job-scored-at", formatDate(job.created_at));
  setText("job-source-type", job.source_type || "—");

  renderJobUrl(job.job_url);
  renderJobFolder(job.folder_id, folders);
  renderTextBlock("job-analysis", job.job_analysis);
  renderTextBlock("job-description", job.job_description);
  renderTextBlock("job-resume", job.resume_snapshot);
  renderJobNotes(job.notes || "");

  document.getElementById("job-detail-loading")?.classList.add("hidden");
  document.getElementById("job-detail-content")?.classList.remove("hidden");
}

/* -------------------------------------------------------------------------- */
/* Function: renderJobUrl                                                      */
/* Purpose: Render the job URL as a safe anchor tag, or a dash if absent.     */
/* -------------------------------------------------------------------------- */
function renderJobUrl(value) {
  const element = document.getElementById("job-url");

  if (!element) {
    return;
  }

  if (!value) {
    element.textContent = "—";
    return;
  }

  element.innerHTML = `
    <a
      href="${escapeHtml(value)}"
      target="_blank"
      rel="noopener noreferrer"
    >
      ${escapeHtml(value)}
    </a>
  `;
}

/* -------------------------------------------------------------------------- */
/* Function: renderJobFolder                                                   */
/* Purpose: Resolve folder_id to a name and display it, or dash if none.     */
/* -------------------------------------------------------------------------- */
function renderJobFolder(folderId, folders) {
  const element = document.getElementById("job-folder");
  if (!element) return;

  if (!folderId) {
    element.textContent = "—";
    return;
  }

  const folder = folders.find((f) => f.folder_id === folderId);
  element.textContent = folder ? folder.name : "—";
}

/* -------------------------------------------------------------------------- */
/* Function: renderTextBlock                                                   */
/* Purpose: Set the text content of an element to the trimmed value, or a    */
/*          dash placeholder if the value is empty or absent.                 */
/* -------------------------------------------------------------------------- */
function renderTextBlock(elementId, value) {
  const element = document.getElementById(elementId);

  if (!element) {
    return;
  }

  const text = String(value || "").trim();

  if (!text) {
    element.textContent = "—";
    return;
  }

  element.textContent = text;
}

function renderJobNotes(value) {
  const element = document.getElementById("job-notes");

  if (!element) {
    return;
  }

  element.value = value;
}

/* -------------------------------------------------------------------------- */
/* Function: bindNotesHandler                                                  */
/* Purpose: Wire the "Update Notes" button to save the textarea value via     */
/*          the API and display inline success or error feedback.             */
/* -------------------------------------------------------------------------- */
function bindNotesHandler(jobId) {
  const button = document.getElementById("update-job-notes-btn");
  const textarea = document.getElementById("job-notes");

  if (!button || !textarea) {
    return;
  }

  button.addEventListener("click", async () => {
    clearNotesMessages();

    const notes = textarea.value;

    button.disabled = true;
    button.textContent = "Updating...";

    try {
      await updateJobNotes(jobId, notes);
      showNotesSuccess("Notes updated.");
    } catch (error) {
      showNotesError(`Failed to update notes: ${error.message}`);
    } finally {
      button.disabled = false;
      button.textContent = "Update Notes";
    }
  });
}

function clearNotesMessages() {
  const errorElement = document.getElementById("job-notes-error");
  const successElement = document.getElementById("job-notes-success");

  if (errorElement) {
    errorElement.textContent = "";
    errorElement.classList.add("hidden");
  }

  if (successElement) {
    successElement.textContent = "";
    successElement.classList.add("hidden");
  }
}

/* -------------------------------------------------------------------------- */
/* Function: showNotesError                                                    */
/* Purpose: Display an inline error message below the notes field. Falls back */
/*          to window.alert if the error element is missing.                  */
/* -------------------------------------------------------------------------- */
function showNotesError(message) {
  const element = document.getElementById("job-notes-error");

  if (!element) {
    window.alert(message);
    return;
  }

  element.textContent = message;
  element.classList.remove("hidden");
}

/* -------------------------------------------------------------------------- */
/* Function: showNotesSuccess                                                  */
/* Purpose: Display an inline success message below the notes field.          */
/* -------------------------------------------------------------------------- */
function showNotesSuccess(message) {
  const element = document.getElementById("job-notes-success");

  if (!element) {
    return;
  }

  element.textContent = message;
  element.classList.remove("hidden");
}

function formatScore(score) {
  return score == null ? "—" : String(score);
}

function setText(elementId, value) {
  const element = document.getElementById(elementId);

  if (!element) {
    return;
  }

  element.textContent = value;
}

/* -------------------------------------------------------------------------- */
/* Function: renderError                                                       */
/* Purpose: Show a page-level error and hide the loading state. Falls back to */
/*          window.alert if the error container element is missing.           */
/* -------------------------------------------------------------------------- */
function renderError(message) {
  document.getElementById("job-detail-loading")?.classList.add("hidden");

  const errorElement = document.getElementById("job-detail-error");

  if (!errorElement) {
    window.alert(message);
    return;
  }

  errorElement.textContent = message;
  errorElement.classList.remove("hidden");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatDate(value) {
  if (!value) {
    return "—";
  }

  try {
    const date = new Date(value);
    return date.toLocaleString();
  } catch {
    return value;
  }
}

// -----------------------------------------------------------------------------
// Attachments
// -----------------------------------------------------------------------------

/* -------------------------------------------------------------------------- */
/* Function: refreshAttachments                                                */
/* Purpose: Fetch the current attachment list from the API and re-render.     */
/* -------------------------------------------------------------------------- */
async function refreshAttachments(jobId) {
  try {
    const attachments = await listAttachments(jobId);
    renderAttachmentList(attachments, jobId);
  } catch (_) {
    renderAttachmentList([], jobId);
  }
}

/* -------------------------------------------------------------------------- */
/* Function: renderAttachmentList                                              */
/* Purpose: Build the attachment list UI with download and delete controls.   */
/* -------------------------------------------------------------------------- */
function renderAttachmentList(attachments, jobId) {
  const el = document.getElementById("attachment-list");
  if (!el) return;

  // Grey out the upload button when the 5-file cap is reached
  const uploadBtn = document.getElementById("btn-upload-attachment");
  if (uploadBtn) uploadBtn.disabled = attachments.length >= 5;

  if (!attachments.length) {
    el.innerHTML = `<p class="attachment-empty">No attachments yet.</p>`;
    return;
  }

  el.innerHTML = attachments.map((att) => `
    <div class="attachment-item">
      ${ICON_CLIP}
      <span class="attachment-name" title="${escapeHtml(att.filename)}">
        ${escapeHtml(att.filename)}
      </span>
      <span class="attachment-size">${formatBytes(att.size)}</span>
      <button type="button" class="icon-btn btn-att-download"
        data-att-id="${escapeHtml(att.attachment_id)}"
        data-filename="${escapeHtml(att.filename)}"
        title="Download">${ICON_DOWNLOAD}</button>
      <button type="button" class="icon-btn danger btn-att-delete"
        data-att-id="${escapeHtml(att.attachment_id)}"
        title="Delete">${ICON_TRASH}</button>
    </div>
  `).join("");

  el.querySelectorAll(".btn-att-download").forEach((btn) => {
    btn.addEventListener("click", () =>
      handleAttachmentDownload(jobId, btn.dataset.attId, btn.dataset.filename)
    );
  });

  el.querySelectorAll(".btn-att-delete").forEach((btn) => {
    btn.addEventListener("click", () =>
      handleAttachmentDelete(jobId, btn.dataset.attId)
    );
  });
}

/* -------------------------------------------------------------------------- */
/* Function: bindUploadHandler                                                 */
/* Purpose: Wire the Upload File button to the hidden file input.             */
/* -------------------------------------------------------------------------- */
function bindUploadHandler(jobId) {
  const btn   = document.getElementById("btn-upload-attachment");
  const input = document.getElementById("attachment-file-input");
  if (!btn || !input) return;

  btn.addEventListener("click", () => input.click());

  input.addEventListener("change", async () => {
    const files = Array.from(input.files || []);
    if (!files.length) return;
    input.value = "";

    const statusEl = document.getElementById("attachment-upload-status");
    const errorEl  = document.getElementById("attachment-upload-error");
    if (statusEl) { statusEl.textContent = ""; statusEl.classList.add("hidden"); }
    if (errorEl)  { errorEl.textContent  = ""; errorEl.classList.add("hidden"); }

    // Count existing attachments to enforce the 5-file cap client-side
    const existing = document.querySelectorAll(".attachment-item").length;
    const slots    = 5 - existing;
    if (slots <= 0) {
      if (errorEl) {
        errorEl.textContent = "Attachment limit reached (5 max).";
        errorEl.classList.remove("hidden");
      }
      return;
    }
    const toUpload = files.slice(0, slots);

    btn.disabled    = true;
    btn.textContent = "Uploading…";

    try {
      for (const file of toUpload) {
        const b64 = await fileToBase64(file);
        await uploadAttachment(jobId, file.name, file.type || "application/octet-stream", b64);
      }
      if (statusEl) {
        const n = toUpload.length;
        statusEl.textContent = `${n} file${n === 1 ? "" : "s"} uploaded.`;
        statusEl.classList.remove("hidden");
      }
      await refreshAttachments(jobId);
    } catch (error) {
      if (errorEl) {
        errorEl.textContent = `Upload failed: ${error.message}`;
        errorEl.classList.remove("hidden");
      }
    } finally {
      btn.disabled    = false;
      btn.textContent = "Upload File";
    }
  });
}

async function handleAttachmentDownload(jobId, attachmentId, filename) {
  try {
    const result = await downloadAttachment(jobId, attachmentId);
    const bytes  = Uint8Array.from(atob(result.data), (c) => c.charCodeAt(0));
    const blob   = new Blob([bytes], { type: result.content_type });
    const url    = URL.createObjectURL(blob);
    const a      = document.createElement("a");
    a.href     = url;
    a.download = result.filename || filename;
    a.click();
    URL.revokeObjectURL(url);
  } catch (error) {
    const errorEl = document.getElementById("attachment-upload-error");
    if (errorEl) {
      errorEl.textContent = `Download failed: ${error.message}`;
      errorEl.classList.remove("hidden");
    }
  }
}

async function handleAttachmentDelete(jobId, attachmentId) {
  try {
    await deleteAttachment(jobId, attachmentId);
    await refreshAttachments(jobId);
  } catch (error) {
    const errorEl = document.getElementById("attachment-upload-error");
    if (errorEl) {
      errorEl.textContent = `Delete failed: ${error.message}`;
      errorEl.classList.remove("hidden");
    }
  }
}

function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload  = () => resolve(reader.result.split(",")[1]);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

function formatBytes(bytes) {
  if (!bytes) return "";
  if (bytes < 1024)        return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}