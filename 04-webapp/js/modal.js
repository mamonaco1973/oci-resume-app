/* ========================================================================== */
/* modal.js                                                                    */
/* Promise-based styled modal replacements for window.alert / confirm /       */
/* prompt. Each function returns a Promise that resolves when dismissed.      */
/* ========================================================================== */

function el(id) { return document.getElementById(id); }

/* -------------------------------------------------------------------------- */
/* Function: showAlert                                                          */
/* Purpose: Display a styled alert modal; resolves when the user clicks OK.  */
/* -------------------------------------------------------------------------- */
export function showAlert(message, { title = "Notice" } = {}) {
  return new Promise((resolve) => {
    el("alert-modal-title").textContent   = title;
    el("alert-modal-message").textContent = message;
    el("alert-modal").classList.remove("hidden");
    el("alert-modal-ok").focus();

    function close() {
      el("alert-modal").classList.add("hidden");
      document.removeEventListener("keydown", onKey);
      resolve();
    }

    function onKey(e) { if (e.key === "Escape" || e.key === "Enter") close(); }
    document.addEventListener("keydown", onKey);
    el("alert-modal-ok").onclick = close;
  });
}

/* -------------------------------------------------------------------------- */
/* Function: showConfirm                                                        */
/* Purpose: Display a styled confirm modal; resolves true on confirm,         */
/*          false on cancel or Escape.                                         */
/* -------------------------------------------------------------------------- */
export function showConfirm(message, {
  title       = "Confirm",
  confirmText = "Confirm",
  danger      = false,
} = {}) {
  return new Promise((resolve) => {
    el("confirm-modal-title").textContent   = title;
    el("confirm-modal-message").textContent = message;

    const okBtn = el("confirm-modal-ok");
    okBtn.textContent = confirmText;
    okBtn.className   = danger ? "danger" : "";

    el("confirm-modal").classList.remove("hidden");
    el("confirm-modal-cancel").focus();

    function close(result) {
      el("confirm-modal").classList.add("hidden");
      document.removeEventListener("keydown", onKey);
      resolve(result);
    }

    function onKey(e) { if (e.key === "Escape") close(false); }
    document.addEventListener("keydown", onKey);
    okBtn.onclick                      = () => close(true);
    el("confirm-modal-cancel").onclick = () => close(false);
  });
}

/* -------------------------------------------------------------------------- */
/* Function: showPrompt                                                         */
/* Purpose: Display a styled prompt modal with a text input; resolves with    */
/*          the trimmed string on OK, or null on cancel / Escape.             */
/* -------------------------------------------------------------------------- */
export function showPrompt(label, {
  title       = "Enter Value",
  placeholder = "",
  confirmText = "OK",
} = {}) {
  return new Promise((resolve) => {
    el("prompt-modal-title").textContent = title;
    el("prompt-modal-label").textContent = label;

    const input = el("prompt-modal-input");
    const okBtn = el("prompt-modal-ok");
    input.value       = "";
    input.placeholder = placeholder;
    okBtn.textContent = confirmText;
    okBtn.disabled    = true;

    el("prompt-modal").classList.remove("hidden");
    input.focus();

    // Enable OK only when input has content
    input.oninput = () => { okBtn.disabled = !input.value.trim(); };

    function close(value) {
      el("prompt-modal").classList.add("hidden");
      document.removeEventListener("keydown", onKey);
      input.oninput = null;
      resolve(value);
    }

    function onKey(e) {
      if (e.key === "Escape") close(null);
      if (e.key === "Enter" && input.value.trim()) close(input.value.trim());
    }

    document.addEventListener("keydown", onKey);
    okBtn.onclick                      = () => close(input.value.trim());
    el("prompt-modal-cancel").onclick  = () => close(null);
  });
}
