import { ArrowUp, Check, GlobeSimple } from "@phosphor-icons/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { motion } from "motion/react";
import { screenshotCandidatesForItem, webClipDisplayUrl } from "../import/webClip.js";
import { sampleImageBottomTone } from "./artifactTone.js";

const WEB_PREVIEW_TIMEOUT_MS = 10_000;
const workingScreenshotByPage = new Map();

function responsiveImageProps(source) {
  if (typeof source !== "string" || !/\/assets\/images\/use-case-[^/]+\.jpg(?:\?.*)?$/.test(source)) {
    return { src: source };
  }
  const base = source.replace(/\.jpg(?:\?.*)?$/, "");
  return {
    src: `${base}-640.jpg`,
    srcSet: `${base}-640.jpg 640w, ${base}-1280.jpg 1280w, ${source} 2268w`,
    sizes: "(max-width: 640px) 100vw, (max-width: 1440px) 70vw, 1280px",
  };
}

function TaskLines({ tasks = [] }) {
  return (
    <ul className="task-lines">
      {tasks.slice(0, 7).map((task, index) => (
        <li key={`${task.text}-${index}`} className={task.done ? "is-done" : ""}>
          <span className="task-check">{task.done && <Check size={7} weight="bold" />}</span>
          <span>{task.text}</span>
        </li>
      ))}
    </ul>
  );
}

function DocumentPreview({ item }) {
  return (
    <div className="document-preview">
      {item.eyebrow && <span className="card-eyebrow">{item.eyebrow}</span>}
      <h3>{item.title}</h3>
      {item.subtitle && <p className="document-lead">{item.subtitle}</p>}
      {item.tasks?.length ? <TaskLines tasks={item.tasks} /> : <p>{item.excerpt || item.body}</p>}
      <div className="document-filler" aria-hidden="true">
        <span /><span /><span /><span />
      </div>
    </div>
  );
}

function NotePreview({ item }) {
  return (
    <div className="note-preview">
      {item.title && <h3>{item.title}</h3>}
      {item.tasks?.length ? <TaskLines tasks={item.tasks} /> : <p>{item.body || item.excerpt}</p>}
    </div>
  );
}

export function ImagePreview({ item }) {
  const source = responsiveImageProps(item.image);
  return (
    <div className="image-preview">
      <img {...source} alt={item.alt || item.title || "Visual reference"} draggable="false" loading="lazy" decoding="async" />
      {item.caption && <span className="image-caption">{item.caption}</span>}
    </div>
  );
}

