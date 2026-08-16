/* ========================================================================== */
/* app.js                                                                      */
/* Dashboard controller. Initializes auth state, wires up the new-job form,  */
/* resume selector, and job list on DOMContentLoaded.                         */
/* ========================================================================== */

import { createJob, listResumes, register, getUsage,
         listFolders, createFolder, deleteFolder } from "./api.js";
import { loadJobs, hasPendingJobs,
         setFolderFilter, setStatusFilter,
         setSearchFilter }                         from "./jobs.js";
import { bindResumeHandlers, openResumeManager }   from "./resumes.js";
import { getLoginUrl, getLogoutUrl, getSignupUrl,
         isLoggedIn }                              from "./auth.js";
import { showAlert, showConfirm, showPrompt }       from "./modal.js";

let lastSelectedResumeId = "";
let autoRefreshTimer     = null;
let countdownInterval    = null;
let folders              = [];
let currentFolderId      = "";

const AUTO_REFRESH_SECONDS = 5;

document.addEventListener("DOMContentLoaded", async () => {
  updateAuthButtons();
  bindUiHandlers();
  bindResumeHandlers();

  if (!isLoggedIn()) {
    showNotLoggedInMessage();
    return;
  }

  // Check user cap before loading the dashboard
  try {
    await register();
  } catch (error) {
    if (error.message === "user_limit_reached") {
      await showAlert(
        "This app has reached its maximum number of free users.\n\n" +
        "To request access, email mamonaco1973@gmail.com.",
        { title: "Registration Closed" }
      );
      localStorage.removeItem("id_token");
      localStorage.removeItem("access_token");
      localStorage.removeItem("refresh_token");
      window.location.href = getLogoutUrl();
      return;
    }
  }

  try {
    restoreFilterState();
    await loadFolders();
    await refreshApp();
    await updateTokenUsage();
  } catch (error) {
    console.error("Failed to load dashboard:", error);
  }
});

