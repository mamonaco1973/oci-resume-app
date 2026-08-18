/* ========================================================================== */
/* jobs.js                                                                     */
/* Fetches the job list, renders the jobs table, handles column sorting,      */
/* client-side filtering, multi-select checkboxes, and bulk actions.          */
/* ========================================================================== */

import { deleteJob, listJobs, moveJobToFolder,
         listAttachments, downloadAttachment }   from "./api.js";
import { showAlert, showConfirm }               from "./modal.js";
import { openJobModal, initJobModal }           from "./job-modal.js";

const ICON_TRASH    = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>`;
const ICON_ARROW    = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/></svg>`;
const ICON_CLIP     = `<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>`;
const ICON_DOWNLOAD = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>`;
const ICON_EXT      = `<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>`;

// Attachment dropdown — one shared element repositioned per click
let dropdownEl          = null;
let activeDropdownJobId = null;

let jobs = [];
let currentSort = {
  field:     "created_at",
  direction: "desc"
};

// Active filter state — set by app.js via the exported setters below
let filterFolderId = "";
let filterStatus   = "";
let filterSearch   = "";

// Multi-select state
let selectedJobIds    = new Set();
let bulkHandlersBound = false;

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

export async function loadJobs() {
  initJobModal();

  // Only narrate on the FIRST load. Auto-refresh polling calls this on a timer,
  // and swapping the populated table out for a loading panel every few seconds
  // would flicker badly.
  const firstLoad = jobs.length === 0;
  if (firstLoad) startLoadingNarration();

  try {
    jobs = await listJobs();
  } catch (error) {
    // renderJobsTable() never runs on this path, so without replacing the copy
    // the panel keeps claiming it is "still starting up" underneath the error
    // alert app.js raises.
    if (firstLoad) showLoadFailed();
    throw error;
  } finally {
    stopLoadingNarration();
  }

  sortJobs();
  renderJobsTable();
  bindSortHandlers();
  bindBulkHandlers();
}

/* ============================================================================ */
/* Loading narration                                                            */
/*                                                                              */
/* OCI Functions scale to zero, so the first request after an idle period waits */
/* on a container start plus an image pull — up to about a minute. A bare       */
/* "Loading your jobs…" for that long reads as a hung app, and the natural      */
/* reaction is to reload, which accomplishes nothing.                           */
/*                                                                              */
/* So the message escalates: plain at first, then explains what is happening,   */
/* then sets an expectation for how long and that it is one-time. Saying "this  */
/* is a cold start" is both true and more reassuring than a spinner.            */
/* ============================================================================ */

const LOADING_STAGES = [
  {
    after: 4000,
    html:
      "<p>Loading your jobs…</p>" +
      "<p class='loading-note'>Waking the backend — OCI Functions scale to " +
      "zero, so the first request has to start a container.</p>"
  },
  {
    after: 15000,
    html:
      "<p>Still starting up…</p>" +
      "<p class='loading-note'>A cold start can take up to a minute. This " +
      "only happens on the first request after an idle period — everything " +
      "after it is fast.</p>"
  }
];

let loadingTimers   = [];
let narrationActive = false;

/* Exported so app.js can start this at the FIRST api call of the page load.
   The cold start is absorbed by register() and loadFolders(), both of which
   run before the job list is ever fetched — narration owned solely by
   loadJobs() therefore begins only after the backend is already warm. */
export function startLoadingNarration() {
  // Already running under app.js's initial load; do not restart and reset the
  // escalation clock back to stage one.
  if (narrationActive) return;

  const emptyState = document.getElementById("empty-state");
  const table      = document.getElementById("jobs-table");
  if (!emptyState) return;

  table?.classList.add("hidden");
  emptyState.classList.remove("hidden");
  emptyState.innerHTML = "<p>Loading your jobs…</p>";

  // Clear timers directly rather than calling stopLoadingNarration() — that
  // also flips narrationActive to false, which would let the very next call
  // restart the sequence and reset the escalation clock to stage one.
  loadingTimers.forEach(clearTimeout);
  loadingTimers = LOADING_STAGES.map((stage) =>
    setTimeout(() => { emptyState.innerHTML = stage.html; }, stage.after)
  );

  narrationActive = true;
}

export function stopLoadingNarration() {
  loadingTimers.forEach(clearTimeout);
  loadingTimers = [];
  narrationActive = false;
}

function showLoadFailed() {
  const emptyState = document.getElementById("empty-state");
  if (!emptyState) return;

  emptyState.innerHTML =
    "<p>Could not load your jobs.</p>" +
    "<p class='loading-note'>Use <b>Refresh</b> to try again.</p>";
}

export function setFolderFilter(folderId) { filterFolderId = folderId || ""; selectedJobIds.clear(); }
export function setStatusFilter(status)   { filterStatus   = status   || ""; selectedJobIds.clear(); }
export function setSearchFilter(text)     { filterSearch   = text     || ""; selectedJobIds.clear(); }

// Returns true if any job is still being processed, so the dashboard
// knows to keep polling.
export function hasPendingJobs() {
  return jobs.some(
    (job) => job.status === "submitted" || job.status === "Scoring"
  );
}

// -----------------------------------------------------------------------------
// Sorting
// -----------------------------------------------------------------------------

function bindSortHandlers() {
  const headers = document.querySelectorAll("th[data-sort]");

  headers.forEach((header) => {
    if (header.dataset.bound === "true") return;

    header.addEventListener("click", () => {
      const field = header.dataset.sort;

      if (currentSort.field === field) {
        currentSort.direction = currentSort.direction === "asc" ? "desc" : "asc";
      } else {
        currentSort.field     = field;
        currentSort.direction = "asc";
      }

      sortJobs();
      renderJobsTable();
    });

    header.dataset.bound = "true";
  });
}

/* -------------------------------------------------------------------------- */
/* Function: sortJobs                                                          */
/* Purpose: Sort the jobs array in place using currentSort field/direction.   */
/* -------------------------------------------------------------------------- */
function sortJobs() {
  const { field, direction } = currentSort;

  jobs.sort((a, b) => {
    const aVal = normalizeSortValue(a[field], field);
    const bVal = normalizeSortValue(b[field], field);
    if (aVal < bVal) return direction === "asc" ? -1 : 1;
    if (aVal > bVal) return direction === "asc" ?  1 : -1;
    return 0;
  });
}

/* -------------------------------------------------------------------------- */
/* Function: normalizeSortValue                                                */
/* Purpose: Coerce a field value into a type-appropriate form for comparison. */
/* -------------------------------------------------------------------------- */
function normalizeSortValue(value, field) {
  if (field === "score") return value == null ? -1 : Number(value);
  if (field === "created_at" || field === "updated_at") {
    return value ? new Date(value).getTime() : 0;
  }
  return (value || "").toString().toLowerCase();
}

// -----------------------------------------------------------------------------
// Filtering
// -----------------------------------------------------------------------------

/* -------------------------------------------------------------------------- */
/* Function: filteredJobs                                                      */
/* Purpose: Apply active folder, status, and search filters to the full       */
/*          jobs array. All filtering is client-side; the API returns all.    */
/* -------------------------------------------------------------------------- */
function filteredJobs() {
  const term = filterSearch.toLowerCase();
  return jobs.filter((job) => {
    if (filterFolderId) {
      if ((job.folder_id || "") !== filterFolderId) return false;
    }
    if (filterStatus) {
      if ((job.status || "").toLowerCase() !== filterStatus.toLowerCase()) return false;
    }
    if (term) {
      const title   = (job.job_title || "").toLowerCase();
      const company = (job.company   || "").toLowerCase();
      if (!title.includes(term) && !company.includes(term)) return false;
    }
    return true;
  });
}

// -----------------------------------------------------------------------------
// Rendering
// -----------------------------------------------------------------------------

function renderJobsTable() {
  const tbody      = document.getElementById("jobs-body");
  const emptyState = document.getElementById("empty-state");
  const table      = document.getElementById("jobs-table");

  tbody.innerHTML = "";

  const visible = filteredJobs();

  if (!visible.length) {
    table.classList.add("hidden");
    emptyState.classList.remove("hidden");
    emptyState.innerHTML = jobs.length
      ? "<p>No jobs match the current filters.</p>"
      : "<p>No jobs submitted yet.</p><p>Click <b>Score New Job</b> to begin.</p>";
    updateBulkActionBar();
    return;
  }

  table.classList.remove("hidden");
  emptyState.classList.add("hidden");

  visible.forEach((job) => {
    const row     = document.createElement("tr");
    const checked = selectedJobIds.has(job.job_id) ? "checked" : "";
    row.innerHTML = `
      <td class="checkbox-cell">
        <input type="checkbox" class="job-checkbox"
          data-job-id="${escapeHtml(job.job_id)}" ${checked}>
      </td>
      <td>${renderJobTitle(job)}</td>
      <td>${renderCompany(job)}</td>
      <td>${renderStatus(job.status)}</td>
      <td>${formatScore(job.score)}</td>
      <td>${formatDate(job.created_at)}</td>
    `;
    tbody.appendChild(row);
  });

  bindCheckboxHandlers(visible);
  bindClipHandlers();
  bindJobOpenHandlers();
  updateBulkActionBar();
}

function renderJobTitle(job) {
  const title = escapeHtml(job.job_title || "—");
  const jobId = escapeHtml(job.job_id);
  const href  = `job.html?id=${encodeURIComponent(job.job_id)}`;
  const n     = job.attachment_count || 0;
  const clip  = n > 0
    ? ` <button class="btn-clip" data-job-id="${jobId}"
          title="${n} attachment${n === 1 ? "" : "s"}">${ICON_CLIP}</button>`
    : "";
  const ext = `<a class="btn-ext-link" href="${href}" target="_blank"
    rel="noopener noreferrer" title="Open in new tab">${ICON_EXT}</a>`;
  return `<button class="btn-job-open" data-job-id="${jobId}">${title}</button>${ext}${clip}`;
}

function bindJobOpenHandlers() {
  document.querySelectorAll(".btn-job-open").forEach((btn) => {
    btn.addEventListener("click", () => openJobModal(btn.dataset.jobId));
  });
}

function renderCompany(job) {
  const name = escapeHtml(job.company || "—");
  if (!job.job_url) return name;
  const href = escapeHtml(job.job_url);
  return `<a href="${href}" target="${escapeHtml(job.job_id)}" rel="noopener noreferrer">${name}</a>`;
}

function renderStatus(status) {
  const label = escapeHtml(status || "unknown");
  return `<span class="status-badge status-${label}">${label}</span>`;
}

function formatScore(score) {
  if (score == null) return "—";
  const n = Number(score);
  const cls = n >= 75 ? "score-high" : n >= 50 ? "score-mid" : "score-low";
  return `<span class="score-badge ${cls}">${n}</span>`;
}

function formatDate(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString();
}

// -----------------------------------------------------------------------------
// Checkbox / Multi-select
// -----------------------------------------------------------------------------

/* -------------------------------------------------------------------------- */
/* Function: bindCheckboxHandlers                                              */
/* Purpose: Wire per-row checkboxes and refresh the master checkbox state.    */
/*          The master checkbox is cloned each render to avoid duplicate      */
/*          listeners accumulating across table refreshes.                    */
/* -------------------------------------------------------------------------- */
function bindCheckboxHandlers(visible) {
  const master = document.getElementById("select-all-jobs");
  if (master) {
    const allChecked  = visible.length > 0 && visible.every((j) => selectedJobIds.has(j.job_id));
    const someChecked = visible.some((j) => selectedJobIds.has(j.job_id));
    const fresh = master.cloneNode(true);
    fresh.checked       = allChecked;
    fresh.indeterminate = someChecked && !allChecked;
    master.replaceWith(fresh);
    fresh.addEventListener("change", () => {
      const vis = filteredJobs();
      if (fresh.checked) vis.forEach((j) => selectedJobIds.add(j.job_id));
      else               vis.forEach((j) => selectedJobIds.delete(j.job_id));
      renderJobsTable();
    });
  }

  document.querySelectorAll(".job-checkbox").forEach((cb) => {
    cb.addEventListener("change", () => {
      if (cb.checked) selectedJobIds.add(cb.dataset.jobId);
      else            selectedJobIds.delete(cb.dataset.jobId);
      updateBulkActionBar();
      // Sync master checkbox without re-rendering the whole table
      const vis = filteredJobs();
      const m   = document.getElementById("select-all-jobs");
      if (m) {
        const all  = vis.length > 0 && vis.every((j) => selectedJobIds.has(j.job_id));
        const some = vis.some((j) => selectedJobIds.has(j.job_id));
        m.checked       = all;
        m.indeterminate = some && !all;
      }
    });
  });
}

/* -------------------------------------------------------------------------- */
/* Function: updateBulkActionBar                                               */
/* Purpose: Show or hide the bulk action bar and sync the folder picker from  */
/*          the main folder dropdown (single source of truth for folder list).*/
/* -------------------------------------------------------------------------- */
function updateBulkActionBar() {
  const bar   = document.getElementById("bulk-action-bar");
  const label = document.getElementById("bulk-count");
  const n     = selectedJobIds.size;
  if (!bar) return;
  if (n === 0) { bar.classList.add("hidden"); return; }
  bar.classList.remove("hidden");
  if (label) label.textContent = `${n} job${n === 1 ? "" : "s"} selected`;
  populateBulkFolderSelect();
}

function populateBulkFolderSelect() {
  const bulk   = document.getElementById("bulk-folder-select");
  const source = document.getElementById("folder-select");
  if (!bulk || !source) return;
  bulk.innerHTML = `<option value="">— Unassigned —</option>`;
  Array.from(source.options).forEach((opt) => {
    if (!opt.value) return;
    const o = document.createElement("option");
    o.value = opt.value; o.textContent = opt.textContent;
    bulk.appendChild(o);
  });
}

/* -------------------------------------------------------------------------- */
/* Function: setTableBusy                                                      */
/* Purpose: Grey out the table and filter bar during bulk operations so the   */
/*          user sees the UI is working rather than an unresponsive screen.   */
/* -------------------------------------------------------------------------- */
function setTableBusy(busy) {
  document.querySelector("main")?.classList.toggle("table-busy", busy);
  document.getElementById("filter-bar")?.classList.toggle("table-busy", busy);
}

/* -------------------------------------------------------------------------- */
/* Function: bindBulkHandlers                                                  */
/* Purpose: Wire the Delete Selected and Move buttons once on first load.     */
/* -------------------------------------------------------------------------- */
function bindBulkHandlers() {
  if (bulkHandlersBound) return;

  document.getElementById("btn-bulk-delete")?.addEventListener("click", async () => {
    const ids = [...selectedJobIds];
    if (!ids.length) return;
    const n = ids.length;
    const confirmed = await showConfirm(
      `Delete ${n} job${n === 1 ? "" : "s"} and all stored data?`,
      { title: "Delete Jobs", confirmText: "Delete", danger: true }
    );
    if (!confirmed) return;
    const btn   = document.getElementById("btn-bulk-delete");
    const label = document.getElementById("bulk-count");
    try {
      if (btn) { btn.disabled = true; btn.innerHTML = "…"; }
      setTableBusy(true);
      for (let i = 0; i < ids.length; i++) {
        if (label) label.textContent = `Deleting ${i + 1} of ${n}…`;
        await deleteJob(ids[i]);
        jobs = jobs.filter((j) => j.job_id !== ids[i]);
        selectedJobIds.delete(ids[i]);
      }
      renderJobsTable();
    } catch (error) {
      await showAlert(`Delete failed: ${error.message}`, { title: "Error" });
      renderJobsTable();
    } finally {
      setTableBusy(false);
      if (btn) { btn.disabled = false; btn.innerHTML = ICON_TRASH; }
    }
  });

  document.getElementById("btn-bulk-move")?.addEventListener("click", async () => {
    const ids      = [...selectedJobIds];
    const folderId = document.getElementById("bulk-folder-select")?.value || null;
    if (!ids.length) return;
    const n     = ids.length;
    const btn   = document.getElementById("btn-bulk-move");
    const label = document.getElementById("bulk-count");
    try {
      if (btn) { btn.disabled = true; btn.innerHTML = "…"; }
      setTableBusy(true);
      for (let i = 0; i < ids.length; i++) {
        if (label) label.textContent = `Moving ${i + 1} of ${n}…`;
        await moveJobToFolder(ids[i], folderId);
        const job = jobs.find((j) => j.job_id === ids[i]);
        if (job) job.folder_id = folderId || "";
      }
      selectedJobIds.clear();
      renderJobsTable();
    } catch (error) {
      await showAlert(`Move failed: ${error.message}`, { title: "Error" });
    } finally {
      setTableBusy(false);
      if (btn) { btn.disabled = false; btn.innerHTML = ICON_ARROW; }
    }
  });

  bulkHandlersBound = true;
}

// -----------------------------------------------------------------------------
// Attachment dropdown
// -----------------------------------------------------------------------------

function getOrCreateDropdown() {
  if (dropdownEl) return dropdownEl;
  dropdownEl = document.createElement("div");
  dropdownEl.className = "attachment-dropdown hidden";
  document.body.appendChild(dropdownEl);
  // Dismiss on any outside click
  document.addEventListener("click", (e) => {
    if (
      dropdownEl &&
      !dropdownEl.contains(e.target) &&
      !e.target.closest(".btn-clip")
    ) {
      closeDropdown();
    }
  }, true);
  return dropdownEl;
}

function closeDropdown() {
  dropdownEl?.classList.add("hidden");
  activeDropdownJobId = null;
}

function bindClipHandlers() {
  document.querySelectorAll(".btn-clip").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const jobId = btn.dataset.jobId;
      if (activeDropdownJobId === jobId) { closeDropdown(); return; }
      await openAttachmentDropdown(btn, jobId);
    });
  });
}

async function openAttachmentDropdown(btn, jobId) {
  const dropdown = getOrCreateDropdown();
  activeDropdownJobId = jobId;

  dropdown.innerHTML = `<div class="attachment-dropdown-loading">Loading…</div>`;
  dropdown.classList.remove("hidden");
  positionDropdown(btn, dropdown);

  try {
    const attachments = await listAttachments(jobId);
    if (!attachments.length) {
      dropdown.innerHTML = `<div class="attachment-dropdown-empty">No attachments</div>`;
      return;
    }
    dropdown.innerHTML = attachments.map((att) => `
      <div class="attachment-dropdown-item"
           data-job-id="${escapeHtml(jobId)}"
           data-att-id="${escapeHtml(att.attachment_id)}"
           data-filename="${escapeHtml(att.filename)}">
        ${ICON_DOWNLOAD}
        <span title="${escapeHtml(att.filename)}">${escapeHtml(att.filename)}</span>
      </div>
    `).join("");

    dropdown.querySelectorAll(".attachment-dropdown-item").forEach((item) => {
      item.addEventListener("click", async (e) => {
        e.stopPropagation();
        closeDropdown();
        await triggerDownload(item.dataset.jobId, item.dataset.attId, item.dataset.filename);
      });
    });
  } catch (_) {
    dropdown.innerHTML = `<div class="attachment-dropdown-empty">Failed to load</div>`;
  }
}

function positionDropdown(btn, dropdown) {
  const rect = btn.getBoundingClientRect();
  dropdown.style.top  = `${rect.bottom + 4}px`;
  const rightEdge = rect.left + 220;
  const left = rightEdge > window.innerWidth ? window.innerWidth - 224 : rect.left;
  dropdown.style.left = `${left}px`;
}

async function triggerDownload(jobId, attachmentId, filename) {
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
    await showAlert(`Download failed: ${error.message}`, { title: "Error" });
  }
}

// -----------------------------------------------------------------------------
// Utilities
// -----------------------------------------------------------------------------

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