export function WebPreview({ item, interactive = false, loadAsset, onScreenshotResolved, onToneChange }) {
  const assetId = item.screenshotAssetId || "";
  const [assetPreview, setAssetPreview] = useState(() => ({
    assetId,
    status: assetId ? "loading" : "none",
    url: "",
  }));

  useEffect(() => {
    let cancelled = false;
    let objectUrl = "";
    if (!assetId || typeof loadAsset !== "function") {
      setAssetPreview({ assetId, status: "none", url: "" });
      return undefined;
    }
    setAssetPreview({ assetId, status: "loading", url: "" });
    Promise.resolve(loadAsset(assetId))
      .then((asset) => {
        if (!asset?.blob || !(asset.blob instanceof Blob) || !asset.blob.type.startsWith("image/")) {
          throw new Error("Cached screenshot is missing");
        }
        objectUrl = URL.createObjectURL(asset.blob);
        if (cancelled) {
          URL.revokeObjectURL(objectUrl);
          objectUrl = "";
          return;
        }
        // Let the retained DOM image perform the only decode. A separate
        // `new Image()` probe decoded every cached screenshot twice, which
        // became especially expensive when a page of web clips entered the
        // overscan window together.
        setAssetPreview({ assetId, status: "ready", url: objectUrl });
      })
      .catch(() => {
        if (!cancelled) setAssetPreview({ assetId, status: "missing", url: "" });
      });
    return () => {
      cancelled = true;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [assetId, loadAsset]);

  const currentAsset = assetPreview.assetId === assetId
    ? assetPreview
    : { assetId, status: assetId ? "loading" : "none", url: "" };
  const remoteCandidates = useMemo(() => screenshotCandidatesForItem(item), [
    item.url,
    item.screenshotUrl,
    item.image,
    item.screenshotCandidates,
  ]);
  const assetPending = currentAsset.status === "loading";
  const candidates = useMemo(() => {
    const derived = remoteCandidates;
    const remembered = workingScreenshotByPage.get(item.url);
    const orderedRemote = remembered && derived.includes(remembered)
      ? [remembered, ...derived.filter((candidate) => candidate !== remembered)]
      : derived;
    return currentAsset.status === "ready" && currentAsset.url
      ? [currentAsset.url, ...orderedRemote]
      : orderedRemote;
  }, [currentAsset.status, currentAsset.url, item.url, remoteCandidates]);
  const candidateKey = JSON.stringify([
    assetId,
    currentAsset.status,
    currentAsset.url,
    item.url,
    item.screenshotUrl,
    item.image,
    item.screenshotCandidates,
  ]);
  const [candidateIndex, setCandidateIndex] = useState(0);
  const [retryRevision, setRetryRevision] = useState(0);
  const [recoveryPass, setRecoveryPass] = useState(0);
  const [loadedScreenshot, setLoadedScreenshot] = useState("");
  const [imageState, setImageState] = useState(assetPending || candidates.length ? "loading" : "error");
  const screenshot = candidates[candidateIndex] || "";

  useEffect(() => {
    const retainedIndex = loadedScreenshot ? candidates.indexOf(loadedScreenshot) : -1;
    const readyAssetIndex = currentAsset.status === "ready" && currentAsset.url
      ? candidates.indexOf(currentAsset.url)
      : -1;
    setCandidateIndex(readyAssetIndex >= 0 ? readyAssetIndex : (retainedIndex >= 0 ? retainedIndex : 0));
    setRetryRevision(0);
    setRecoveryPass(0);
    setImageState(retainedIndex >= 0
      ? "ready"
      : (assetPending || candidates.length ? "loading" : "error"));
  }, [assetPending, candidateKey, candidates, currentAsset.status, currentAsset.url, loadedScreenshot]);

  const tryNextCandidate = useCallback(() => {
    setCandidateIndex((current) => {
      if (current + 1 < candidates.length) {
        setImageState("loading");
        return current + 1;
      }
      if (candidates.length > 0 && recoveryPass === 0) {
        // A provider can finish warming its screenshot just after the first
        // request fails. One cache-busted recovery pass avoids surfacing a
        // transient terminal state without creating an unbounded retry loop.
        setRecoveryPass(1);
        setRetryRevision((revision) => revision + 1);
        setImageState("loading");
        return 0;
      }
      setImageState("error");
      return current;
    });
  }, [candidates.length, recoveryPass]);

  useEffect(() => {
    if (!screenshot || imageState !== "loading") return undefined;
    const timeout = window.setTimeout(tryNextCandidate, WEB_PREVIEW_TIMEOUT_MS);
    return () => window.clearTimeout(timeout);
  }, [imageState, retryRevision, screenshot, tryNextCandidate]);

  const retry = useCallback(() => {
    setCandidateIndex(0);
    setRecoveryPass(0);
    setRetryRevision((current) => current + 1);
    setLoadedScreenshot("");
    setImageState(candidates.length ? "loading" : "error");
  }, [candidates.length]);

  const renderedScreenshot = retryRevision && screenshot.startsWith("https:")
    ? `${screenshot}${screenshot.includes("?") ? "&" : "?"}_spatialRetry=${retryRevision}`
    : screenshot;
  const domain = webClipDisplayUrl(item);

  return (
    <div className={`web-preview is-${imageState}`}>
      <div className="web-preview-shot">
        {renderedScreenshot && (
          <img
            key={renderedScreenshot}
            src={renderedScreenshot}
            alt={`Screenshot of ${item.title || domain}`}
            draggable="false"
            loading={interactive ? "eager" : "lazy"}
            decoding="async"
            referrerPolicy="no-referrer"
            onLoad={(event) => {
              onToneChange?.(sampleImageBottomTone(event.currentTarget, {
                fallback: item.artifactTone === "dark" ? "dark" : "light",
              }));
              if (screenshot.startsWith("https:") && item.url) {
                workingScreenshotByPage.set(item.url, screenshot);
                if (item.id && !item.screenshotAssetId) onScreenshotResolved?.(item.id, screenshot);
              }
              setLoadedScreenshot(screenshot);
              setImageState("ready");
            }}
            onError={tryNextCandidate}
          />
        )}
        {imageState === "loading" && (
          <div className="web-shot-status is-loading" role="status" aria-label="Capturing page preview">
            <span />
          </div>
        )}
        {imageState === "error" && (
          <div className="web-shot-status is-error">
            <GlobeSimple size={24} weight="thin" />
            <span>Preview unavailable</span>
            {interactive && candidates.length > 0 && (
              <button type="button" onClick={retry}>Retry</button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function StackPreview({ item }) {
  return (
    <div className="stack-preview">
      <div className="stack-open-pill" aria-hidden="true">
        <ArrowUp size={10} weight="bold" /> Open
      </div>
      <div className="stack-front">
        <span>{item.memberIds?.length || item.count || 0} Items</span>
        <h3>{item.title || "Untitled"}</h3>
        {item.subtitle && <p>{item.subtitle}</p>}
      </div>
    </div>
  );
}

export function ItemCard({
  item,
  children,
  selected = false,
  dimmed = false,
  dragging = false,
  resizing = false,
  snapTarget = false,
  onPointerDown,
  onDoubleClick,
  onOpenStack,
  transitionClone = false,
  interactive = true,
}) {
  const kind = item.kind || item.type;
  const inert = transitionClone || dimmed || !interactive;
  const style = {
    width: item.width,
    height: item.height,
    zIndex: item.z ?? 1,
    "--item-color": item.color || "#fcfcfc",
    "--item-glow": item.glow || item.color || "transparent",
  };

  return (
    <motion.article
      data-item-id={item.id}
      data-kind={kind}
      className={`spatial-item item-${kind} ${selected ? "is-selected" : ""} ${snapTarget ? "is-snap-target" : ""} ${dimmed ? "is-dimmed" : ""} ${dragging ? "is-dragging" : ""} ${resizing ? "is-resizing" : ""} ${transitionClone ? "is-transition-clone" : ""}`}
      style={style}
      onPointerDown={inert ? undefined : onPointerDown}
      onDoubleClick={inert ? undefined : onDoubleClick}
      onKeyDown={inert ? undefined : (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        event.stopPropagation();
        if (kind === "stack" || kind === "folder") onOpenStack?.(item.id);
        else onDoubleClick?.(event);
      }}
      role={inert ? undefined : "button"}
      tabIndex={inert ? undefined : 0}
      aria-hidden={inert || undefined}
      aria-label={inert ? undefined : (item.title || `${kind} item`)}
    >
      {children ?? (
        <>
          {kind === "image" && <ImagePreview item={item} />}
          {kind === "note" && <NotePreview item={item} />}
          {kind === "document" && <DocumentPreview item={item} />}
          {kind === "web" && <WebPreview item={item} />}
          {(kind === "stack" || kind === "folder") && <StackPreview item={item} />}
        </>
      )}
    </motion.article>
  );
}