/* -------------------------------------------------------------------------- */
/* Function: bindUiHandlers                                                    */
/* Purpose: Attach all event listeners for the dashboard: modal open/close,  */
/*          source type toggle, form submit, live validation, and auth        */
/*          buttons. Called once on DOMContentLoaded.                         */
/* -------------------------------------------------------------------------- */
function bindUiHandlers() {
  const newJobModal = document.getElementById("new-job-modal");
  const resumeModal = document.getElementById("resume-modal");

  const btnNewJob = document.getElementById("btn-new-job");
  const btnManageResumes = document.getElementById("btn-manage-resumes");
  const cancelNewJob = document.getElementById("cancel-new-job");
  const btnSignIn = document.getElementById("btn-sign-in");
  const btnSignOut = document.getElementById("btn-sign-out");
  
  const sourceType = document.getElementById("source-type");
  const resumeSelect = document.getElementById("resume-select");
  const newJobForm = document.getElementById("new-job-form");
  
  // ---------------------------------------------------------------------------
  // Track last selected resume
  // ---------------------------------------------------------------------------

  resumeSelect?.addEventListener("change", () => {
    lastSelectedResumeId = resumeSelect.value;
  });

  // ---------------------------------------------------------------------------
  // Open "Score New Job"
  // ---------------------------------------------------------------------------

  btnNewJob?.addEventListener("click", async () => {
    try {
      resumeModal?.classList.add("hidden");
      resetNewJobForm();
      const hasResumes = await populateResumeSelect();
      if (!hasResumes) {
        await showAlert(
          "Please define a resume before scoring a job.",
          { title: "No Resume Found" }
        );
        await openResumeManager();
        return;
      }
      populateJobFolderSelect();
      updateSourceFields();
      newJobModal?.classList.remove("hidden");
      updateNewJobFormValidation();
    } catch (error) {
      console.error("Failed to load resumes:", error);
      await showAlert(`Failed to load resumes: ${error.message}`, { title: "Error" });
    }
  });

  // ---------------------------------------------------------------------------
  // Open "Manage Resumes"
  // ---------------------------------------------------------------------------

  btnManageResumes?.addEventListener("click", async () => {
    newJobModal?.classList.add("hidden");
    await openResumeManager();
  });

  // ---------------------------------------------------------------------------
  // Cancel new job modal
  // ---------------------------------------------------------------------------

  cancelNewJob?.addEventListener("click", () => {
    newJobModal?.classList.add("hidden");
  });

  // ---------------------------------------------------------------------------
  // Source type toggle
  // ---------------------------------------------------------------------------

  sourceType?.addEventListener("change", () => {
    setCookie("jobFilter_sourceType", sourceType.value);
    updateSourceFields();
  });

// ---------------------------------------------------------------------------
// Live validation listeners
// ---------------------------------------------------------------------------

resumeSelect?.addEventListener("change", updateNewJobFormValidation);

sourceType?.addEventListener("change", updateNewJobFormValidation);

document
  .getElementById("job-url")
  ?.addEventListener("input", updateNewJobFormValidation);

document
  .getElementById("job-description")
  ?.addEventListener("input", updateNewJobFormValidation);

document
  .getElementById("linkedin-job-ids")
  ?.addEventListener("input", updateNewJobFormValidation);


  newJobForm?.addEventListener("submit", async (event) => {
  event.preventDefault();

  const validation = validateNewJobForm();

  clearNewJobFormErrors();

  if (!validation.isValid) {
    renderNewJobFormErrors(validation.errors);
    return;
  }

  const submitBtn = document.getElementById("submit-new-job");
  const statusEl  = document.getElementById("new-job-submit-status");
  if (submitBtn) { submitBtn.disabled = true; submitBtn.textContent = "Submitting..."; }
  if (statusEl)  { statusEl.textContent = ""; statusEl.classList.add("hidden"); }
  const newJobModal = document.getElementById("new-job-modal");
  newJobModal?.classList.add("modal-submitting");
  let submitError = null;
  try {
    await submitJobScoringRequest((current, total) => {
      if (statusEl) {
        statusEl.textContent = `Submitting ${current} of ${total}…`;
        statusEl.classList.remove("hidden");
      }
    });
  } catch (err) {
    submitError = err.message || "Submission failed. Please try again.";
  } finally {
    newJobModal?.classList.remove("modal-submitting");
    if (submitBtn) { submitBtn.disabled = false; submitBtn.textContent = "Submit"; }
    if (statusEl)  { statusEl.classList.add("hidden"); }
  }
  if (submitError) {
    const errEl = document.getElementById("new-job-submit-error");
    if (errEl) { errEl.textContent = submitError; errEl.classList.remove("hidden"); }
    return;
  }
  newJobModal?.classList.add("hidden");
  resetNewJobForm();
  await refreshApp();

});

  document.getElementById("btn-refresh")?.addEventListener("click", refreshApp);

  // ---------------------------------------------------------------------------
  // Folder dropdown
  // ---------------------------------------------------------------------------

  document.getElementById("folder-select")?.addEventListener("change", (e) => {
    currentFolderId = e.target.value;
    setFolderFilter(currentFolderId);
    setCookie("jobFilter_folder", currentFolderId);
    updateDeleteFolderButton();
    refreshApp();
  });

  document.getElementById("btn-new-folder")?.addEventListener("click", async () => {
    const name = await showPrompt("Folder name", {
      title: "New Folder", placeholder: "Enter folder name...", confirmText: "Create",
    });
    if (!name) return;
    if (folders.some((f) => f.name.toLowerCase() === name.toLowerCase())) {
      await showAlert(`A folder named "${name}" already exists.`, { title: "Duplicate Folder" });
      return;
    }
    try {
      await createFolder({ name });
      await loadFolders();
    } catch (error) {
      await showAlert(`Failed to create folder: ${error.message}`, { title: "Error" });
    }
  });

  document.getElementById("btn-delete-folder")?.addEventListener("click", async () => {
    if (!currentFolderId) return;
    const folder = folders.find((f) => f.folder_id === currentFolderId);
    const label  = folder?.name || currentFolderId;
    const confirmed = await showConfirm(
      `Delete folder "${label}"? Jobs inside will move to All Jobs.`,
      { title: "Delete Folder", confirmText: "Delete", danger: true }
    );
    if (!confirmed) return;
    try {
      await deleteFolder(currentFolderId);
      currentFolderId = "";
      setFolderFilter("");
      setCookie("jobFilter_folder", "");
      await loadFolders();
      await refreshApp();
    } catch (error) {
      await showAlert(`Failed to delete folder: ${error.message}`, { title: "Error" });
    }
  });

  // ---------------------------------------------------------------------------
  // Filter bar — status + search
  // ---------------------------------------------------------------------------

  document.getElementById("filter-status")?.addEventListener("change", (e) => {
    setStatusFilter(e.target.value);
    setCookie("jobFilter_status", e.target.value);
    refreshApp();
  });

  document.getElementById("filter-search")?.addEventListener("input", (e) => {
    setSearchFilter(e.target.value);
    setCookie("jobFilter_search", e.target.value);
    refreshApp();
  });

  // ---------------------------------------------------------------------------
  // Help modal
  // ---------------------------------------------------------------------------

  const helpModal = document.getElementById("help-modal");
  document.getElementById("btn-help")?.addEventListener("click", () => {
    helpModal?.classList.remove("hidden");
  });
  document.getElementById("btn-help-close")?.addEventListener("click", () => {
    helpModal?.classList.add("hidden");
  });
  helpModal?.addEventListener("click", (e) => {
    if (e.target === helpModal) helpModal.classList.add("hidden");
  });

  // ---------------------------------------------------------------------------
  // Sign in — open preview modal; actual redirect happens inside the modal
  // ---------------------------------------------------------------------------

  const signInModal = document.getElementById("sign-in-modal");

  btnSignIn?.addEventListener("click", () => {
    signInModal?.classList.remove("hidden");
  });

  // Awaited because building the authorize URL now derives a PKCE S256
  // challenge, which is an async crypto.subtle call.
  document.getElementById("btn-sign-in")?.addEventListener("click", async () => {
    window.location.href = await getLoginUrl();
  });

  // -------------------------------------------------------------------------
  // Sign Up
  // -------------------------------------------------------------------------
  // Identity Domains will not render a self-registration link on its own
  // sign-in page even with the profile marked visible, so the app links to the
  // hosted signup form directly.
  //
  // Opened in a NEW tab, not this one. Navigating away would discard the PKCE
  // verifier this tab has already stashed in sessionStorage, so a user who
  // registered and pressed Back would land on a sign-in that fails with an
  // opaque invalid_grant. Registering beside the app and returning to it keeps
  // that state intact.
  //
  // The button is revealed only when apply.sh actually resolved a
  // self-registration profile; otherwise SIGNUP_URL is empty and it stays
  // hidden rather than leading to a broken page.
  const btnSignUp  = document.getElementById("btn-sign-up");
  const signUpHint = document.getElementById("sign-up-hint");
  const signupUrl  = getSignupUrl();

  if (signupUrl) {
    btnSignUp?.classList.remove("hidden");
    signUpHint?.classList.remove("hidden");

    btnSignUp?.addEventListener("click", () => {
      // noopener so the new tab cannot reach back through window.opener.
      window.open(signupUrl, "_blank", "noopener");
    });
  }

  // ---------------------------------------------------------------------------
  // Sign out
  // ---------------------------------------------------------------------------

  btnSignOut?.addEventListener("click", () => {
  localStorage.removeItem("id_token");
  localStorage.removeItem("access_token");
  localStorage.removeItem("refresh_token");

  window.location.href = getLogoutUrl();
  });

}

