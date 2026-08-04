import { AnimatePresence, motion } from "motion/react";

export const SPATIAL_COLORS = [
  { name: "Coral", value: "#ff5e49" },
  { name: "Orange", value: "#ff8b42" },
  { name: "Yellow", value: "#ffe34d" },
  { name: "Lime", value: "#c9f629" },
  { name: "Green", value: "#26e16f" },
  { name: "Mint", value: "#57ebbd" },
  { name: "Cyan", value: "#24d9dd" },
  { name: "Azure", value: "#48b8ff" },
  { name: "Blue", value: "#298cff" },
  { name: "Indigo", value: "#6e68ff" },
  { name: "Violet", value: "#9c55ff" },
  { name: "Magenta", value: "#d345ff" },
];

const INNER_COLORS = [
  { name: "Blush", value: "#ffb2aa" },
  { name: "Cream", value: "#fff0b2" },
  { name: "Pear", value: "#dbf99c" },
  { name: "Seafoam", value: "#a4f3db" },
  { name: "Ice", value: "#aeefff" },
  { name: "Periwinkle", value: "#bfc6ff" },
  { name: "Lavender", value: "#ddbdff" },
  { name: "Rose", value: "#ffb9e3" },
];

const SWATCHES = [
  ...SPATIAL_COLORS.map((color, index) => ({ ...color, ring: "outer", index, count: SPATIAL_COLORS.length })),
  ...INNER_COLORS.map((color, index) => ({ ...color, ring: "inner", index, count: INNER_COLORS.length })),
];

export function RadialColorPicker({ open, value, onPreview, onCommit, onCancel }) {
  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="radial-picker"
          initial={{ opacity: 0, scale: 0.38, y: 16, rotate: -12 }}
          animate={{ opacity: 1, scale: 1, y: 0, rotate: 0 }}
          exit={{ opacity: 0, scale: 0.48, y: 10 }}
          transition={{ type: "spring", stiffness: 470, damping: 29, mass: 0.7 }}
          role="listbox"
          aria-label="Note color"
          onPointerLeave={() => onPreview?.(value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") onCancel?.();
          }}
        >
          <div className="radial-picker-halo" style={{ "--picker-color": value }} />
          {SWATCHES.map((color, animationIndex) => {
            const radius = color.ring === "outer" ? 43 : 22;
            const angle = ((Math.PI * 2) / color.count) * color.index - Math.PI / 2 + (color.ring === "inner" ? Math.PI / 8 : 0);
            const x = Math.cos(angle) * radius;
            const y = Math.sin(angle) * radius;
            return (
              <motion.button
                type="button"
                key={color.value}
                className={`color-petal ${value === color.value ? "is-current" : ""}`}
                style={{ background: color.value, x, y, "--petal-size": color.ring === "outer" ? "27px" : "25px" }}
                aria-label={color.name}
                role="option"
                aria-selected={value === color.value}
                initial={{ x: 0, y: 0, opacity: 0 }}
                animate={{ x, y, opacity: 1 }}
                transition={{ type: "spring", stiffness: 480, damping: 28, delay: animationIndex * 0.008 }}
                onPointerEnter={() => onPreview?.(color.value)}
                onFocus={() => onPreview?.(color.value)}
                onPointerDown={(event) => event.stopPropagation()}
                onClick={() => onCommit?.(color.value)}
              />
            );
          })}
          <button
            type="button"
            className="color-petal-center"
            aria-label="Neutral"
            onPointerEnter={() => onPreview?.("#f7f8f3")}
            onClick={() => onCommit?.("#f7f8f3")}
          />
        </motion.div>
      )}
    </AnimatePresence>
  );
}
