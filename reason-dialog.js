import { addText } from './ui.js';

// Application dialogue: works without native browser prompts and retains failed input.
export function openReasonDialog({ title, explanation, loadPreview, submit, onSuccess, confirmLabel = 'Confirm resolution', inputLabel = 'Resolution reason (required)' }) {
  const dialog = document.createElement('dialog');
  dialog.className = 'fixture-correction-dialog reason-dialog';
  const form = document.createElement('form');
  const heading = addText(form, 'h2', title); heading.id = 'reason-dialog-title';
  dialog.setAttribute('aria-labelledby', heading.id);
  addText(form, 'p', explanation, 'field-help');
  const previewText = addText(form, 'p', '', 'field-help');
  const label = document.createElement('label'); label.textContent = inputLabel;
  const input = document.createElement('textarea'); input.rows = 4; input.required = true;
  input.minLength = 10; input.maxLength = 1000; label.append(input); form.append(label);
  const feedback = addText(form, 'p', '', 'admin-message'); feedback.setAttribute('role', 'status');
  const actions = document.createElement('div'); actions.className = 'processing-dialog-actions';
  const refresh = addText(actions, 'button', 'Refresh preview', 'nav-button'); refresh.type = 'button';
  const cancel = addText(actions, 'button', 'Cancel', 'nav-button'); cancel.type = 'button';
  const confirm = addText(actions, 'button', confirmLabel, 'primary-button'); confirm.type = 'submit';
  form.append(actions); dialog.append(form); document.body.append(dialog);
  let preview = null, busy = false, saving = false, closed = false;
  const setBusy = value => { busy = value; input.disabled = value; cancel.disabled = saving; refresh.disabled = value; confirm.disabled = value || !preview; };
  const close = () => { if (saving) return; closed = true; dialog.close(); dialog.remove(); };
  cancel.addEventListener('click', close);
  dialog.addEventListener('cancel', event => { event.preventDefault(); close(); });
  async function refreshPreview() {
    preview = null; setBusy(true); feedback.textContent = 'Loading the current review…';
    try {
      preview = await loadPreview();
      if (closed) return;
      previewText.textContent = preview.description || 'Existing outcomes and winners will be retained. The reason and administrator will be recorded.';
      feedback.textContent = '';
    } catch (error) { feedback.textContent = error.message; }
    finally { setBusy(false); }
  }
  refresh.addEventListener('click', refreshPreview);
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (busy || !preview) return;
    const reason = input.value.trim();
    if (reason.length < 10 || reason.length > 1000) { feedback.textContent = 'Enter a meaningful reason of 10–1000 characters.'; input.focus(); return; }
    saving = true; setBusy(true); feedback.textContent = 'Saving the decision…';
    try {
      await submit(reason, preview);
      saving = false; setBusy(false); close(); await onSuccess();
    } catch (error) {
      feedback.textContent = error.message;
      if (/state changed|not open|already resolved/i.test(error.message)) preview = null;
      saving = false; setBusy(false);
    }
  });
  dialog.showModal(); input.focus(); refreshPreview();
  return dialog;
}
