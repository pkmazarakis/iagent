export const DETAIL_SHEET_SPRING = {
  type: "spring",
  stiffness: 420,
  damping: 38,
  mass: 0.72,
  restDelta: 0.5,
  restSpeed: 1,
};

export const DETAIL_RADIUS_TRANSITION = {
  duration: 0.68,
  ease: [0.16, 1, 0.3, 1],
};

export const ITEM_LAYOUT_TRANSITION = Object.freeze({
  type: "spring",
  stiffness: 310,
  damping: 36,
  mass: 0.82,
  restDelta: 0.35,
  restSpeed: 0.6,
});

export const STACK_STAGGER_SECONDS = 0.036;

export const CAMERA_FOCUS_TRANSITION = Object.freeze({
  type: "tween",
  duration: 0.72,
  ease: [0.16, 1, 0.3, 1],
});
