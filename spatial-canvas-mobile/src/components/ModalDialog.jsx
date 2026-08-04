import { X } from "@phosphor-icons/react";
import { motion } from "motion/react";
import { useId } from "react";

const MODAL_EASE = [0.22, 1, 0.36, 1];

export function ModalDialog({
  title,
  description,
  onClose,
  closeDisabled = false,
  className = "",
  children,
}) {
  const titleId = useId();
  const descriptionId = useId();

  return (
    <motion.div
      className="app-modal-layer"
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.14, ease: MODAL_EASE }}
    >
      <button
        type="button"
        className="app-modal-backdrop"
        onClick={onClose}
        disabled={closeDisabled}
        aria-label={`Close ${title}`}
      />
      <motion.section
        className={`app-modal-panel${className ? ` ${className}` : ""}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={description ? descriptionId : undefined}
        initial={{ opacity: 0, y: 8, scale: 0.985 }}
        animate={{ opacity: 1, y: 0, scale: 1 }}
        exit={{ opacity: 0, y: 6, scale: 0.985 }}
        transition={{ duration: 0.16, ease: MODAL_EASE }}
        onKeyDown={(event) => {
          if (event.key !== "Escape" || closeDisabled) return;
          event.stopPropagation();
          onClose?.();
        }}
      >
        <header className="app-modal-header">
          <span className="app-modal-heading">
            <strong id={titleId}>{title}</strong>
            {description && <small id={descriptionId}>{description}</small>}
          </span>
          <button
            type="button"
            className="app-modal-close"
            onClick={onClose}
            disabled={closeDisabled}
            aria-label={`Close ${title}`}
          >
            <X size={14} />
          </button>
        </header>
        <div className="app-modal-content">{children}</div>
      </motion.section>
    </motion.div>
  );
}
