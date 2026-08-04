export function wheelRoutingMode({ detailOpen, withinDetailScrollRegion }) {
  if (!detailOpen) return "canvas";
  return withinDetailScrollRegion ? "native" : "blocked";
}
