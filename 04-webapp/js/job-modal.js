/* ========================================================================== */
/* job-modal.js                                                                */
/* Renders a job detail modal inline on the dashboard. Handles notes and      */
/* attachment CRUD without navigating away from the jobs table.               */
/* ========================================================================== */

import { getJob, listFolders, updateJobNotes,
         listAttachments, uploadAttachment,
         downloadAttachment, deleteAttachment } from "./api.js";

const ICON_CLIP     = `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>`;
const ICON_DOWNLOAD = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>`;
const ICON_TRASH    = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>`;

let currentJobId    = null;
let initialized     = false;

/* -------------------------------------------------------------------------- */
/* Function: initJobModal                                                      */
/* Purpose: Wire close button, backdrop click, notes, and upload handlers.    */
/*          Safe to call multiple times — only runs once.                     */
/* -------------------------------------------------------------------------- */
export function initJobModal() {
  if (initialized) return;
  initialized = true;

  const modal = document.getElementById("job-detail-modal");
  if (!modal) return;

  modal.addEventListener("click", (e) => { if (e.target === modal) closeJobModal(); });
  document.getElementById("jd-close-btn")?.addEventListener("click", closeJobModal);
  bindNotesHandler();
  bindUploadHandler();
}

/* -------------------------------------------------------------------------- */
/* Function: openJobModal                                                      */
/* Purpose: Fetch job + folders in parallel, then render into the modal.      */
/* -------------------------------------------------------------------------- */
export async function openJobModal(jobId) {
  currentJobId = jobId;

  setVisible("jd-error",   false);
  setVisible("jd-loading", true);
  setVisible("jd-content", false);
  document.getElementById("job-detail-modal")?.classList.remove("hidden");

  try {
    const [job, folders] = await Promise.all([getJob(jobId), listFolders()]);
    renderJobDetail(job, folders);
    await refreshAttachments(jobId);
  } catch (err) {
    showError(`Failed to load job: ${err.message}`);
  }
}

function closeJobModal() {
  document.getElementById("job-detail-modal")?.classList.add("hidden");
  currentJobId = null;
}

/* -------------------------------------------------------------------------- */
/* Function: renderJobDetail                                                   */
/* Purpose: Populate all modal fields from the job API response.              */
/* -------------------------------------------------------------------------- */
function renderJobDetail(job, folders) {
  const extLink = document.getElementById("jd-ext-link");
  if (extLink) extLink.href = `job.html?id=${encodeURIComponent(job.job_id)}`;

  setText("jd-job-title",      job.job_title      || "—");
  setText("jd-company",        job.company        || "—");
  setText("jd-status-message", job.status_message || "—");
  setText("jd-source-type",    job.source_type    || "—");
  setText("jd-scored-at",      formatDate(job.created_at));

  renderStatusBadge(job.status);
  renderScoreRing(job.score);

  const folder = folders.find((f) => f.folder_id === job.folder_id);
  setText("jd-folder", folder?.name || "—");

  renderUrl(job.job_url);
  renderTextBlock("jd-analysis",    job.job_analysis);
  renderTextBlock("jd-description", job.job_description);
  renderTextBlock("jd-resume",      job.resume_snapshot);

  const notes = document.getElementById("jd-notes");
  if (notes) notes.value = job.notes || "";

  setVisible("jd-loading", false);
  setVisible("jd-content", true);
}

function renderUrl(value) {
  const el = document.getElementById("jd-url");
  if (!el) return;
  if (!value) { el.textContent = "—"; return; }
  el.innerHTML = `<a href="${escapeHtml(value)}" target="_blank" rel="noopener noreferrer">${escapeHtml(value)}</a>`;
}

function renderTextBlock(id, value) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = String(value || "").trim() || "—";
}

function renderStatusBadge(status) {
  const el = document.getElementById("jd-status");
  if (!el) return;
  const s = status || "";
  el.innerHTML = s
    ? `<span class="status-badge status-${escapeHtml(s)}">${escapeHtml(s)}</span>`
    : "—";
}

/* -------------------------------------------------------------------------- */
/* Function: renderScoreRing                                                   */
/* Purpose: Animate the SVG donut arc and center label to reflect the score.  */
/*          Circumference of r=40 circle ≈ 251.                               */
/* -------------------------------------------------------------------------- */
function renderScoreRing(score) {
  const arc   = document.getElementById("jd-score-arc");
  const label = document.getElementById("jd-score-label");
  const CIRC  = 251;

  if (score == null) {
    if (arc)   { arc.style.strokeDasharray = `0 ${CIRC}`; arc.style.stroke = "#e2e8f0"; }
    if (label) { label.textContent = "—"; label.style.fill = "#94a3b8"; }
    return;
  }

  const n     = Number(score);
  const color = n >= 75 ? "#1b7a3c" : n >= 50 ? "#a66b00" : "#b33434";
  const len   = (Math.max(0, Math.min(100, n)) / 100) * CIRC;

  if (arc)   { arc.style.strokeDasharray = `${len} ${CIRC}`; arc.style.stroke = color; }
  if (label) { label.textContent = n; label.style.fill = color; }
}

function formatDate(value) {
  if (!value) return "—";
  try { return new Date(value).toLocaleString(); } catch { return value; }
}

