import {
  CopySimple,
  CornersIn,
  DownloadSimple,
  Drop,
  Folder,
  FolderOpen,
  GridFour,
  PencilSimple,
  Stack,
  Trash,
} from "@phosphor-icons/react";
import { AnimatePresence, LayoutGroup, motion, useReducedMotion } from "motion/react";
import { IconButton } from "./Chrome.jsx";

export const TOOLBAR_LAYOUT_TRANSITION = Object.freeze({
  type: "spring",
  stiffness: 470,
  damping: 40,
  mass: 0.68,
  restDelta: 0.25,
  restSpeed: 0.5,
});

const TOOLBAR_BUTTON_TRANSITION = Object.freeze({
  type: "spring",
  stiffness: 520,
  damping: 38,
  mass: 0.6,
});

const actions = {
  copy: { label: "Duplicate", Icon: CopySimple },
  stack: { label: "Create stack", Icon: Stack },
  grid: { label: "Arrange in grid", Icon: GridFour },
  download: { label: "Export", Icon: DownloadSimple },
  color: { label: "Color", Icon: Drop },
  unpack: { label: "Unpack stack", Icon: Stack },
  unpackFolder: { label: "Dissolve folder", Icon: FolderOpen },
  folder: { label: "Add to folder", Icon: Folder },
  open: { label: "Open folder", Icon: FolderOpen },
  rename: { label: "Rename folder", Icon: PencilSimple },
  trash: { label: "Delete", Icon: Trash },
  focus: { label: "Focus selection", Icon: CornersIn },
};

export function toolbarActionsFor({ selectedCount, selectedKind, canColor }) {
  if (selectedCount <= 0) return [];
  if (selectedKind === "folder") return ["open", "rename", "focus", "unpackFolder", "trash"];
  if (selectedKind === "stack") return ["unpack", "focus", "trash"];
  if (selectedCount > 1) return ["copy", "focus", "stack", "folder", "grid", "color", "trash"];
  if (canColor) return ["copy", "focus", "color", "folder", "trash"];
  return ["focus", "folder", "trash"];
}

export function ContextToolbar({
  selectedCount,
  canColor = false,
  selectedKind = null,
  colorOpen = false,
  onAction,
  children,
}) {
  const reducedMotion = useReducedMotion();
  const visibleActions = toolbarActionsFor({ selectedCount, selectedKind, canColor });
  const actionSignature = visibleActions.join("|");

  return (
    <LayoutGroup id="context-toolbar-layout">
      <AnimatePresence>
        {selectedCount > 0 && (
          <motion.div
            className="context-toolbar-wrap"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.14 }}
          >
            <motion.div
              className="context-toolbar-motion"
              layout
              layoutDependency={actionSignature}
              initial={{ y: 24, scale: 0.88 }}
              animate={{ y: 0, scale: 1 }}
              exit={{ y: 18, scale: 0.9 }}
              transition={{
                type: "spring",
                stiffness: 520,
                damping: 34,
                mass: 0.72,
                layout: reducedMotion ? { duration: 0 } : TOOLBAR_LAYOUT_TRANSITION,
              }}
            >
              {children}
              <motion.div
                className="context-toolbar"
                data-action-count={visibleActions.length}
                data-action-signature={actionSignature}
                layout="size"
                layoutDependency={actionSignature}
                transition={{ layout: reducedMotion ? { duration: 0 } : TOOLBAR_LAYOUT_TRANSITION }}
              >
                <AnimatePresence initial={false} mode="popLayout">
                  {visibleActions.map((key, index) => {
                    const { label, Icon } = actions[key];
                    const enterDelay = reducedMotion ? 0 : Math.min(index * 0.018, 0.07);
                    return (
                      <motion.div
                        key={key}
                        className="context-toolbar-slot"
                        layout="position"
                        initial={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: 0.86, y: 4 }}
                        animate={{
                          opacity: 1,
                          scale: 1,
                          y: 0,
                          transition: reducedMotion
                            ? { duration: 0.08 }
                            : { ...TOOLBAR_BUTTON_TRANSITION, delay: enterDelay },
                        }}
                        exit={{
                          opacity: 0,
                          scale: reducedMotion ? 1 : 0.86,
                          y: reducedMotion ? 0 : 2,
                          transition: { duration: reducedMotion ? 0.06 : 0.1, ease: "easeIn" },
                        }}
                        transition={{ layout: reducedMotion ? { duration: 0 } : TOOLBAR_LAYOUT_TRANSITION }}
                      >
                        <IconButton
                          label={label}
                          active={key === "color" && colorOpen}
                          onClick={() => onAction?.(key)}
                          className="toolbar-button"
                        >
                          <Icon size={16} weight="regular" />
                        </IconButton>
                      </motion.div>
                    );
                  })}
                </AnimatePresence>
              </motion.div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </LayoutGroup>
  );
}
