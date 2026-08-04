import {
  ArrowRight,
  FileText,
  Folder,
  FolderOpen,
  Image,
  LinkSimple,
  NoteBlank,
  Plus,
  Stack,
  X,
} from "@phosphor-icons/react";
import { AnimatePresence, motion } from "motion/react";

const options = [
  { kind: "note", label: "Sticky note", Icon: NoteBlank, shortcut: "N" },
  { kind: "document", label: "Document", Icon: FileText, shortcut: "D" },
  { kind: "image", label: "Image", Icon: Image, shortcut: "I" },
  { kind: "web", label: "Web clip", Icon: LinkSimple, shortcut: "W" },
  { kind: "stack", label: "Stack selection", Icon: Stack, shortcut: "S" },
  { kind: "folder", label: "New folder", Icon: Folder, shortcut: "F" },
];

export function AddMenu({ open, onChoose, onClose, hiddenKinds = [] }) {
  const hidden = new Set(hiddenKinds);
  return (
    <AnimatePresence>
      {open && (
        <>
          <button type="button" className="overlay-dismiss" onClick={onClose} aria-label="Close add menu" />
          <motion.div
            className="add-menu"
            initial={{ opacity: 0, y: 14, scale: 0.9 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 10, scale: 0.92 }}
            transition={{ type: "spring", stiffness: 520, damping: 34 }}
          >
            {options.filter(({ kind }) => !hidden.has(kind)).map(({ kind, label, Icon, shortcut }) => (
              <button type="button" key={kind} onClick={() => onChoose?.(kind)}>
                <Icon size={16} />
                <span>{label}</span>
                <kbd>{shortcut}</kbd>
              </button>
            ))}
          </motion.div>
        </>
      )}
    </AnimatePresence>
  );
}

export function FolderPicker({
  open,
  folders = [],
  selectedCount = 0,
  currentFolderId = null,
  onChoose,
  onCreate,
  onRemove,
  onClose,
}) {
  return (
    <AnimatePresence>
      {open && (
        <>
          <button type="button" className="overlay-dismiss" onClick={onClose} aria-label="Close folder picker" />
          <motion.section
            className="folder-picker"
            role="dialog"
            aria-modal="true"
            aria-label="Add selected items to a folder"
            initial={{ opacity: 0, y: 14, scale: 0.94 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 10, scale: 0.96 }}
            transition={{ type: "spring", stiffness: 500, damping: 38, mass: 0.78 }}
          >
            <header>
              <span><strong>Add to folder</strong><small>{selectedCount} selected</small></span>
              <button type="button" onClick={onClose} aria-label="Close folder picker"><X size={14} /></button>
            </header>
            <div className="folder-picker-list">
              {folders.map((folder) => (
                <button
                  type="button"
                  key={folder.id}
                  className={folder.id === currentFolderId ? "is-current" : ""}
                  disabled={folder.id === currentFolderId}
                  onClick={() => onChoose?.(folder.id)}
                >
                  <span className="folder-picker-icon"><FolderOpen size={16} /></span>
                  <span><strong>{folder.title || "Untitled folder"}</strong><small>{folder.count} {folder.count === 1 ? "item" : "items"}</small></span>
                  <ArrowRight size={13} />
                </button>
              ))}
              {!folders.length && <p>No folders yet. Create one for this selection.</p>}
            </div>
            <footer>
              {currentFolderId && (
                <button type="button" className="folder-picker-remove" onClick={onRemove}>
                  Remove from current folder
                </button>
              )}
              <button type="button" className="folder-picker-create" onClick={onCreate}>
                <Plus size={14} /> New folder with selection
              </button>
            </footer>
          </motion.section>
        </>
      )}
    </AnimatePresence>
  );
}

export function ScratchPad({ open, onClose, onSave }) {
  return (
    <AnimatePresence>
      {open && (
        <motion.div className="scratch-overlay" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
          <button type="button" className="overlay-dismiss" onClick={onClose} aria-label="Close scratch pad" />
          <motion.form
            className="scratch-pad"
            initial={{ opacity: 0, scale: 0.86, y: 22 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.92, y: 10 }}
            transition={{ type: "spring", stiffness: 430, damping: 32 }}
            onSubmit={(event) => {
              event.preventDefault();
              const value = new FormData(event.currentTarget).get("scratch")?.toString().trim();
              if (value) onSave?.(value);
              onClose?.();
            }}
          >
            <label htmlFor="scratch-input">Catch a thought</label>
            <textarea id="scratch-input" name="scratch" autoFocus placeholder="Type anything…" />
            <div className="scratch-footer">
              <span>Option + Space</span>
              <button type="submit">Add to space <kbd>⌘↵</kbd></button>
            </div>
          </motion.form>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