function setText(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function setVisible(id, visible) {
  document.getElementById(id)?.classList.toggle("hidden", !visible);
}

function showError(message) {
  setVisible("jd-loading", false);
  const el = document.getElementById("jd-error");
  if (el) { el.textContent = message; el.classList.remove("hidden"); }
}

// -----------------------------------------------------------------------------
// Notes
// -----------------------------------------------------------------------------

function bindNotesHandler() {
  const btn      = document.getElementById("jd-update-notes-btn");
  const textarea = document.getElementById("jd-notes");
  if (!btn || !textarea) return;

  btn.addEventListener("click", async () => {
    if (!currentJobId) return;
    clearNotesMessages();
    btn.disabled    = true;
    btn.textContent = "Updating...";
    try {
      await updateJobNotes(currentJobId, textarea.value);
      showNotesSuccess("Notes updated.");
    } catch (err) {
      showNotesError(`Failed: ${err.message}`);
    } finally {
      btn.disabled    = false;
      btn.textContent = "Update Notes";
    }
  });
}

function clearNotesMessages() {
  ["jd-notes-error", "jd-notes-success"].forEach((id) => {
    const el = document.getElementById(id);
    if (el) { el.textContent = ""; el.classList.add("hidden"); }
  });
}

function showNotesError(msg) {
  const el = document.getElementById("jd-notes-error");
  if (el) { el.textContent = msg; el.classList.remove("hidden"); }
}

function showNotesSuccess(msg) {
  const el = document.getElementById("jd-notes-success");
  if (el) { el.textContent = msg; el.classList.remove("hidden"); }
}

// -----------------------------------------------------------------------------
// Attachments
// -----------------------------------------------------------------------------

async function refreshAttachments(jobId) {
  try {
    renderAttachmentList(await listAttachments(jobId), jobId);
  } catch (_) {
    renderAttachmentList([], jobId);
  }
}

function renderAttachmentList(attachments, jobId) {
  const el = document.getElementById("jd-attachment-list");
  if (!el) return;

  const btn = document.getElementById("jd-btn-upload-attachment");
  if (btn) btn.disabled = attachments.length >= 5;

  if (!attachments.length) {
    el.innerHTML = `<p class="attachment-empty">No attachments yet.</p>`;
    return;
  }

  el.innerHTML = attachments.map((att) => `
    <div class="attachment-item">
      ${ICON_CLIP}
      <span class="attachment-name" title="${escapeHtml(att.filename)}">${escapeHtml(att.filename)}</span>
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

  el.querySelectorAll(".btn-att-download").forEach((b) => {
    b.addEventListener("click", () => handleDownload(jobId, b.dataset.attId, b.dataset.filename));
  });
  el.querySelectorAll(".btn-att-delete").forEach((b) => {
    b.addEventListener("click", () => handleDelete(jobId, b.dataset.attId));
  });
}

function bindUploadHandler() {
  const btn   = document.getElementById("jd-btn-upload-attachment");
  const input = document.getElementById("jd-attachment-file-input");
  if (!btn || !input) return;

  btn.addEventListener("click", () => input.click());

  input.addEventListener("change", async () => {
    if (!currentJobId) return;
    const files = Array.from(input.files || []);
    if (!files.length) return;
    input.value = "";

    const statusEl = document.getElementById("jd-attachment-upload-status");
    const errorEl  = document.getElementById("jd-attachment-upload-error");
    if (statusEl) { statusEl.textContent = ""; statusEl.classList.add("hidden"); }
    if (errorEl)  { errorEl.textContent  = ""; errorEl.classList.add("hidden"); }

    const existing = document.querySelectorAll("#jd-attachment-list .attachment-item").length;
    const slots    = 5 - existing;
    if (slots <= 0) {
      if (errorEl) { errorEl.textContent = "Attachment limit reached (5 max)."; errorEl.classList.remove("hidden"); }
      return;
    }

    const toUpload = files.slice(0, slots);
    btn.disabled    = true;
    btn.textContent = "Uploading…";

    try {
      for (const file of toUpload) {
        const b64 = await fileToBase64(file);
        await uploadAttachment(currentJobId, file.name, file.type || "application/octet-stream", b64);
      }
      if (statusEl) {
        const n = toUpload.length;
        statusEl.textContent = `${n} file${n === 1 ? "" : "s"} uploaded.`;
        statusEl.classList.remove("hidden");
      }
      await refreshAttachments(currentJobId);
    } catch (err) {
      if (errorEl) { errorEl.textContent = `Upload failed: ${err.message}`; errorEl.classList.remove("hidden"); }
    } finally {
      btn.disabled    = false;
      btn.textContent = "Upload File";
    }
  });
}

async function handleDownload(jobId, attachmentId, filename) {
  try {
    const result = await downloadAttachment(jobId, attachmentId);
    const bytes  = Uint8Array.from(atob(result.data), (c) => c.charCodeAt(0));
    const blob   = new Blob([bytes], { type: result.content_type });
    const url    = URL.createObjectURL(blob);
    const a      = document.createElement("a");
    a.href = url; a.download = result.filename || filename; a.click();
    URL.revokeObjectURL(url);
  } catch (err) {
    const el = document.getElementById("jd-attachment-upload-error");
    if (el) { el.textContent = `Download failed: ${err.message}`; el.classList.remove("hidden"); }
  }
}

async function handleDelete(jobId, attachmentId) {
  try {
    await deleteAttachment(jobId, attachmentId);
    await refreshAttachments(jobId);
  } catch (err) {
    const el = document.getElementById("jd-attachment-upload-error");
    if (el) { el.textContent = `Delete failed: ${err.message}`; el.classList.remove("hidden"); }
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

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
