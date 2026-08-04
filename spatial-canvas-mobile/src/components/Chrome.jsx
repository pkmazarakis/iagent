import {
  ArrowLeft,
  ArrowClockwise,
  ArrowCounterClockwise,
  ArrowsOutSimple,
  CaretUp,
  Check,
  GridFour,
  Hash,
  NoteBlank,
  Plus,
  SlidersHorizontal,
  Stack,
} from "@phosphor-icons/react";
import { AnimatePresence, motion } from "motion/react";

const iconProps = { size: 15, weight: "regular" };

export function IconButton({ label, active = false, className = "", children, ...props }) {
  return (
    <button
      type="button"
      className={`icon-button ${active ? "is-active" : ""} ${className}`}
      aria-label={label}
      title={label}
      {...props}
    >
      {children}
    </button>
  );
}

export function AppChrome({
  detailOpen,
  integratedDetailHeader = false,
  backLabel = "Back to board",
  onBack,
  onAdd,
  onAutoOrganize,
  onOpenBoards,
  onOpenScratch,
  onToggleTheme,
  onUndo,
  onRedo,
  canUndo = false,
  canRedo = false,
  showAddInDetail = false,
  showExpandContainer = false,
  expandContainerLabel = "Open folder as its own canvas",
  onExpandContainer,
  theme = "light",
  boardTitle = "Spatial board",
}) {
  return (
    <div className="chrome-layer" aria-label="Spatial controls">
      <motion.div
        className={`chrome-top-left ${integratedDetailHeader ? "is-integrated-detail-header" : ""}`}
        layout
      >
        <AnimatePresence initial={false} mode="popLayout">
          {detailOpen ? (
            <motion.div
              key="back"
              initial={integratedDetailHeader
                ? { opacity: 0, scale: 1, x: -5 }
                : { opacity: 0, scale: 0.82, x: -8 }}
              animate={{ opacity: 1, scale: 1, x: 0 }}
              exit={integratedDetailHeader
                ? { opacity: 0, scale: 1, x: -5 }
                : { opacity: 0, scale: 0.82, x: -8 }}
              transition={integratedDetailHeader
                ? { duration: 0.16, ease: [0.16, 1, 0.3, 1] }
                : { type: "spring", stiffness: 520, damping: 34 }}
            >
              <IconButton label={backLabel} onClick={onBack} className="back-button">
                <ArrowLeft {...iconProps} size={integratedDetailHeader ? 18 : iconProps.size} />
              </IconButton>
            </motion.div>
          ) : (
            <motion.div
              key="modes"
              className="segmented-control"
              initial={{ opacity: 0, scale: 0.92 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.92 }}
            >
              <IconButton label="New note" onClick={() => onAdd?.("note")}>
                <NoteBlank {...iconProps} />
              </IconButton>
              <IconButton label="Labels" onClick={() => onAdd?.("label")}>
                <Hash {...iconProps} />
              </IconButton>
              <IconButton label="Tasks" onClick={() => onAdd?.("tasks")}>
                <Check {...iconProps} />
              </IconButton>
            </motion.div>
          )}
        </AnimatePresence>
        <span className="visually-hidden">{boardTitle}</span>
      </motion.div>

      <AnimatePresence initial={false}>
        {showExpandContainer && (
          <motion.div
            key="expand-container"
            className="chrome-top-right"
            data-inspection-control="true"
            initial={{ opacity: 0, scale: 0.82, x: 8 }}
            animate={{ opacity: 1, scale: 1, x: 0 }}
            exit={{ opacity: 0, scale: 0.82, x: 8 }}
            transition={{ type: "spring", stiffness: 520, damping: 34 }}
          >
            <IconButton
              label={expandContainerLabel}
              onClick={onExpandContainer}
              className="expand-container-button"
            >
              <ArrowsOutSimple {...iconProps} />
            </IconButton>
          </motion.div>
        )}
      </AnimatePresence>

      {!detailOpen && (
        <>
          <div className="chrome-bottom-left">
            <IconButton label="Auto-organize board" onClick={onAutoOrganize}>
              <GridFour {...iconProps} />
            </IconButton>
            <IconButton label="Open scratch pad" onClick={onOpenScratch}>
              <SlidersHorizontal {...iconProps} />
            </IconButton>
            <IconButton label="Undo" onClick={onUndo} disabled={!canUndo}>
              <ArrowCounterClockwise {...iconProps} />
            </IconButton>
            <IconButton label="Redo" onClick={onRedo} disabled={!canRedo}>
              <ArrowClockwise {...iconProps} />
            </IconButton>
          </div>

          <div className="chrome-bottom-right">
            <button type="button" className="workspace-button" onClick={onOpenBoards}>
              <Stack {...iconProps} />
              <CaretUp size={11} weight="bold" />
              <span className="visually-hidden">Open boards</span>
            </button>
            <IconButton label="Add to board" onClick={() => onAdd?.("menu")} className="add-button">
              <Plus {...iconProps} />
            </IconButton>
          </div>

          <button
            type="button"
            className="theme-toggle-hitbox"
            onClick={onToggleTheme}
            aria-label={`Use ${theme === "light" ? "dark" : "light"} canvas`}
            title="Switch canvas theme"
          />
        </>
      )}

      {detailOpen && showAddInDetail && (
        <div className="chrome-bottom-right">
          <IconButton label="Add inside folder" onClick={() => onAdd?.("menu")} className="add-button">
            <Plus {...iconProps} />
          </IconButton>
        </div>
      )}
    </div>
  );
}