/* -------------------------------------------------------------------------- */
/* Function: updateSourceFields                                                */
/* Purpose: Show only the input field group that matches the selected source  */
/*          type (url, raw_text, or linkedin_job_id); hide the others.       */
/* -------------------------------------------------------------------------- */
function updateSourceFields() {
  const sourceType = document.getElementById("source-type");
  const urlField = document.getElementById("url-field");
  const textField = document.getElementById("text-field");
  const linkedinField = document.getElementById("linkedin-field");

  if (!sourceType) {
    return;
  }

  urlField?.classList.add("hidden");
  textField?.classList.add("hidden");
  linkedinField?.classList.add("hidden");

  if (sourceType.value === "url") {
    urlField?.classList.remove("hidden");
    return;
  }

  if (sourceType.value === "raw_text") {
    textField?.classList.remove("hidden");
    return;
  }

  if (sourceType.value === "linkedin_job_id") {
    linkedinField?.classList.remove("hidden");
  }
}

/* -------------------------------------------------------------------------- */
/* Function: populateResumeSelect                                              */
/* Purpose: Fetch all resumes and rebuild the resume dropdown. Restores the   */
/*          last-used selection when possible; falls back to the first item.  */
/* -------------------------------------------------------------------------- */
async function populateResumeSelect() {
  const resumeSelect = document.getElementById("resume-select");

  if (!resumeSelect) {
    return;
  }

  const resumes = await listResumes();

  resumeSelect.innerHTML = "";

  if (!Array.isArray(resumes) || resumes.length === 0) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "No resumes available";
    option.disabled = true;
    option.selected = true;
    resumeSelect.appendChild(option);
    return false;
  }

  resumes.forEach((resume) => {
    const option = document.createElement("option");
    option.value = resume.resume_id;
    option.textContent = resume.name || "Untitled Resume";
    resumeSelect.appendChild(option);
  });

  const hasSavedSelection = resumes.some(
    (resume) => resume.resume_id === lastSelectedResumeId
  );

  if (hasSavedSelection) {
    resumeSelect.value = lastSelectedResumeId;
  } else {
    resumeSelect.value = resumes[0].resume_id;
    lastSelectedResumeId = resumes[0].resume_id;
  }
  return true;
}

