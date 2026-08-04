import { FileArrowUp, LinkSimple } from "@phosphor-icons/react";
import { AnimatePresence } from "motion/react";
import { useEffect, useId, useState } from "react";
import { ModalDialog } from "./ModalDialog.jsx";

const GOOGLE_LINK_PLACEHOLDER = "Paste a Google Docs, Slides, Sheets, or Drive link";

export function DocumentImportDialog({
  open,
  onClose,
  onPickFile,
  onImportGoogleLink,
  busy = false,
  error = "",
}) {
  const [googleLink, setGoogleLink] = useState("");
  const linkId = useId();
  const errorId = useId();

  useEffect(() => {
    if (!open) setGoogleLink("");
  }, [open]);

  const trimmedLink = googleLink.trim();

  return (
    <AnimatePresence>
      {open && (
        <ModalDialog
          title="Add document"
          description="Upload an Office file or link a Google document."
          className="document-import-modal"
          onClose={onClose}
          closeDisabled={busy}
        >
          <div className="document-import-options">
            <button
              type="button"
              className="document-import-upload"
              onClick={onPickFile}
              disabled={busy}
            >
              <span className="document-import-option-icon" aria-hidden="true">
                <FileArrowUp size={18} />
              </span>
              <span className="document-import-option-copy">
                <strong>{busy ? "Importing…" : "Upload a file"}</strong>
                <small>Word, PowerPoint, or Excel</small>
              </span>
            </button>

            <form
              className="document-import-link-form"
              onSubmit={(event) => {
                event.preventDefault();
                if (!trimmedLink || busy) return;
                onImportGoogleLink?.(trimmedLink);
              }}
            >
              <label className="app-modal-field-label" htmlFor={linkId}>
                Google Workspace link
              </label>
              <div className="app-modal-input-row document-import-link-row">
                <LinkSimple size={15} aria-hidden="true" />
                <input
                  id={linkId}
                  className="document-import-link-input"
                  type="url"
                  inputMode="url"
                  autoComplete="url"
                  placeholder={GOOGLE_LINK_PLACEHOLDER}
                  value={googleLink}
                  onChange={(event) => setGoogleLink(event.target.value)}
                  disabled={busy}
                  aria-invalid={Boolean(error)}
                  aria-describedby={error ? errorId : undefined}
                />
                <button
                  type="submit"
                  disabled={!trimmedLink || busy}
                >
                  {busy ? "Adding…" : "Add"}
                </button>
              </div>
            </form>
          </div>

          {error && (
            <p id={errorId} className="app-modal-error" role="alert">
              {error}
            </p>
          )}
        </ModalDialog>
      )}
    </AnimatePresence>
  );
}
