export function ArtifactTitleOverlay({ eyebrow, title, tone = "light", visible = true }) {
  return (
    <div
      className={`artifact-title-overlay tone-${tone === "dark" ? "dark" : "light"} ${visible ? "is-visible" : "is-hidden"}`}
      aria-hidden="true"
    >
      {eyebrow && <span>{eyebrow}</span>}
      <strong>{title || "Untitled"}</strong>
    </div>
  );
}