/* -------------------------------------------------------------------------- */
/* Function: resetNewJobForm                                                   */
/* Purpose: Clear all new-job form fields and restore the default source type */
/*          (url), then update the visible source field group.                */
/* -------------------------------------------------------------------------- */
function resetNewJobForm() {
  document.getElementById("new-job-form")?.reset();

  const errEl = document.getElementById("new-job-submit-error");
  if (errEl) { errEl.textContent = ""; errEl.classList.add("hidden"); }

  const savedSourceType = getCookie("jobFilter_sourceType") || "linkedin_job_id";
  document.getElementById("source-type").value = savedSourceType;
  document.getElementById("job-url").value = "";
  document.getElementById("job-description").value = "";
  document.getElementById("linkedin-job-ids").value = "";

  updateSourceFields();
}

/* -------------------------------------------------------------------------- */
/* Function: validateNewJobForm                                                */
/* Purpose: Collect and validate all new-job form inputs. Returns an object   */
/*          with isValid and an errors map keyed by field name.               */
/* -------------------------------------------------------------------------- */
function validateNewJobForm() {
  const errors = {};

  const resumeId = document.getElementById("resume-select")?.value.trim() || "";
  const sourceType = document.getElementById("source-type")?.value || "url";
  const jobUrl = document.getElementById("job-url")?.value.trim() || "";
  const jobDescription =
    document.getElementById("job-description")?.value.trim() || "";
  const linkedinRaw =
    document.getElementById("linkedin-job-ids")?.value.trim() || "";

  const resumeSelect = document.getElementById("resume-select");
  const hasAvailableResumes = Array.from(resumeSelect?.options || []).some((option) => option.value.trim() !== "");

  if (!resumeId) {
    if (hasAvailableResumes) {
      errors.resume = "You must select a resume.";
    } else {
    errors.resume = "Please add a resume with Manage Resumes.";
    }
  }

  if (sourceType === "url") {
  if (!jobUrl) {
    errors.jobUrl = "Job URL is required.";
  } else if (!isValidUrl(jobUrl)) {
    errors.jobUrl = "URL is invalid. Enter a valid http or https URL.";
  }
  }

  if (sourceType === "raw_text") {
    if (!jobDescription) {
      errors.jobDescription = "Job description is required.";
    } else if (jobDescription.length < 100) {
      errors.jobDescription = "Job description is too short.";
    }
  }

 if (sourceType === "linkedin_job_id") {
  const jobIds = parseLinkedInJobIds(linkedinRaw);

  if (jobIds.length === 0) {
    errors.linkedinJobIds = "Enter at least one LinkedIn job ID.";
  } else if (jobIds.length > 10) {
    errors.linkedinJobIds = "You can submit at most 10 LinkedIn job IDs at once.";
  } else if (!jobIds.every(isValidLinkedInJobId)) {
    errors.linkedinJobIds =
      "Each LinkedIn Job ID must be numeric and 7 to 12 digits long.";
  }
}

  return {
    isValid: Object.keys(errors).length === 0,
    errors
  };
}

/* -------------------------------------------------------------------------- */
/* Function: parseLinkedInJobIds                                               */
/* Purpose: Split newline-separated input into a trimmed array of job ID      */
/*          strings, discarding blank lines.                                  */
/* -------------------------------------------------------------------------- */
function parseLinkedInJobIds(value) {
  return value
    .split(/\n+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

/* -------------------------------------------------------------------------- */
/* Function: isValidLinkedInJobId                                              */
/* Purpose: Validate that a LinkedIn job ID is purely numeric and 7–12 digits.*/
/* -------------------------------------------------------------------------- */
function isValidLinkedInJobId(value) {
  return /^\d{7,12}$/.test(value);
}


/* -------------------------------------------------------------------------- */
/* Function: renderNewJobFormErrors                                            */
/* Purpose: Map the errors object from validateNewJobForm to the corresponding*/
/*          inline error elements in the DOM.                                 */
/* -------------------------------------------------------------------------- */
function renderNewJobFormErrors(errors) {
  setFieldError("resume-error", errors.resume);
  setFieldError("job-url-error", errors.jobUrl);
  setFieldError("job-description-error", errors.jobDescription);
  setFieldError("linkedin-job-ids-error", errors.linkedinJobIds);
}

function clearNewJobFormErrors() {
  renderNewJobFormErrors({});
}

/* -------------------------------------------------------------------------- */
/* Function: setFieldError                                                     */
/* Purpose: Show or hide an inline error element. When message is truthy the  */
/*          element is revealed; when falsy it is cleared and hidden.         */
/* -------------------------------------------------------------------------- */
function setFieldError(elementId, message) {
  const element = document.getElementById(elementId);

  if (!element) {
    return;
  }

  if (message) {
    element.textContent = message;
    element.classList.remove("hidden");
  } else {
    element.textContent = "";
    element.classList.add("hidden");
  }
}

/* -------------------------------------------------------------------------- */
/* Function: updateNewJobFormValidation                                        */
/* Purpose: Run live validation on every input change and enable or disable   */
/*          the submit button based on the result.                            */
/* -------------------------------------------------------------------------- */
function updateNewJobFormValidation() {
  const validation = validateNewJobForm();

  renderNewJobFormErrors(validation.errors);

  const submitButton = document.getElementById("submit-new-job");

  if (submitButton) {
    submitButton.disabled = !validation.isValid;
  }
}

/* -------------------------------------------------------------------------- */
/* Function: isValidUrl                                                        */
/* Purpose: Return true only if the value is a well-formed http or https URL. */
/* -------------------------------------------------------------------------- */
function isValidUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

/* -------------------------------------------------------------------------- */
/* Function: scheduleAutoRefresh                                               */
/* Purpose: If any job is still pending (submitted/Scoring), schedule a       */
/*          15-second refresh. Clears any existing timer first so manual      */
/*          refreshes reset the countdown rather than stacking timers.        */
/*          Stops automatically once all jobs reach a terminal status.        */
/* -------------------------------------------------------------------------- */
function scheduleAutoRefresh() {
  if (autoRefreshTimer !== null) {
    clearTimeout(autoRefreshTimer);
    autoRefreshTimer = null;
  }
  if (countdownInterval !== null) {
    clearInterval(countdownInterval);
    countdownInterval = null;
  }

  const indicator = document.getElementById("auto-refresh-indicator");
  const text = document.getElementById("auto-refresh-text");
  const spinner = indicator?.querySelector(".spinner");

  if (hasPendingJobs()) {
    spinner?.classList.remove("hidden");
    indicator?.classList.remove("hidden");

    let remaining = AUTO_REFRESH_SECONDS;
    if (text) text.textContent = `Auto-refreshing in ${remaining}s...`;

    countdownInterval = setInterval(() => {
      remaining -= 1;
      if (text) text.textContent = `Auto-refreshing in ${remaining}s...`;
    }, 1000);

    autoRefreshTimer = setTimeout(() => {
      clearInterval(countdownInterval);
      countdownInterval = null;
      autoRefreshTimer = null;
      refreshApp();
    }, AUTO_REFRESH_SECONDS * 1000);
  } else {
    indicator?.classList.add("hidden");
  }
}

/* -------------------------------------------------------------------------- */
/* Function: refreshApp                                                        */
/* Purpose: Reload the job list from the API and re-render the table.         */
/*          Disables the refresh button while in-flight, then schedules an    */
/*          auto-refresh if any jobs are still pending.                       */
/* -------------------------------------------------------------------------- */
async function refreshApp() {
  // Stop any running countdown before fetching.
  if (countdownInterval !== null) {
    clearInterval(countdownInterval);
    countdownInterval = null;
  }

  const refreshButton = document.getElementById("btn-refresh");
  const table = document.getElementById("jobs-table");

  try {
    if (refreshButton) refreshButton.disabled = true;
    table?.classList.add("loading");

    await loadJobs();
    await updateTokenUsage();
  } catch (error) {
    console.error("Failed to refresh dashboard:", error);
    await showAlert(`Failed to refresh jobs: ${error.message}`, { title: "Error" });
  } finally {
    if (refreshButton) refreshButton.disabled = false;
    table?.classList.remove("loading");
    scheduleAutoRefresh();
  }
}

/* -------------------------------------------------------------------------- */
/* Function: submitJobScoringRequest                                           */
/* Purpose: Read the selected source type and dispatch the appropriate        */
/*          createJob call. LinkedIn job IDs are expanded into individual     */
/*          URL-based job submissions.                                        */
/* -------------------------------------------------------------------------- */
async function submitJobScoringRequest(onProgress = () => {}) {
  const resumeId  = document.getElementById("resume-select")?.value.trim() || "";
  const sourceType = document.getElementById("source-type")?.value || "url";
  const folderId   = document.getElementById("new-job-folder-select")?.value || null;
  const base       = { resume_id: resumeId, ...(folderId ? { folder_id: folderId } : {}) };

  if (sourceType === "url") {
    onProgress(1, 1);
    await createJob({
      ...base,
      source_type: "url",
      job_url: document.getElementById("job-url")?.value.trim() || "",
    });
    return;
  }

  if (sourceType === "raw_text") {
    onProgress(1, 1);
    await createJob({
      ...base,
      source_type: "raw_text",
      job_description: document.getElementById("job-description")?.value.trim() || "",
    });
    return;
  }

  if (sourceType === "linkedin_job_id") {
    const ids = (document.getElementById("linkedin-job-ids")?.value.trim() || "")
      .split("\n").map((id) => id.trim()).filter(Boolean);
    for (let i = 0; i < ids.length; i++) {
      onProgress(i + 1, ids.length);
      await createJob({
        ...base,
        source_type: "url",
        job_url: `https://www.linkedin.com/jobs/view/${ids[i]}`,
      });
    }
    return;
  }
}

/* -------------------------------------------------------------------------- */
/* Function: updateAuthButtons                                                 */
/* Purpose: Toggle sign-in/sign-out visibility and enable or disable action   */
/*          buttons based on whether the user is currently authenticated.     */
/* -------------------------------------------------------------------------- */
function updateAuthButtons() {
  const signIn = document.getElementById("btn-sign-in");
  const signOut = document.getElementById("btn-sign-out");

  const refresh = document.getElementById("btn-refresh");
  const scoreJob = document.getElementById("btn-new-job");
  const manageResumes = document.getElementById("btn-manage-resumes");

  const loggedIn = isLoggedIn();

  if (loggedIn) {
    signIn?.classList.add("hidden");
    signOut?.classList.remove("hidden");
    document.getElementById("filter-bar")?.classList.remove("hidden");

    refresh?.removeAttribute("disabled");
    scoreJob?.removeAttribute("disabled");
    manageResumes?.removeAttribute("disabled");
  } else {
    signIn?.classList.remove("hidden");
    signOut?.classList.add("hidden");
    document.getElementById("filter-bar")?.classList.add("hidden");
    // Reset token usage so it re-enters hidden state for the next login
    document.getElementById("token-usage")?.classList.add("hidden");

    refresh?.setAttribute("disabled", "true");
    scoreJob?.setAttribute("disabled", "true");
    manageResumes?.setAttribute("disabled", "true");
  }
}

/* ================================================================================
/* Folders
/* ================================================================================ */

/* -------------------------------------------------------------------------- */
/* Function: loadFolders                                                       */
/* Purpose: Fetch the folder list and repopulate the folder dropdown,         */
/*          preserving the current selection when it still exists.            */
/* -------------------------------------------------------------------------- */
async function loadFolders() {
  try {
    folders = await listFolders();
  } catch (_) {
    folders = [];
  }

  const select = document.getElementById("folder-select");
  if (!select) return;

  select.innerHTML = `<option value="">All Jobs</option>`;
  folders.forEach((f) => {
    const opt = document.createElement("option");
    opt.value       = f.folder_id;
    opt.textContent = f.name;
    select.appendChild(opt);
  });

  const stillValid = folders.some((f) => f.folder_id === currentFolderId);
  if (!stillValid) { currentFolderId = ""; setCookie("jobFilter_folder", ""); }
  select.value = currentFolderId;
  setFolderFilter(currentFolderId);
  updateDeleteFolderButton();
}

function updateDeleteFolderButton() {
  const btn = document.getElementById("btn-delete-folder");
  if (!btn) return;
  if (currentFolderId) btn.classList.remove("hidden");
  else                 btn.classList.add("hidden");
}

function populateJobFolderSelect() {
  const select = document.getElementById("new-job-folder-select");
  if (!select) return;
  select.innerHTML = `<option value="">No Folder</option>`;
  folders.forEach((f) => {
    const opt = document.createElement("option");
    opt.value       = f.folder_id;
    opt.textContent = f.name;
    select.appendChild(opt);
  });
  select.value = currentFolderId || "";
}

/* -------------------------------------------------------------------------- */
/* Function: restoreFilterState                                                */
/* Purpose: Read saved filter cookies and apply them to the filter bar and    */
/*          in-memory state before the first data load.                       */
/* -------------------------------------------------------------------------- */
function restoreFilterState() {
  const savedFolder = getCookie("jobFilter_folder");
  const savedStatus = getCookie("jobFilter_status");
  const savedSearch  = getCookie("jobFilter_search");

  if (savedFolder) currentFolderId = savedFolder;

  const statusEl = document.getElementById("filter-status");
  const searchEl = document.getElementById("filter-search");
  if (savedStatus && statusEl) { statusEl.value = savedStatus; setStatusFilter(savedStatus); }
  if (savedSearch  && searchEl) { searchEl.value = savedSearch;  setSearchFilter(savedSearch); }
}

/* ================================================================================
/* Cookie Helpers
/* ================================================================================ */

function setCookie(name, value) {
  const expires = new Date(Date.now() + 30 * 864e5).toUTCString();
  document.cookie = `${name}=${encodeURIComponent(value)}; expires=${expires}; path=/; SameSite=Lax`;
}

function getCookie(name) {
  return document.cookie.split("; ").reduce((found, part) => {
    const [k, v] = part.split("=");
    return k === name ? decodeURIComponent(v || "") : found;
  }, "");
}

/* -------------------------------------------------------------------------- */
/* Function: updateTokenUsage                                                  */
/* Purpose: Fetch the user's current token usage and update the SVG ring     */
/*          indicator in the filter bar. Swallows errors so it never blocks  */
/*          the dashboard from loading.                                       */
/* -------------------------------------------------------------------------- */
async function updateTokenUsage() {
  try {
    const data      = await getUsage();
    const used      = data?.tokens_used ?? 0;
    const limit     = data?.token_limit ?? 100000;
    const remaining = Math.max(0, limit - used);
    const usedPct   = limit > 0 ? Math.min((used / limit) * 100, 100) : 0;
    const leftPct   = 100 - usedPct;

    const arc     = document.getElementById("token-ring-arc");
    const label   = document.getElementById("token-usage-label");
    const display = document.getElementById("token-usage");
    if (!arc || !label) return;

    // Arc represents remaining tokens — starts full and depletes
    arc.setAttribute("stroke-dasharray", `${leftPct.toFixed(1)} ${usedPct.toFixed(1)}`);
    arc.classList.toggle("token-near-limit", usedPct >= 80);

    const fmt = (n) => n >= 1000 ? `${(n / 1000).toFixed(1)}K` : String(n);
    label.textContent = `${fmt(remaining)} / ${fmt(limit)}`;
    label.title       = `${used.toLocaleString()} of ${limit.toLocaleString()} tokens used (${usedPct.toFixed(1)}%)`;

    // Reveal only after data is populated — avoids showing an empty ring on load
    display?.classList.remove("hidden");
  } catch (_) {
    // Token display is non-critical — fail silently
  }
}

/* -------------------------------------------------------------------------- */
/* Function: showNotLoggedInMessage                                            */
/* Purpose: Hide the jobs table and replace the empty state with a sign-in   */
/*          prompt for unauthenticated visitors.                              */
/* -------------------------------------------------------------------------- */
function showNotLoggedInMessage() {
  const table = document.getElementById("jobs-table");
  const emptyState = document.getElementById("empty-state");

  table?.classList.add("hidden");

  if (emptyState) {
    emptyState.classList.remove("hidden");
    emptyState.innerHTML = `<p>Please sign in to use the application.</p>`;
  }

  // Auto-open the sign-in modal for unauthenticated visitors
  document.getElementById("sign-in-modal")?.classList.remove("hidden");
}
