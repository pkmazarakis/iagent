import { useEffect, useId, useRef, useState } from "react";
import {
  Activity,
  AudioLines,
  CalendarDays,
  Check,
  ChevronDown,
  Cloud,
  Command,
  ListTodo,
  NotebookText,
  Pause,
  PanelsTopLeft,
  Play,
  SquareTerminal,
} from "lucide-react";

const ASSET = "/assets";

const media = {
  icon: `${ASSET}/brand/iagent-app-icon.jpg`,
  stageLight: `${ASSET}/generated/device-stage-silver-light-v1.jpg`,
  macFrame: `${ASSET}/generated/mac-studio-display-frame-v2.png`,
  phoneFrame: `${ASSET}/generated/iphone-titanium-frame-v2.png`,
  desktop: {
    calendarRecordable: `${ASSET}/desktop/calendar-recordable-meeting.png`,
    calendarToday: `${ASSET}/desktop/calendar-today.png`,
    meetingListening: `${ASSET}/desktop/meeting-listening.png`,
    noteMarkdown: `${ASSET}/desktop/note-markdown.png`,
    todoList: `${ASSET}/desktop/todo-list.png`,
  },
  mobile: {
    welcome: `${ASSET}/mobile/native-v1/welcome.png`,
    today: `${ASSET}/mobile/native-v1/today.png`,
    codex: `${ASSET}/mobile/native-v1/codex.png`,
    notes: `${ASSET}/mobile/native-v1/notes.png`,
    todos: `${ASSET}/mobile/native-v1/todos.png`,
    createMenu: `${ASSET}/mobile/native-v1/create-menu.png`,
    meetingLive: `${ASSET}/mobile/native-v1/meeting-live.png`,
    meetingSummary: `${ASSET}/mobile/native-v1/meeting-summary.png`,
    todoCompose: `${ASSET}/mobile/native-v1/todo-compose.png`,
    askSources: `${ASSET}/mobile/native-v1/ask-sources.png`,
    askReview: `${ASSET}/mobile/native-v1/ask-review.png`,
    askCreated: `${ASSET}/mobile/native-v1/ask-created.png`,
    todayStart: `${ASSET}/mobile/native-v1/today-start.jpg`,
    codexStart: `${ASSET}/mobile/native-v1/codex-start.jpg`,
    notesStart: `${ASSET}/mobile/native-v1/notes-start.jpg`,
    todosStart: `${ASSET}/mobile/native-v1/todos-start.jpg`,
    askStart: `${ASSET}/mobile/native-v1/ask-start.jpg`,
    meetingStart: `${ASSET}/mobile/native-v1/meeting-start.jpg`,
  },
  video: {
    meetingGoldenFlow: `${ASSET}/video/macos-meeting-golden-flow.mp4`,
    meetingGoldenPoster: `${ASSET}/video/macos-meeting-golden-flow-poster.jpg`,
    meetingGoldenStart: `${ASSET}/video/macos-meeting-golden-flow-start.jpg`,
    iphoneToday: `${ASSET}/video/iphone-native-v1-today.mp4`,
    iphoneCodex: `${ASSET}/video/iphone-native-v1-codex.mp4`,
    iphoneNotes: `${ASSET}/video/iphone-native-v1-notes.mp4`,
    iphoneTodos: `${ASSET}/video/iphone-native-v1-todos.mp4`,
    iphoneAsk: `${ASSET}/video/iphone-native-v1-ask.mp4`,
    iphoneMeeting: `${ASSET}/video/iphone-native-v1-meeting.mp4`,
  },
};

const askTabs = [
  {
    label: "Speak naturally",
    caption: "A spoken request moves through live transcription into Ask iAgent.",
    frames: [media.mobile.askCreated],
    poster: media.mobile.askStart,
    reducedPoster: media.mobile.askCreated,
    video: media.video.iphoneAsk,
    alt: "A spoken request becomes a grounded Ask iAgent response and proposed todo on iPhone",
    kind: "phone",
  },
  {
    label: "Review context",
    caption: "The work trace shows the local meeting records selected for the answer.",
    frames: [media.mobile.askSources],
    alt: "Ask iAgent reviewing selected local meeting records on iPhone",
    kind: "phone",
  },
  {
    label: "Approve the action",
    caption: "Nothing changes until you confirm; the approved todo is then saved locally.",
    frames: [media.mobile.askReview, media.mobile.askCreated],
    poster: media.mobile.askCreated,
    alt: "Ask iAgent moving from an explicit todo review to a locally created todo",
    kind: "phone",
  },
];

const knowledgeTabs = [
  {
    label: "Plain Markdown",
    caption: "Readable files remain the canonical library on your Mac.",
    frames: [media.desktop.noteMarkdown],
    alt: "A plain Markdown note open in the iAgent Mac panel",
    kind: "desktop",
    panelVariant: "note",
  },
  {
    label: "Local notes",
    caption: "Create a note on iPhone and return to the local library in one flow.",
    frames: [media.mobile.notes],
    poster: media.mobile.notesStart,
    reducedPoster: media.mobile.notes,
    video: media.video.iphoneNotes,
    alt: "iAgent creates a note and returns to the local Notes library on iPhone",
    kind: "phone",
  },
  {
    label: "Meeting records",
    caption: "A live transcript settles into a finished summary in the same library.",
    frames: [media.mobile.meetingLive, media.mobile.meetingSummary],
    poster: media.mobile.meetingSummary,
    alt: "An iPhone meeting transcript becoming a finished iAgent summary",
    kind: "phone",
  },
];

const meetingMobileTabs = [
  {
    label: "Golden flow",
    caption: "Start, record, stop, transcribe, and review the finished summary on iPhone.",
    frames: [media.mobile.meetingSummary],
    poster: media.mobile.meetingStart,
    reducedPoster: media.mobile.meetingSummary,
    video: media.video.iphoneMeeting,
    alt: "iAgent records a meeting on iPhone, shows the live transcript, then generates the finished summary",
    kind: "phone",
  },
  {
    label: "Live transcript",
    caption: "The timer, live words, waveform, and stop control remain visible while recording.",
    frames: [media.mobile.meetingLive],
    alt: "A live iAgent meeting transcript and waveform on iPhone",
    kind: "phone",
  },
  {
    label: "Finished summary",
    caption: "The transcript becomes a local meeting record with a readable summary.",
    frames: [media.mobile.meetingSummary],
    alt: "A finished iAgent meeting summary on iPhone",
    kind: "phone",
  },
];

const todayMobileTabs = [
  {
    label: "See the day",
    caption: "Move from the daily briefing into the exact event, task, or next action.",
    frames: [media.mobile.today],
    poster: media.mobile.todayStart,
    reducedPoster: media.mobile.today,
    video: media.video.iphoneToday,
    alt: "iAgent Today moving between the schedule, a live Codex task, and open todos on iPhone",
    kind: "phone",
  },
  {
    label: "Follow Codex",
    caption: "Open a live task and inspect its recent agent activity without returning to the Mac.",
    frames: [media.mobile.codex],
    poster: media.mobile.codexStart,
    reducedPoster: media.mobile.codex,
    video: media.video.iphoneCodex,
    alt: "iAgent opens a live Codex task and its recent agent activity on iPhone",
    kind: "phone",
  },
  {
    label: "Capture a todo",
    caption: "Dictate a task, review the text, and save it into the local todo list.",
    frames: [media.mobile.todos],
    poster: media.mobile.todosStart,
    reducedPoster: media.mobile.todos,
    video: media.video.iphoneTodos,
    alt: "iAgent dictates a task and saves it locally on iPhone",
    kind: "phone",
  },
];

const outcomes = [
  {
    milestone: "Today",
    title: "See the whole day",
    items: [
      "Calendar, live Codex work, and todos in one briefing",
      "Start a note or meeting capture in one gesture",
      "Carry the same day onto iPhone",
    ],
  },
  {
    milestone: "Day 3",
    title: "Capture without friction",
    items: [
      "Meetings become structured notes",
      "Voice becomes a note, todo, or agent prompt",
      "Priority work stays visible at the edge of your screen",
    ],
  },
  {
    milestone: "Day 7",
    title: "Work from context",
    items: [
      "Ask across Calendar, Codex, todos, notes, and transcripts",
      "Keep edits synced privately between devices",
      "Spend less time reopening and reconciling apps",
    ],
  },
];

const directory = [
  [CalendarDays, "Calendar", "Events and meeting links"],
  [SquareTerminal, "Codex", "Live root-task status"],
  [NotebookText, "Notes", "Local Markdown library"],
  [ListTodo, "Todos", "Lists, due dates, history"],
  [AudioLines, "Meetings", "Transcript and summary"],
  [Cloud, "CloudKit", "Private cross-device sync"],
  [PanelsTopLeft, "Widgets", "Glanceable priorities"],
  [Activity, "Live Activities", "Approval attention"],
  [Command, "Shortcuts", "Option-Space, Option-N, Option-V"],
];

const faqs = [
  [
    "What runs locally?",
    "The Mac panel, local Markdown/JSON library, meeting transcript workflow, and desktop source indexes live on your devices.",
  ],
  [
    "What syncs through iCloud?",
    "When enabled, encrypted CloudKit records carry notes, todos, transcripts, Calendar metadata, and Codex activity into your private database. Raw meeting audio is never stored or synced.",
  ],
  [
    "Does a meeting bot join my calls?",
    "No. iAgent captures microphone and system audio directly on the Mac after you start a recording.",
  ],
  [
    "Can I use iAgent offline?",
    "Yes. Both apps keep local state and queue changes until connectivity returns.",
  ],
  [
    "Can Ask iAgent make changes for me?",
    "It can prepare grounded actions and proposals. Anything sensitive or consequential still follows explicit review and authorization.",
  ],
  [
    "Where are my notes stored?",
    "Plain Markdown under your iAgent Library on Mac, plus the iPhone's offline local store and optional private CloudKit records.",
  ],
  [
    "Which devices are supported?",
    "The current experience is built for macOS and iPhone.",
  ],
];

function usePrefersReducedMotion() {
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, []);

  return reduced;
}

function SequenceImage({
  frames,
  poster,
  alt,
  className = "",
  interval = 2300,
  eager = false,
  preloadFrames = true,
}) {
  const reduceMotion = usePrefersReducedMotion();
  const frameKey = frames.join("|");
  const posterIndex = poster ? Math.max(0, frames.indexOf(poster)) : 0;
  const [index, setIndex] = useState(posterIndex);
  const [isInViewport, setIsInViewport] = useState(eager);
  const [userPaused, setUserPaused] = useState(false);
  const containerRef = useRef(null);

  useEffect(() => {
    if (!containerRef.current || !("IntersectionObserver" in window)) return undefined;
    const observer = new IntersectionObserver(
      ([entry]) => setIsInViewport(entry.isIntersecting),
      { rootMargin: "120px" },
    );
    observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    setIndex(reduceMotion ? posterIndex : 0);
    if (reduceMotion || !preloadFrames || !isInViewport || userPaused || frames.length < 2) return undefined;
    const timer = window.setInterval(() => {
      setIndex((current) => (current + 1) % frames.length);
    }, interval);
    return () => window.clearInterval(timer);
  }, [frameKey, frames.length, interval, isInViewport, posterIndex, preloadFrames, reduceMotion, userPaused]);

  useEffect(() => {
    if (!preloadFrames || !isInViewport || userPaused || frames.length < 2) return undefined;
    const nextFrame = new Image();
    nextFrame.src = frames[(index + 1) % frames.length];
    return () => {
      nextFrame.src = "";
    };
  }, [frames, index, isInViewport, preloadFrames, userPaused]);

  return (
    <div ref={containerRef} className={`sequence-image ${className}`.trim()}>
      <img
        key={frames[index]}
        src={frames[index]}
        alt={alt}
        loading={eager ? "eager" : "lazy"}
        fetchPriority={eager ? "high" : "auto"}
      />
      {!reduceMotion && preloadFrames && frames.length > 1 ? (
        <button
          className="sequence-playback"
          type="button"
          aria-label={userPaused ? "Play image demo" : "Pause image demo"}
          onClick={() => setUserPaused((current) => !current)}
        >
          {userPaused ? <Play aria-hidden="true" size={12} fill="currentColor" /> : <Pause aria-hidden="true" size={12} fill="currentColor" />}
        </button>
      ) : null}
    </div>
  );
}

function NativeVideo({ src, poster, reducedPoster = poster, alt, className = "" }) {
  const reduceMotion = usePrefersReducedMotion();
  const containerRef = useRef(null);
  const videoRef = useRef(null);
  const playbackToken = useRef(Symbol(src));
  const [isInViewport, setIsInViewport] = useState(false);
  const [userPaused, setUserPaused] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);

  useEffect(() => {
    if (!containerRef.current || !("IntersectionObserver" in window)) {
      setIsInViewport(true);
      return undefined;
    }
    const observer = new IntersectionObserver(
      ([entry]) => setIsInViewport(entry.isIntersecting),
      { rootMargin: "0px", threshold: 0.3 },
    );
    observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || reduceMotion || !isInViewport) {
      setIsPlaying(false);
      return undefined;
    }

    const handlePlaybackClaim = (event) => {
      if (event.detail === playbackToken.current) return;
      video.pause();
      setIsPlaying(false);
    };

    window.addEventListener("iagent:demo-play", handlePlaybackClaim);
    if (userPaused) {
      video.pause();
      setIsPlaying(false);
    } else {
      window.dispatchEvent(new CustomEvent("iagent:demo-play", { detail: playbackToken.current }));
      video.play().then(() => setIsPlaying(true)).catch(() => setIsPlaying(false));
    }

    return () => {
      window.removeEventListener("iagent:demo-play", handlePlaybackClaim);
    };
  }, [isInViewport, reduceMotion, src, userPaused]);

  const togglePlayback = () => {
    const video = videoRef.current;
    if (!video || reduceMotion) return;
    if (video.paused) {
      setUserPaused(false);
      window.dispatchEvent(new CustomEvent("iagent:demo-play", { detail: playbackToken.current }));
      video.play().then(() => setIsPlaying(true)).catch(() => setIsPlaying(false));
    } else {
      video.pause();
      setUserPaused(true);
      setIsPlaying(false);
    }
  };

  if (reduceMotion || !isInViewport) {
    return (
      <div ref={containerRef} className={`sequence-image ${className}`.trim()}>
        <img src={reduceMotion ? reducedPoster : poster} alt={alt} loading="lazy" />
      </div>
    );
  }

  return (
    <div ref={containerRef} className={`sequence-image native-video ${className}`.trim()}>
      <video
        ref={videoRef}
        src={src}
        poster={poster}
        aria-label={alt}
        muted
        loop
        playsInline
        preload="metadata"
      />
      <button
        className="sequence-playback"
        type="button"
        aria-label={isPlaying ? "Pause iPhone demo" : "Play iPhone demo"}
        onClick={togglePlayback}
      >
        {isPlaying ? <Pause aria-hidden="true" size={12} fill="currentColor" /> : <Play aria-hidden="true" size={12} fill="currentColor" />}
      </button>
    </div>
  );
}

function DeviceStage({ children, className = "" }) {
  return (
    <div
      className={`device-stage ${className}`.trim()}
      style={{ backgroundImage: `url(${media.stageLight})` }}
    >
      {children}
    </div>
  );
}

function MacDevice({ children, className = "" }) {
  return (
    <figure className={`mac-device ${className}`.trim()}>
      <div className="mac-device-screen">{children}</div>
      <img className="mac-device-frame" src={media.macFrame} alt="" aria-hidden="true" />
    </figure>
  );
}

function IPhoneDevice({ children, className = "" }) {
  return (
    <figure className={`iphone-device ${className}`.trim()}>
      <div className="iphone-device-screen">{children}</div>
      <img className="iphone-device-frame" src={media.phoneFrame} alt="" aria-hidden="true" />
    </figure>
  );
}

function MacDesktopState({ frames, poster, alt, interval = 2500, variant = "panel" }) {
  return (
    <div className={`mac-desktop-state mac-state-${variant}`}>
      <img className="mac-desktop-wallpaper" src={media.video.meetingGoldenStart} alt="" aria-hidden="true" />
      <SequenceImage
        frames={frames}
        poster={poster}
        alt={alt}
        interval={interval}
        className="mac-panel-sequence"
      />
    </div>
  );
}

function MeetingGoldenFlow({ className = "", compact = false, eager = false }) {
  const reduceMotion = usePrefersReducedMotion();
  const containerRef = useRef(null);
  const videoRef = useRef(null);
  const playbackToken = useRef(Symbol("mac-demo"));
  const [isInViewport, setIsInViewport] = useState(eager);
  const [userPaused, setUserPaused] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);

  useEffect(() => {
    if (!containerRef.current || !("IntersectionObserver" in window)) {
      setIsInViewport(true);
      return undefined;
    }
    const observer = new IntersectionObserver(
      ([entry]) => setIsInViewport(entry.isIntersecting),
      { rootMargin: "0px", threshold: 0.45 },
    );
    observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || reduceMotion || !isInViewport) {
      setIsPlaying(false);
      return undefined;
    }

    const handlePlaybackClaim = (event) => {
      if (event.detail === playbackToken.current) return;
      video.pause();
      setIsPlaying(false);
    };

    window.addEventListener("iagent:demo-play", handlePlaybackClaim);
    if (userPaused) {
      video.pause();
      setIsPlaying(false);
    } else {
      window.dispatchEvent(new CustomEvent("iagent:demo-play", { detail: playbackToken.current }));
      video.play().then(() => setIsPlaying(true)).catch(() => setIsPlaying(false));
    }

    return () => {
      window.removeEventListener("iagent:demo-play", handlePlaybackClaim);
    };
  }, [isInViewport, reduceMotion, userPaused]);

  const togglePlayback = () => {
    const video = videoRef.current;
    if (!video || reduceMotion) return;
    if (video.paused) {
      setUserPaused(false);
      window.dispatchEvent(new CustomEvent("iagent:demo-play", { detail: playbackToken.current }));
      video.play().then(() => setIsPlaying(true)).catch(() => setIsPlaying(false));
    } else {
      video.pause();
      setUserPaused(true);
      setIsPlaying(false);
    }
  };

  return (
    <div ref={containerRef} className={`golden-flow ${compact ? "golden-flow-compact" : ""} ${className}`.trim()}>
      <MacDevice label="A complete iAgent meeting flow running inside a Mac desktop display">
        {reduceMotion || !isInViewport ? (
          <img
            className="device-screen-fill"
            src={media.video.meetingGoldenPoster}
            alt="The closed iAgent panel on a clean Mac desktop"
            loading={eager ? "eager" : "lazy"}
            fetchPriority={eager ? "high" : "auto"}
          />
        ) : (
          <video
            ref={videoRef}
            className="device-screen-fill"
            src={media.video.meetingGoldenFlow}
            poster={media.video.meetingGoldenStart}
            aria-label="Closed iAgent panel opens, records a meeting, creates a transcript and summary, then closes"
            muted
            loop
            playsInline
            preload={eager ? "auto" : "metadata"}
          />
        )}
      </MacDevice>
      {!reduceMotion && isInViewport ? (
        <button
          className="demo-playback"
          type="button"
          aria-label={isPlaying ? "Pause Mac demo" : "Play Mac demo"}
          onClick={togglePlayback}
        >
          {isPlaying ? <Pause aria-hidden="true" size={14} fill="currentColor" /> : <Play aria-hidden="true" size={14} fill="currentColor" />}
          <span>{isPlaying ? "Pause demo" : "Play demo"}</span>
        </button>
      ) : null}
    </div>
  );
}

function DeviceMedia({ item }) {
  if (item.kind === "phone") {
    return (
      <IPhoneDevice className="showcase-phone-device" label={item.alt}>
        {item.video ? (
          <NativeVideo
            src={item.video}
            poster={item.poster}
            reducedPoster={item.reducedPoster}
            alt={item.alt}
            className="device-screen-media"
          />
        ) : (
          <SequenceImage
            frames={item.frames}
            poster={item.poster}
            alt={item.alt}
            interval={item.interval ?? 2500}
            className="device-screen-media"
          />
        )}
      </IPhoneDevice>
    );
  }

  return (
    <MacDevice className="showcase-mac-device" label={item.alt}>
      <MacDesktopState
        frames={item.frames}
        poster={item.poster}
        alt={item.alt}
        variant={item.panelVariant}
      />
    </MacDevice>
  );
}

function CTA({ children, href = "#download", variant = "primary", className = "" }) {
  return (
    <a className={`cta cta-${variant} ${className}`.trim()} href={href}>
      {children}
    </a>
  );
}

function CheckList({ items }) {
  return (
    <ul className="check-list">
      {items.map((item) => (
        <li key={item}>
          <Check aria-hidden="true" size={16} strokeWidth={2.4} />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

function SiteNav() {
  const [open, setOpen] = useState(false);
  const navRef = useRef(null);
  const menuButtonRef = useRef(null);

  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key === "Escape" && open) {
        setOpen(false);
        window.requestAnimationFrame(() => menuButtonRef.current?.focus());
      }
    };
    const onPointerDown = (event) => {
      if (navRef.current && !navRef.current.contains(event.target)) setOpen(false);
    };
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown);
    };
  }, [open]);

  return (
    <header className="site-nav-shell" ref={navRef}>
      <nav className="site-nav" aria-label="Primary navigation">
        <div className="nav-start">
          <a className="brand" href="#top" aria-label="iAgent home" onClick={() => setOpen(false)}>
            <img src={media.icon} alt="" width="34" height="34" />
            <span>iAgent</span>
          </a>
          <div className="features-menu-wrap nav-desktop-link">
            <button
              ref={menuButtonRef}
              className="nav-button"
              type="button"
              aria-expanded={open}
              onClick={() => setOpen((current) => !current)}
            >
              Features
              <ChevronDown className={`nav-chevron ${open ? "is-open" : ""}`} aria-hidden="true" />
            </button>
            {open ? (
              <div className="features-menu" id="features-menu">
                <a href="#meetings" onClick={() => setOpen(false)}>
                  <span>Meeting intelligence</span>
                  <small>Transcript to private note</small>
                </a>
                <a href="#ask" onClick={() => setOpen(false)}>
                  <span>Ask iAgent</span>
                  <small>Grounded answers with sources</small>
                </a>
                <a href="#system" onClick={() => setOpen(false)}>
                  <span>One private system</span>
                  <small>Calendar, Codex, notes, and todos</small>
                </a>
                <a href="#knowledge" onClick={() => setOpen(false)}>
                  <span>Local-first knowledge</span>
                  <small>Markdown and private CloudKit</small>
                </a>
                <a href="#today" onClick={() => setOpen(false)}>
                  <span>Today</span>
                  <small>Your next useful step</small>
                </a>
              </div>
            ) : null}
          </div>
          <a className="nav-text-link" href="#privacy">
            Privacy
          </a>
        </div>
        <div className="nav-links">
          <a className="nav-text-link nav-desktop-link" href="#faq-title">
            Support
          </a>
          <CTA className="nav-cta">Get iAgent</CTA>
        </div>
      </nav>
    </header>
  );
}

function SectionHeader({ eyebrow, title, color = "blue", children, id }) {
  return (
    <header className="section-header">
      <p className={`eyebrow eyebrow-${color}`}>{eyebrow}</p>
      <h2 id={id}>{title}</h2>
      {children}
    </header>
  );
}

function ProofCard({ title, children, tone = "green" }) {
  return (
    <article className={`proof-card proof-${tone}`}>
      <span className="proof-dot" aria-hidden="true" />
      <h3>{title}</h3>
      <p>{children}</p>
    </article>
  );
}

function Marquee({ label, items, subtle = false }) {
  return (
    <div className={`marquee ${subtle ? "marquee-subtle" : ""}`} aria-label={label}>
      <div className="marquee-track">
        {[0, 1].map((copy) => (
          <div className="marquee-group" key={copy} aria-hidden={copy === 1 ? "true" : undefined}>
            {items.map((item) => (
              <span key={`${copy}-${item}`}>{item}</span>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

function ProductShowcase({ tabs, label, tone = "blue", className = "" }) {
  const [active, setActive] = useState(0);
  const id = useId();
  const panelId = `${id}-panel`;
  const selected = tabs[active];

  const onTabKeyDown = (event, index) => {
    let next = null;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") next = (index + 1) % tabs.length;
    if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = (index - 1 + tabs.length) % tabs.length;
    if (event.key === "Home") next = 0;
    if (event.key === "End") next = tabs.length - 1;
    if (next === null) return;
    event.preventDefault();
    setActive(next);
    event.currentTarget.parentElement?.querySelectorAll('[role="tab"]')[next]?.focus();
  };

  return (
    <div className={`product-showcase showcase-${tone} ${className}`.trim()}>
      <div className="showcase-tabs" role="tablist" aria-label={label}>
        {tabs.map((tab, index) => (
          <button
            type="button"
            role="tab"
            id={`${id}-tab-${index}`}
            aria-controls={panelId}
            aria-selected={active === index}
            tabIndex={active === index ? 0 : -1}
            className={active === index ? "is-active" : ""}
            key={tab.label}
            onClick={() => setActive(index)}
            onKeyDown={(event) => onTabKeyDown(event, index)}
          >
            {tab.label}
          </button>
        ))}
      </div>
      <div
        className={`showcase-panel showcase-panel-${selected.kind}`}
        role="tabpanel"
        id={panelId}
        aria-labelledby={`${id}-tab-${active}`}
      >
        <DeviceMedia item={selected} />
        <p className="showcase-caption">{selected.caption}</p>
      </div>
    </div>
  );
}

function Hero() {
  return (
    <section className="hero section-rail" id="top" aria-labelledby="hero-title">
      <div className="proof-chips" aria-label="Product availability and privacy">
        <span>Built for Mac + iPhone</span>
        <span>Local-first by design</span>
      </div>
      <h1 id="hero-title">
        Run every day with your<br />private AI command hub
      </h1>
      <p className="hero-copy">
        Calendar, Codex, todos, notes, and meeting capture in one calm Mac panel—with the same day
        waiting on iPhone.
      </p>
      <div className="hero-actions">
        <CTA>Get iAgent</CTA>
        <CTA href="#meetings" variant="secondary">
          See it in action
        </CTA>
      </div>
      <a className="changelog" id="hero-changelog" href="#ask">
        <span aria-hidden="true">New</span>
        Ask iAgent searches Calendar, Codex, notes, todos, and meeting transcripts
      </a>
      <DeviceStage className="hero-stage">
        <MeetingGoldenFlow className="hero-mac-flow" eager />
        <IPhoneDevice
          className="hero-phone-device"
          label="The same iAgent day moving through Today, Codex, Notes, and Todos on iPhone"
        >
          <SequenceImage
            frames={[media.mobile.today, media.mobile.codex, media.mobile.notes, media.mobile.todos]}
            poster={media.mobile.today}
            alt="The iAgent mobile app moving through Today, Codex, Notes, and Todos on iPhone"
            interval={3000}
            className="device-screen-media"
            eager
          />
        </IPhoneDevice>
        <p className="hero-demo-note">One private day, moving naturally between your Mac and iPhone.</p>
      </DeviceStage>
    </section>
  );
}

function CapabilityRail() {
  return (
    <section className="capability-section section-rail" aria-labelledby="capability-title">
      <h2 className="sr-only" id="capability-title">
        The native parts of your day in one place
      </h2>
      <p>One quiet surface for</p>
      <Marquee
        label="iAgent capabilities"
        items={["Calendar", "Codex", "Todos", "Notes", "Meetings", "Private CloudKit sync"]}
      />
      <small>Native sources, not another workspace to maintain.</small>
    </section>
  );
}

function ValuePromise() {
  return (
    <section className="value-promise section-rail" id="overview" aria-labelledby="promise-title">
      <h2 id="promise-title">
        <span>Before the day gets loud:</span> See the next meeting. Track live work. Capture a
        thought. Keep moving.
      </h2>
      <CTA href="#meetings">Meet iAgent</CTA>
    </section>
  );
}

function MeetingSection() {
  const captureBenefits = [
    "Pause or stop from the top edge of your screen",
    "See live transcript and waveform without changing apps",
    "Attach the session to the exact Calendar event",
    "Open the finished summary as a local Markdown note",
  ];

  return (
    <section className="feature-section section-rail" id="meetings" aria-labelledby="meetings-title">
      <SectionHeader eyebrow="Meeting Intelligence" title="Remember every meeting, without a bot" color="green" id="meetings-title">
        <p className="replaces"><strong>Replaces:</strong> Loose transcripts, scattered notes, manual follow-up</p>
      </SectionHeader>

      <div className="editorial-block">
        <h3>Why iAgent?</h3>
        <p>
          Most meeting tools stop at a transcript. iAgent keeps the conversation beside the rest of
          your day—your event, private notes, decisions, and next actions.
        </p>
        <p>
          Start from the Mac panel, keep the call free of meeting bots, and finish with a structured
          Markdown note you control.
        </p>
      </div>

      <div className="proof-grid proof-grid-two">
        <ProofCard title="Private by default">Raw audio and screen frames are never saved.</ProofCard>
        <ProofCard title="Built into your day">A meeting becomes a note without opening another workspace.</ProofCard>
      </div>

      <div className="meeting-story-grid">
        <article>
          <h3>The source stays legible</h3>
          <p>
            Microphone and system-audio lines remain separate in the live transcript, while the
            Calendar event keeps the record anchored to the right title and time.
          </p>
          <p>
            That context survives into the finished summary, so a decision is still connected to
            the conversation that produced it.
          </p>
        </article>
        <article>
          <h3>Nothing raw to manage</h3>
          <p>
            iAgent processes capture in short-lived chunks and keeps the transcript—not a folder of
            audio recordings or screen frames.
          </p>
          <p>
            The result is a readable local record that can be edited, searched, and removed like
            any other note in your library.
          </p>
        </article>
      </div>

      <div className="subsection-copy bordered-copy">
        <h3>Transcript, summary, and next steps</h3>
        <p>
          iAgent captures microphone and system audio into one synchronized session, accumulates the
          live transcript, and turns the finished conversation into a clear overview and key points.
        </p>
      </div>

      <DeviceStage className="meeting-golden-stage">
        <MeetingGoldenFlow />
        <ol className="demo-timeline" aria-label="Mac meeting demo sequence">
          <li>Closed panel</li>
          <li>Record</li>
          <li>Transcript</li>
          <li>Summary</li>
          <li>Meeting note</li>
        </ol>
      </DeviceStage>

      <div className="mobile-flow-intro">
        <p className="eyebrow eyebrow-green">The iPhone flow</p>
        <h3>The same meeting record fits in your hand</h3>
        <p>
          Start a recording on iPhone, follow the live transcript, and keep the finished summary
          beside the rest of your private notes.
        </p>
      </div>
      <ProductShowcase
        tabs={meetingMobileTabs}
        label="iPhone meeting capture stages"
        tone="dark"
        className="phone-showcase meeting-mobile-showcase"
      />

      <Marquee
        subtle
        label="Meeting capabilities"
        items={["Calendar context", "System audio", "Microphone", "Markdown", "Private CloudKit", "Searchable history"]}
      />

      <div className="recorder-story">
        <div className="recorder-copy">
          <h3>Your Mac is the recorder</h3>
          <p>
            Capture stays in the panel at the top of your screen, so the call remains free of added
            participants and your controls remain close.
          </p>
          <CheckList items={captureBenefits} />
        </div>
        <DeviceStage className="recorder-visual">
          <MacDevice label="iAgent Calendar and recording states inside a Mac display">
            <MacDesktopState
              frames={[media.desktop.calendarRecordable, media.desktop.meetingListening]}
              poster={media.desktop.calendarRecordable}
              alt="iAgent moving from a Calendar event into a compact live recording transcript"
              interval={2700}
              variant="recorder"
            />
          </MacDevice>
        </DeviceStage>
      </div>

      <blockquote className="quote-rail quote-green">
        The recorder stays at the edge of the screen. The finished record stays in your own library.
      </blockquote>

      <div className="native-stack" aria-label="Native technologies and destinations">
        {["Apple Calendar", "ScreenCaptureKit", "Microphone", "Markdown", "CloudKit", "iPhone"].map((item) => (
          <span key={item}>{item}</span>
        ))}
      </div>

      <div className="meeting-story-grid meeting-story-grid-final">
        <article>
          <h3>Works with the calls you already join</h3>
          <p>
            If a conversation reaches your Mac as system audio, iAgent can capture it. There is no
            provider-specific bot to invite and no guest waiting in the lobby.
          </p>
          <p>
            Start from the Calendar event or the panel, then pause, resume, or stop without
            covering the call itself.
          </p>
        </article>
        <article>
          <h3>The finished record stays yours</h3>
          <p>
            The summary opens as Markdown in the iAgent Library, beside your private notes and the
            event metadata that made the session useful.
          </p>
          <p>
            Optional CloudKit sync carries the structured record to iPhone. Raw meeting audio is
            never added to that sync path.
          </p>
        </article>
      </div>

      <div className="private-notes-grid">
        <div>
          <h3>Shape the summary with your own notes</h3>
          <p>
            Write privately before or during a meeting. iAgent keeps your words in the finished note
            and uses the meeting context to organize what matters.
          </p>
        </div>
        <DeviceStage className="inline-mac-stage">
          <MacDevice label="Private Markdown notes in iAgent on Mac">
            <MacDesktopState
              frames={[media.desktop.noteMarkdown]}
              alt="Private Markdown notes in iAgent"
              variant="note"
            />
          </MacDevice>
        </DeviceStage>
      </div>
    </section>
  );
}

function OutcomePlan() {
  const [active, setActive] = useState(0);

  return (
    <section className="outcome-section section-rail" aria-labelledby="outcome-title">
      <h2 id="outcome-title">
        What changes after <span>one calm week</span> with iAgent
      </h2>
      <div className="milestones" aria-label="One week outcomes">
        {outcomes.map((outcome, index) => (
          <button
            type="button"
            key={outcome.milestone}
            className={active === index ? "is-active" : ""}
            aria-pressed={active === index}
            onClick={() => setActive(index)}
          >
            {outcome.milestone}
          </button>
        ))}
      </div>
      <div className="outcome-cards">
        {outcomes.map((outcome, index) => (
          <article className={`outcome-card ${active === index ? "is-active" : ""}`} key={outcome.milestone}>
            <p>{outcome.milestone}</p>
            <h3>{outcome.title}</h3>
            <CheckList items={outcome.items} />
          </article>
        ))}
      </div>
      <CTA>Start with iAgent</CTA>
    </section>
  );
}

function AskSection() {
  return (
    <section className="feature-section section-rail" id="ask" aria-labelledby="ask-title">
      <SectionHeader eyebrow="Ask iAgent" title="Ask your day, not another empty chatbot" id="ask-title" />
      <blockquote className="speech-card">
        Speak a real request. iAgent transcribes it, checks the local context that matters, and
        pauses for review before it changes anything.
      </blockquote>
      <div className="ask-artifact">
        <DeviceStage className="ask-device-stage">
          <IPhoneDevice label="A spoken Ask iAgent request becoming a reviewed local action on iPhone">
            <NativeVideo
              src={media.video.iphoneAsk}
              poster={media.mobile.askStart}
              reducedPoster={media.mobile.askCreated}
              alt="A spoken request becomes a grounded Ask iAgent response and reviewed local todo"
              className="device-screen-media"
            />
          </IPhoneDevice>
        </DeviceStage>
        <div>
          <p className="artifact-kicker">Voice → context → review</p>
          <h3>Ask can stop before it acts</h3>
          <p>
            The work trace stays visible while iAgent checks local records. A proposed todo remains
            a proposal until you approve it, then saves locally.
          </p>
        </div>
      </div>
      <div className="subsection-copy bordered-copy">
        <h3>Grounded work you can inspect</h3>
        <p>
          iAgent shows the local records it checks, keeps the response in the same thread, and
          separates read-only research from an action that needs your confirmation.
        </p>
        <p className="highlight-line"><span>One useful request:</span> “Turn these meeting decisions into the todos I need.”</p>
      </div>
      <div className="proof-grid proof-grid-two ask-proof-grid">
        <ProofCard title="Read-only retrieval">Questions begin by finding context, not changing it.</ProofCard>
        <ProofCard title="Explicit approval">A proposed action waits for your confirmation before it is saved.</ProofCard>
      </div>
      <ProductShowcase tabs={askTabs} label="Ask iAgent stages" tone="dark" className="phone-showcase" />
    </section>
  );
}

function SystemDiagram() {
  const sources = ["Apple Calendar", "Codex", "Markdown notes", "Meeting capture"];
  const destinations = ["Today", "Ask iAgent", "Todos", "iPhone"];
  return (
    <div className="system-diagram" role="img" aria-label="Calendar, Codex, Markdown notes, and meeting capture flow through iAgent to Today, Ask iAgent, Todos, and iPhone">
      <div className="diagram-column diagram-sources">
        <p>Sources</p>
        {sources.map((item) => <span key={item}>{item}</span>)}
      </div>
      <div className="diagram-center">
        <img src={media.icon} alt="" />
        <strong>iAgent</strong>
        <small>local context</small>
      </div>
      <div className="diagram-column diagram-destinations">
        <p>Views</p>
        {destinations.map((item) => <span key={item}>{item}</span>)}
      </div>
    </div>
  );
}

function ConnectedSystem() {
  return (
    <section className="feature-section section-rail" id="system" aria-labelledby="system-title">
      <SectionHeader eyebrow="One private system" title="Keep every part of your day in context" id="system-title" />
      <div className="editorial-block system-copy">
        <p>
          iAgent does not need a new cloud workspace to understand your day. It reads the native
          sources already on your devices.
        </p>
        <p>
          Calendar events, Codex activity, local Markdown notes, todos, and meeting transcripts meet
          in one quiet interface.
        </p>
        <p>
          When private sync is enabled, encrypted CloudKit records reconcile the Mac and iPhone—even
          after working offline.
        </p>
      </div>
      <SystemDiagram />
      <p className="diagram-caption">Your sources stay recognizable. iAgent adds the context between them.</p>
      <div className="directory-grid">
        {directory.map(([Icon, title, description]) => (
          <article key={title}>
            <span className="directory-mark" aria-hidden="true">
              <Icon size={19} strokeWidth={1.8} />
            </span>
            <div>
              <h3>{title}</h3>
              <p>{description}</p>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function KnowledgeSection() {
  return (
    <section className="feature-section section-rail" id="knowledge" aria-labelledby="knowledge-title">
      <SectionHeader eyebrow="Local-first knowledge" title="Your notes stay yours—and stay with you" color="purple" id="knowledge-title" />
      <div className="editorial-block">
        <p>
          Notes, meeting transcripts, and todos remain plain files in your iAgent Library on Mac.
          There is no proprietary document format standing between you and your work.
        </p>
        <p>
          On iPhone, a new note, live meeting transcript, and finished summary remain part of the
          same readable local library. Private CloudKit sync can reconcile changes when a connection returns.
        </p>
      </div>
      <blockquote className="quote-rail quote-purple">
        Readable files on disk. Private records in iCloud. Useful context everywhere you ask.
      </blockquote>
      <ProductShowcase tabs={knowledgeTabs} label="Local-first knowledge views" tone="gray" />
      <div className="knowledge-grid">
        <article>
          <span>01</span>
          <h3>By meeting</h3>
          <p>Keep every conversation beside its event.</p>
        </article>
        <article>
          <span>02</span>
          <h3>By project</h3>
          <p>Find notes and active work together.</p>
        </article>
        <article>
          <span>03</span>
          <h3>By question</h3>
          <p>Pull the exact source into Ask iAgent.</p>
        </article>
      </div>
    </section>
  );
}

function TodaySection() {
  return (
    <section className="feature-section section-rail" id="today" aria-labelledby="today-title">
      <SectionHeader eyebrow="Today" title="Organize the day without organizing another app" color="orange" id="today-title">
        <p className="replaces"><strong>Replaces:</strong> App hopping, stale task lists, missed context</p>
      </SectionHeader>
      <p className="section-intro">
        iAgent combines the next Calendar event, active Codex tasks, and every open todo into one
        briefing. As the day changes, the panel keeps the most relevant next step within reach.
      </p>
      <ProductShowcase
        tabs={todayMobileTabs}
        label="The iAgent mobile companion"
        tone="warm"
        className="phone-showcase today-mobile-showcase"
      />
      <div className="mini-features">
        <article>
          <h3>One daily briefing</h3>
          <p>See meetings, agent activity, todos, and priorities without assembling a dashboard.</p>
          <div className="mini-media desktop-mini-media">
            <MacDevice label="Today's Calendar events inside iAgent on Mac">
              <MacDesktopState
                frames={[media.desktop.calendarToday]}
                alt="Today's Calendar events in iAgent"
                variant="calendar"
              />
            </MacDevice>
          </div>
        </article>
        <article>
          <h3>Capture from anywhere</h3>
          <p>
            Use Mac shortcuts or the iPhone plus menu for a voice chat, note, todo, agent task, or
            meeting recording.
          </p>
          <div className="mini-media phone-mini-media">
            <IPhoneDevice label="The iAgent Create menu and todo composer on iPhone">
              <SequenceImage
                frames={[media.mobile.createMenu, media.mobile.todoCompose]}
                poster={media.mobile.createMenu}
                alt="The iAgent Create menu opening a full todo composer on iPhone"
                className="device-screen-media"
                interval={3000}
              />
            </IPhoneDevice>
          </div>
        </article>
      </div>
      <div className="proof-grid proof-grid-three">
        <ProofCard title="Local-first" tone="orange">Your Mac files remain canonical.</ProofCard>
        <ProofCard title="Works offline" tone="orange">Changes queue and reconcile later.</ProofCard>
        <ProofCard title="Quiet by design" tone="orange">The panel collapses back to a one-row status.</ProofCard>
      </div>
    </section>
  );
}

function HowItWorks() {
  const steps = [
    ["Install iAgent", "Add the Mac panel and iPhone companion."],
    ["Connect your day", "Grant only the Calendar, microphone, and sync access you want."],
    ["Keep moving", "Open one panel to see, capture, ask, and act."],
  ];

  return (
    <section className="how-section section-rail" id="download" aria-labelledby="how-title">
      <img className="how-watermark" src={media.icon} alt="" aria-hidden="true" />
      <p className="eyebrow eyebrow-blue">How it works</p>
      <h2 id="how-title">Ready to make the day feel lighter?</h2>
      <p className="how-subtitle">Start in three small steps.</p>
      <div className="steps-grid">
        {steps.map(([title, description], index) => (
          <article key={title}>
            <span aria-hidden="true">{index + 1}</span>
            <h3>{title}</h3>
            <p>{description}</p>
          </article>
        ))}
      </div>
      <div className="how-onboarding">
        <DeviceStage className="how-onboarding-stage">
          <IPhoneDevice label="The iAgent welcome screen on iPhone">
            <SequenceImage
              frames={[media.mobile.welcome]}
              alt="The iAgent welcome screen with a Get started button on iPhone"
              className="device-screen-media"
            />
          </IPhoneDevice>
        </DeviceStage>
        <div>
          <p className="artifact-kicker">A native companion from first launch</p>
          <h3>Start small, then carry the whole day with you</h3>
          <p>
            The iPhone app opens into the same local-first system—Today, Codex, Notes, Todos,
            meetings, and reviewed actions—without turning your work into another cloud workspace.
          </p>
        </div>
      </div>
      <CTA href="#meetings">See iAgent in action</CTA>
    </section>
  );
}

function FAQ() {
  const [open, setOpen] = useState(null);
  const baseId = useId();
  return (
    <section className="faq-section section-rail" aria-labelledby="faq-title">
      <h2 id="faq-title">FAQs</h2>
      <p>Private by default, explicit when an action matters.</p>
      <div className="faq-card">
        {faqs.map(([question, answer], index) => {
          const expanded = open === index;
          const buttonId = `${baseId}-question-${index}`;
          const answerId = `${baseId}-answer-${index}`;
          return (
            <article className={`faq-item ${expanded ? "is-open" : ""}`} key={question} id={index === 1 ? "privacy" : undefined}>
              <h3>
                <button
                  type="button"
                  id={buttonId}
                  aria-controls={answerId}
                  aria-expanded={expanded}
                  onClick={() => setOpen(expanded ? null : index)}
                >
                  {question}
                  <ChevronDown className="faq-chevron" aria-hidden="true" />
                </button>
              </h3>
              <div
                className="faq-answer-shell"
                id={answerId}
                role="region"
                aria-labelledby={buttonId}
                aria-hidden={!expanded}
              >
                <div><p>{answer}</p></div>
              </div>
            </article>
          );
        })}
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <div className="footer-inner">
        <div className="footer-links">
          <div>
            <h2>Product</h2>
            <a href="#overview">Overview</a>
            <a href="#meetings">Meetings</a>
            <a href="#ask">Ask iAgent</a>
            <a href="#today">Today</a>
            <a href="#privacy">Privacy</a>
            <a href="#hero-changelog">Changelog</a>
          </div>
          <div>
            <h2>Company</h2>
            <a href="#download">Download</a>
            <a href="#faq-title">Support</a>
            <a href="#download">Private beta</a>
            <a href="#faq-title">Contact</a>
          </div>
          <div className="footer-note">
            <h2>Built for your devices</h2>
            <p>macOS panel</p>
            <p>iPhone companion</p>
            <p>Optional private CloudKit sync</p>
          </div>
        </div>
        <div className="footer-breathing-room" aria-hidden="true" />
        <div className="footer-bottom">
          <a className="footer-brand" href="#top" aria-label="Back to the top of iAgent">
            <img src={media.icon} alt="" width="52" height="52" />
            <span><strong>iAgent</strong><small>Designed for the top edge of your day</small></span>
          </a>
          <div className="legal-links">
            <a href="#privacy">Privacy</a>
            <a href="#faq-title">Terms</a>
            <span>© iAgent 2026</span>
          </div>
        </div>
      </div>
    </footer>
  );
}

export function App() {
  useEffect(() => {
    document.title = "iAgent — Your private AI command center";
  }, []);

  return (
    <>
      <style>{styles}</style>
      <a className="skip-link" href="#content">Skip to content</a>
      <SiteNav />
      <main id="content">
        <Hero />
        <CapabilityRail />
        <ValuePromise />
        <MeetingSection />
        <OutcomePlan />
        <AskSection />
        <ConnectedSystem />
        <KnowledgeSection />
        <TodaySection />
        <HowItWorks />
        <FAQ />
      </main>
      <Footer />
    </>
  );
}

const styles = String.raw`
  :root {
    color: rgba(255, 255, 255, .96);
    background: #000;
    color-scheme: dark;
    font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif;
    font-synthesis: none;
    --rail: 976px;
    --canvas: #000;
    --sheet: #1b1b1c;
    --sheet-raised: #252526;
    --surface: rgba(255, 255, 255, .055);
    --raised-surface: rgba(255, 255, 255, .09);
    --selected-surface: rgba(255, 255, 255, .12);
    --border: rgba(255, 255, 255, .075);
    --strong-border: rgba(255, 255, 255, .15);
    --primary: rgba(255, 255, 255, .96);
    --secondary: rgba(255, 255, 255, .48);
    --tertiary: rgba(255, 255, 255, .25);
    --coral: #ff524a;
    --blue: #299eff;
    --blue-dark: #1687e5;
    --green: #33d680;
    --purple: #7563ff;
    --orange: #f5b83f;
    --muted: rgba(255, 255, 255, .56);
    --line: rgba(255, 255, 255, .075);
    --ease: cubic-bezier(.22, .61, .36, 1);
    --ease-out: cubic-bezier(.23, 1, .32, 1);
    --ease-in-out: cubic-bezier(.77, 0, .175, 1);
  }

  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body { background: var(--canvas); color: var(--primary); font-size: 16px; line-height: 28px; }
  button, a { -webkit-tap-highlight-color: transparent; }
  button { font: inherit; }
  a { color: inherit; }
  img { display: block; max-width: 100%; }
  p { margin: 0; }
  h1, h2, h3 { margin: 0; }
  section[id], article[id], h2[id] { scroll-margin-top: 92px; }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }

  .skip-link {
    position: fixed;
    z-index: 100;
    top: 8px;
    left: 8px;
    padding: 10px 14px;
    border-radius: 10px;
    background: var(--primary);
    color: var(--canvas);
    transform: translateY(-150%);
    transition: transform 180ms var(--ease);
  }
  .skip-link:focus { transform: translateY(0); }

  .site-nav-shell {
    position: sticky;
    z-index: 50;
    top: 0;
    height: 60px;
    border-bottom: 1px solid var(--border);
    background: rgba(0, 0, 0, .78);
    backdrop-filter: blur(20px) saturate(125%);
  }
  .site-nav {
    width: min(calc(100% - 48px), var(--rail));
    height: 60px;
    margin: 0 auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .brand, .footer-brand {
    text-decoration: none;
    display: inline-flex;
    align-items: center;
    gap: 10px;
  }
  .brand img { width: 24px; height: 24px; border-radius: 7px; box-shadow: 0 0 0 1px var(--border), 0 6px 18px rgba(0, 0, 0, .42); }
  .brand span { display: none; }
  .nav-start, .nav-links { display: flex; align-items: center; gap: 24px; }
  .nav-text-link, .nav-button {
    font-size: 14px;
    font-weight: 590;
    text-decoration: none;
    color: var(--primary);
  }
  .nav-button {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 9px 4px;
    border: 0;
    background: transparent;
    cursor: pointer;
  }
  .nav-chevron, .faq-chevron {
    width: 14px;
    height: 14px;
    transform: rotate(0deg);
    transition: transform 220ms var(--ease);
  }
  .nav-chevron.is-open { transform: rotate(180deg); }
  .features-menu-wrap { position: relative; }
  .features-menu {
    position: absolute;
    top: calc(100% + 9px);
    left: -12px;
    width: 308px;
    padding: 8px;
    border: 1px solid var(--strong-border);
    border-radius: 18px;
    background: rgba(27, 27, 28, .97);
    box-shadow: 0 24px 64px rgba(0, 0, 0, .58), inset 0 1px 0 rgba(255, 255, 255, .035);
    animation: menu-in 180ms var(--ease) both;
  }
  .features-menu a {
    display: grid;
    gap: 2px;
    padding: 11px 12px;
    border-radius: 11px;
    text-decoration: none;
  }
  .features-menu a:hover, .features-menu a:focus-visible { background: var(--raised-surface); outline: none; }
  .features-menu span { font-size: 14px; font-weight: 680; }
  .features-menu small { color: var(--secondary); font-size: 12px; }
  @keyframes menu-in { from { opacity: 0; transform: translateY(-7px) scale(.98); } }

  .cta {
    min-height: 50px;
    padding: 0 26px;
    border: 1px solid transparent;
    border-radius: 12px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: #050506;
    background: var(--coral);
    box-shadow: 0 8px 24px rgba(255, 82, 74, .18);
    font-weight: 690;
    text-decoration: none;
    transition: transform 160ms var(--ease), background-color 160ms var(--ease), box-shadow 160ms var(--ease);
  }
  .cta:hover { transform: translateY(-1px); background: #ff6861; box-shadow: 0 12px 30px rgba(255, 82, 74, .24); }
  .cta:active { transform: translateY(0); }
  .cta-secondary { color: var(--primary); background: var(--surface); border-color: var(--strong-border); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .035); }
  .cta-secondary:hover { color: #fff; background: var(--raised-surface); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .055), 0 10px 24px rgba(0, 0, 0, .28); }
  .nav-cta { min-height: 32px; padding: 0 16px; border-radius: 8px; font-size: 14px; line-height: 20px; }

  .section-rail { width: min(calc(100% - 48px), var(--rail)); margin-inline: auto; }
  .hero { padding: 48px 0; }
  .proof-chips { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 24px; }
  .proof-chips span {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 32px;
    min-height: 32px;
    padding: 6px 12px;
    border: 1px solid var(--strong-border);
    border-radius: 999px;
    color: var(--secondary);
    background: var(--surface);
    font-size: 14px;
    line-height: 20px;
    font-weight: 600;
    text-align: center;
    white-space: nowrap;
  }
  .proof-chips span:first-child { width: 190px; }
  .proof-chips span:last-child { width: 181px; }
  .proof-chips span:first-child { color: var(--coral); background: rgba(255, 82, 74, .1); border-color: rgba(255, 82, 74, .32); }
  .hero h1 { max-width: 976px; font-size: 56px; line-height: 64px; font-weight: 700; letter-spacing: -.7px; }
  .hero-copy { max-width: 672px; margin-top: 20px; color: var(--muted); font-size: 20px; line-height: 28px; font-weight: 500; letter-spacing: 0; }
  .hero-actions { display: flex; gap: 10px; margin-top: 20px; }
  .changelog {
    width: fit-content;
    margin-top: 48px;
    display: flex;
    align-items: center;
    gap: 9px;
    color: var(--secondary);
    font-size: 13px;
    line-height: 15.84px;
    text-decoration: none;
  }
  .changelog span { min-height: 16px; padding: 1px 5px; display: inline-flex; align-items: center; border-radius: 999px; color: #050506; background: var(--coral); font-size: 9px; line-height: 14px; font-weight: 800; text-transform: uppercase; letter-spacing: .06em; }
  .device-stage {
    position: relative;
    overflow: hidden;
    border: 1px solid var(--strong-border);
    border-radius: 20px;
    background-color: #111214;
    background-position: center;
    background-repeat: no-repeat;
    background-size: cover;
    box-shadow: 0 0 0 1px rgba(255,255,255,.025), 0 18px 52px rgba(0,0,0,.38), inset 0 1px 0 rgba(255,255,255,.035);
  }

  .mac-device, .iphone-device { position: relative; z-index: 1; margin: 0; flex: 0 0 auto; filter: drop-shadow(0 26px 34px rgba(0, 0, 0, .45)); }
  .mac-device { width: 100%; aspect-ratio: 1210 / 930; }
  .iphone-device { width: 100%; aspect-ratio: 565 / 1175; }
  .mac-device-screen, .iphone-device-screen { position: absolute; z-index: 1; background: #000; }
  .mac-device-screen { overflow: hidden; }
  .mac-device-screen { left: 1.405%; top: 1.828%; width: 97.19%; height: 70.753%; }
  .iphone-device-screen { left: 4.071%; top: 1.617%; width: 92.035%; height: 96.766%; border-radius: 9.2% / 4.45%; }
  .mac-device-frame, .iphone-device-frame { position: absolute; z-index: 2; inset: 0; width: 100%; height: 100%; object-fit: contain; pointer-events: none; }
  .device-screen-fill, .device-screen-media, .device-screen-media > img, .device-screen-media > video { width: 100%; height: 100%; }
  .device-screen-fill { display: block; object-fit: cover; object-position: center top; }
  .device-screen-media { overflow: hidden; }
  .device-screen-media > img, .device-screen-media > video { display: block; object-fit: cover; }
  .iphone-device-screen .device-screen-media { overflow: visible; }
  .iphone-device-screen .device-screen-media > img,
  .iphone-device-screen .device-screen-media > video { border-radius: 9.2% / 4.45%; }
  .mac-desktop-state { position: relative; width: 100%; height: 100%; overflow: hidden; background: #000; }
  .mac-desktop-wallpaper { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; object-position: center top; }
  .mac-panel-sequence { position: absolute; z-index: 1; top: 5%; left: 50%; width: 86%; transform: translateX(-50%); }
  .mac-panel-sequence img { width: 100%; border-radius: 1.2vw; filter: drop-shadow(0 12px 18px rgba(0, 0, 0, .36)); }
  .mac-state-note .mac-panel-sequence { width: 87%; }
  .mac-state-calendar .mac-panel-sequence { top: 8%; width: 88%; }
  .mac-state-todo .mac-panel-sequence { top: 10%; width: 88%; }
  .mac-state-recorder .mac-panel-sequence { top: 9%; width: 88%; }

  .golden-flow { position: relative; width: 100%; }
  .demo-playback {
    position: absolute;
    z-index: 4;
    right: 3.5%;
    bottom: 31%;
    min-height: 34px;
    padding: 7px 11px;
    display: inline-flex;
    align-items: center;
    gap: 7px;
    border: 1px solid rgba(255,255,255,.16);
    border-radius: 999px;
    color: rgba(255,255,255,.84);
    background: rgba(7,7,8,.76);
    backdrop-filter: blur(14px);
    font-size: 11px;
    line-height: 1;
    cursor: pointer;
    transition: transform 180ms var(--ease-out), background-color 180ms var(--ease-out);
  }
  .demo-playback:hover { transform: translateY(-1px); background: rgba(24,24,26,.9); }

  .hero-stage { height: 700px; margin-top: 11px; }
  .hero-mac-flow { position: absolute; left: 24px; top: 29px; width: 770px; }
  .hero-phone-device { position: absolute; z-index: 3; top: 227px; right: 24px; width: 154px; filter: drop-shadow(0 30px 32px rgba(0,0,0,.5)); }
  .hero-demo-note { position: absolute; right: 28px; bottom: 22px; left: 28px; color: rgba(255,255,255,.66); font-size: 12px; text-align: center; }

  .sequence-image img, .sequence-image video { animation: frame-in 460ms var(--ease-out) both; }
  .sequence-image video { display: block; width: 100%; }
  .sequence-image { position: relative; }
  .sequence-playback {
    position: absolute;
    z-index: 5;
    right: 9px;
    bottom: 9px;
    width: 30px;
    height: 30px;
    padding: 0;
    display: grid;
    place-items: center;
    border: 1px solid rgba(255,255,255,.18);
    border-radius: 50%;
    color: rgba(255,255,255,.9);
    background: rgba(6,6,7,.78);
    backdrop-filter: blur(12px);
    cursor: pointer;
    transition: transform 180ms var(--ease-out), background-color 180ms var(--ease-out);
  }
  .sequence-playback:hover { transform: scale(1.04); background: rgba(28,28,30,.92); }
  .iphone-device-screen .sequence-playback {
    top: 10px;
    right: auto;
    bottom: auto;
    left: calc(100% + 14px);
    width: 44px;
    height: 44px;
    box-shadow: 0 10px 26px rgba(0,0,0,.34);
  }
  .hero-phone-device .sequence-playback {
    right: calc(100% + 14px);
    left: auto;
  }
  @keyframes frame-in { from { opacity: .18; transform: scale(1.006); } to { opacity: 1; transform: scale(1); } }

  .capability-section { height: 144px; margin-top: 96px; margin-bottom: 128px; overflow: hidden; }
  .capability-section > p { margin-bottom: 12px; color: var(--secondary); font-size: 14px; }
  .capability-section > small { display: block; margin-top: 16px; color: var(--secondary); font-size: 11px; font-style: italic; }
  .marquee { overflow: hidden; mask-image: linear-gradient(90deg, transparent, #000 5%, #000 95%, transparent); }
  .marquee-track { display: flex; width: max-content; animation: marquee 70s linear infinite; }
  .marquee-group { display: flex; align-items: center; gap: 48px; padding-right: 48px; }
  .marquee-group span { color: var(--secondary); font-size: 23px; font-weight: 650; white-space: nowrap; letter-spacing: -.03em; }
  .marquee-group span::after { content: "·"; margin-left: 48px; color: var(--tertiary); }
  .marquee-group span:last-child::after { content: ""; margin: 0; }
  @keyframes marquee { to { transform: translateX(-50%); } }
  .marquee-subtle { margin: 36px 0 68px; padding: 13px 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
  .marquee-subtle .marquee-group span { color: var(--secondary); font-size: 18px; font-weight: 500; }

  .value-promise { margin-bottom: 192px; display: grid; gap: 20px; justify-items: start; }
  .value-promise h2 { font-size: 56px; line-height: 64px; font-weight: 700; letter-spacing: -.7px; }
  .value-promise h2 span { padding: 0 .08em; border-radius: .12em; color: var(--primary); background: var(--selected-surface); box-decoration-break: clone; -webkit-box-decoration-break: clone; }

  .feature-section { margin-bottom: 192px; }
  .section-header { display: grid; gap: 14px; }
  .eyebrow { font-size: 15px; font-weight: 710; letter-spacing: -.015em; }
  .eyebrow-blue { color: var(--blue); }
  .eyebrow-green { color: var(--green); }
  .eyebrow-purple { color: var(--purple); }
  .eyebrow-orange { color: var(--orange); }
  .section-header h2 { max-width: 900px; font-size: 40px; line-height: 54.4px; font-weight: 700; letter-spacing: -.5px; }
  .replaces { margin-top: 3px; color: var(--secondary); font-size: 15px; }
  .replaces strong { color: var(--primary); }
  .editorial-block { margin-top: 54px; max-width: 900px; display: grid; gap: 20px; }
  .editorial-block h3, .subsection-copy h3, .recorder-copy h3, .private-notes-grid h3, .ask-artifact h3, .mobile-flow-intro h3, .how-onboarding h3 { font-size: 22px; line-height: 1.2; }
  .editorial-block p, .subsection-copy p, .recorder-copy > p, .private-notes-grid p, .system-copy p, .section-intro, .mini-features p, .ask-artifact p, .mobile-flow-intro > p:last-child, .how-onboarding > div:last-child > p:last-child {
    color: var(--muted);
    font-size: 16px;
    line-height: 28px;
    letter-spacing: 0;
  }
  .proof-grid { display: grid; gap: 0; margin-top: 42px; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
  .proof-grid-two { grid-template-columns: repeat(2, 1fr); }
  .proof-grid-three { grid-template-columns: repeat(3, 1fr); }
  .proof-card { position: relative; min-height: 188px; padding: 34px 32px 30px 28px; }
  .proof-card + .proof-card { border-left: 1px solid var(--line); }
  .proof-dot { display: block; width: 9px; height: 9px; margin-bottom: 25px; border-radius: 50%; background: var(--green); }
  .proof-orange .proof-dot { background: var(--orange); }
  .proof-card h3 { font-size: 18px; }
  .proof-card p { max-width: 360px; margin-top: 9px; color: var(--muted); font-size: 15px; line-height: 1.55; }
  .meeting-story-grid {
    min-height: 228px;
    margin-top: 48px;
    padding: 24px 0;
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 48px;
    border-top: 1px solid var(--line);
    border-bottom: 1px solid var(--line);
  }
  .meeting-story-grid article { display: grid; align-content: start; gap: 14px; }
  .meeting-story-grid h3 { font-size: 20px; line-height: 28px; font-weight: 600; letter-spacing: -.5px; }
  .meeting-story-grid p { color: var(--muted); font-size: 16px; line-height: 28px; }
  .meeting-story-grid-final { margin-top: 56px; }
  .ask-proof-grid { margin-top: 42px; }
  #ask { padding-bottom: 46px; }
  .bordered-copy { margin-top: 64px; padding-top: 32px; border-top: 1px solid var(--line); }
  .subsection-copy { display: grid; gap: 12px; }

  .meeting-golden-stage { min-height: 682px; margin-top: 34px; padding: 34px 42px 66px; }
  .meeting-golden-stage .golden-flow { max-width: 842px; margin: 0 auto; }
  .demo-timeline {
    position: absolute;
    right: 30px;
    bottom: 22px;
    left: 30px;
    margin: 0;
    padding: 0;
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    list-style: none;
    color: rgba(255,255,255,.66);
    font-size: 11px;
    text-align: center;
  }
  .demo-timeline li { position: relative; padding-top: 10px; border-top: 1px solid rgba(255,255,255,.18); }
  .demo-timeline li::before { content: ""; position: absolute; top: -3px; left: 50%; width: 5px; height: 5px; border-radius: 50%; background: rgba(255,255,255,.52); }
  .demo-timeline li:nth-child(2)::before { background: var(--coral); box-shadow: 0 0 0 4px rgba(255,82,74,.14); }
  .mobile-flow-intro { max-width: 690px; margin: 66px auto 0; display: grid; gap: 12px; text-align: center; }
  .meeting-mobile-showcase { margin-top: 28px; }

  .product-showcase { margin-top: 34px; overflow: hidden; border: 1px solid var(--strong-border); border-radius: 12px; background-color: #111214; background-image: url(${media.stageLight}); background-position: center; background-size: cover; box-shadow: 0 18px 48px rgba(0,0,0,.34), inset 0 1px 0 rgba(255,255,255,.025); }
  .showcase-blue, .showcase-dark, .showcase-gray, .showcase-warm { background-color: #111214; }
  .showcase-tabs { display: grid; grid-template-columns: repeat(3, 1fr); background: rgba(0, 0, 0, .34); backdrop-filter: blur(12px); }
  .showcase-gray .showcase-tabs, .showcase-warm .showcase-tabs { background: rgba(0, 0, 0, .3); }
  .showcase-tabs button {
    min-height: 64px;
    padding: 12px;
    border: 0;
    border-right: 1px solid rgba(255, 255, 255, .14);
    color: rgba(255, 255, 255, .64);
    background: transparent;
    font-weight: 680;
    cursor: pointer;
    transition: color 180ms var(--ease), background-color 180ms var(--ease);
  }
  .showcase-tabs button:last-child { border-right: 0; }
  .showcase-tabs button:hover, .showcase-tabs button:focus-visible { color: #fff; }
  .showcase-tabs button.is-active { color: #fff; background: rgba(255, 255, 255, .12); }
  .showcase-gray .showcase-tabs button, .showcase-warm .showcase-tabs button { color: rgba(255, 255, 255, .64); border-color: rgba(255, 255, 255, .14); }
  .showcase-gray .showcase-tabs button:hover, .showcase-gray .showcase-tabs button:focus-visible,
  .showcase-warm .showcase-tabs button:hover, .showcase-warm .showcase-tabs button:focus-visible,
  .showcase-gray .showcase-tabs button.is-active, .showcase-warm .showcase-tabs button.is-active { color: #fff; background: rgba(255, 255, 255, .12); }
  .showcase-panel { position: relative; min-height: 692px; padding: 34px 46px 74px; display: flex; align-items: center; justify-content: center; }
  .showcase-panel-desktop, .showcase-panel-desktop-wide { min-height: 650px; }
  .showcase-mac-device { width: min(100%, 826px); }
  .showcase-phone-device { width: 284px; }
  .showcase-caption {
    position: absolute;
    right: 24px;
    bottom: 20px;
    left: 24px;
    color: rgba(255, 255, 255, .82);
    font-size: 13px;
    text-align: center;
  }
  .showcase-gray .showcase-caption, .showcase-warm .showcase-caption { color: rgba(255, 255, 255, .72); }

  .recorder-story { display: grid; grid-template-columns: .72fr 1.28fr; align-items: center; gap: 54px; margin-top: 58px; }
  .recorder-copy { display: grid; gap: 15px; }
  .check-list { list-style: none; margin: 22px 0 0; padding: 0; display: grid; gap: 17px; }
  .check-list li { display: grid; grid-template-columns: 17px 1fr; gap: 10px; font-size: 15px; line-height: 1.48; }
  .check-list li > svg { margin-top: .24em; color: var(--green); }
  .recorder-visual { min-width: 0; min-height: 390px; padding: 30px 24px; display: grid; place-items: center; }
  .recorder-visual .mac-device { width: 100%; }
  .quote-rail { margin: 56px 0; padding: 5px 0 5px 22px; color: var(--primary); font-size: 17px; font-weight: 590; line-height: 1.55; border-left: 4px solid var(--green); }
  .quote-purple { border-color: var(--purple); }
  .native-stack { display: grid; grid-template-columns: repeat(6, 1fr); overflow: hidden; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); }
  .native-stack span { min-height: 80px; padding: 15px 9px; display: grid; place-items: center; border-right: 1px solid var(--line); color: var(--secondary); font-size: 12px; text-align: center; }
  .native-stack span:last-child { border-right: 0; }
  .private-notes-grid { margin-top: 58px; display: grid; grid-template-columns: .7fr 1.3fr; gap: 42px; align-items: center; }
  .private-notes-grid > div { display: grid; gap: 14px; }
  .inline-mac-stage { min-height: 378px; padding: 24px; display: grid; place-items: center; }
  .inline-mac-stage .mac-device { width: 100%; }

  .outcome-section { margin-bottom: 192px; text-align: center; }
  .outcome-section > h2 { max-width: 740px; margin: 0 auto; font-size: 40px; line-height: 54.4px; font-weight: 700; letter-spacing: -.5px; }
  .outcome-section > h2 span { padding: 0 .08em; border-radius: .12em; color: var(--blue); background: rgba(41, 158, 255, .12); box-decoration-break: clone; -webkit-box-decoration-break: clone; }
  .milestones { position: relative; margin: 62px 9% 40px; display: flex; justify-content: space-between; }
  .milestones::before { content: ""; position: absolute; z-index: -1; top: 50%; right: 2px; left: 2px; height: 1px; background: var(--strong-border); }
  .milestones button { min-width: 90px; padding: 10px 17px; border: 0; border-radius: 999px; color: var(--secondary); background: var(--raised-surface); cursor: pointer; transition: background 180ms var(--ease), color 180ms var(--ease), transform 180ms var(--ease); }
  .milestones button.is-active { color: #050506; background: var(--coral); transform: scale(1.03); }
  .outcome-cards { display: grid; grid-template-columns: repeat(3, 1fr); overflow: hidden; border: 1px solid var(--strong-border); border-radius: 16px; background: var(--surface); box-shadow: inset 0 1px 0 rgba(255, 255, 255, .025); text-align: left; }
  .outcome-card { min-height: 310px; padding: 34px 30px; }
  .outcome-card + .outcome-card { border-left: 1px solid var(--line); }
  .outcome-card > p { display: none; color: var(--secondary); font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .08em; }
  .outcome-card h3 { font-size: 21px; text-align: center; }
  .outcome-card .check-list { margin-top: 24px; }
  .outcome-section > .cta { margin-top: 56px; }

  .speech-card { max-width: 665px; margin: 46px 0 0; padding: 18px 22px; border-radius: 20px; background: var(--surface); box-shadow: inset 0 0 0 1px var(--border); font-size: 18px; line-height: 1.5; }
  .ask-artifact { margin-top: 54px; padding: 38px 54px; display: grid; grid-template-columns: 310px 1fr; gap: 56px; align-items: center; overflow: hidden; border: 1px solid var(--strong-border); border-radius: 22px; background: var(--surface); }
  .ask-device-stage { min-height: 560px; padding: 24px; display: grid; place-items: center; }
  .ask-device-stage .iphone-device { width: 228px; transform: translateX(-10px); }
  .ask-artifact > div { display: grid; gap: 13px; }
  .artifact-kicker { color: var(--blue) !important; font-size: 13px !important; font-weight: 720; text-transform: uppercase; letter-spacing: .06em !important; }
  .highlight-line { margin-top: 7px; color: var(--secondary); }
  .highlight-line span { padding: 2px 5px; border-radius: 5px; color: var(--blue); background: rgba(41, 158, 255, .12); }
  .phone-showcase .showcase-panel { min-height: 730px; }

  .system-copy { grid-template-columns: repeat(3, 1fr); max-width: none; gap: 28px; }
  .system-diagram {
    position: relative;
    min-height: 560px;
    margin-top: 48px;
    padding: 62px 70px;
    display: grid;
    grid-template-columns: 1fr 190px 1fr;
    align-items: center;
    gap: 55px;
    overflow: hidden;
    border: 1px solid var(--line);
    border-radius: 22px;
    background: var(--surface);
  }
  .system-diagram::before, .system-diagram::after { content: ""; position: absolute; top: 50%; width: 33%; height: 1px; background: var(--strong-border); }
  .system-diagram::before { left: 25%; }
  .system-diagram::after { right: 25%; }
  .diagram-column { position: relative; z-index: 1; display: grid; gap: 12px; }
  .diagram-column > p { margin-bottom: 4px; color: var(--secondary); font-size: 11px; font-weight: 750; text-transform: uppercase; letter-spacing: .12em; }
  .diagram-column span { min-height: 48px; padding: 11px 15px; display: grid; align-items: center; border: 1px solid var(--border); border-radius: 12px; background: var(--raised-surface); font-size: 14px; font-weight: 650; }
  .diagram-destinations { text-align: right; }
  .diagram-center { position: relative; z-index: 2; display: grid; justify-items: center; gap: 7px; }
  .diagram-center img { width: 124px; border-radius: 28px; box-shadow: 0 0 0 1px var(--strong-border), 0 18px 36px rgba(0, 0, 0, .54); }
  .diagram-center strong { margin-top: 5px; font-size: 17px; }
  .diagram-center small { color: var(--secondary); }
  .diagram-caption { margin-top: 16px; color: var(--secondary); font-size: 12px; text-align: center; }
  .directory-grid { margin-top: 48px; display: grid; grid-template-columns: repeat(3, 1fr); gap: 63px 42px; }
  .directory-grid article { display: grid; grid-template-columns: 46px 1fr; gap: 14px; align-items: center; }
  .directory-mark { width: 46px; height: 46px; display: grid; place-items: center; border: 1px solid var(--strong-border); border-radius: 12px; color: var(--secondary); background: var(--raised-surface); }
  .directory-grid h3 { font-size: 16px; letter-spacing: -.02em; }
  .directory-grid p { margin-top: 2px; color: var(--muted); font-size: 13px; line-height: 1.35; }

  .knowledge-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; margin-top: 44px; }
  .knowledge-grid article { min-height: 300px; padding: 25px; border-top: 1px solid var(--line); }
  .knowledge-grid span { color: var(--purple); font-size: 12px; font-weight: 800; letter-spacing: .08em; }
  .knowledge-grid h3 { margin-top: 33px; font-size: 19px; }
  .knowledge-grid p { margin-top: 9px; color: var(--muted); font-size: 15px; line-height: 1.5; }

  .section-intro { max-width: 890px; margin-top: 42px; }
  .mini-features { margin-top: 48px; display: grid; grid-template-columns: repeat(2, 1fr); gap: 48px; }
  .mini-features article { min-width: 0; }
  .mini-features h3 { font-size: 21px; }
  .mini-features p { min-height: 88px; margin-top: 10px; }
  .mini-media { margin-top: 22px; min-height: 360px; padding: 24px 18px; display: grid; place-items: center; overflow: hidden; border: 1px solid var(--strong-border); border-radius: 16px; background-color: #111214; background-image: url(${media.stageLight}); background-position: center; background-size: cover; }
  .mini-media .mac-device { width: 100%; }
  .phone-mini-media .iphone-device { width: 148px; }
  .today-mobile-showcase { margin-top: 42px; }
  #today .proof-card { min-height: 91px; padding: 18px 20px; }

  .how-section {
    position: relative;
    min-height: 562px;
    margin-bottom: 192px;
    padding: 64px 40px 40px;
    overflow: hidden;
    border: 1px solid var(--strong-border);
    border-radius: 12px;
    background: rgba(17, 17, 18, .92);
    box-shadow: inset 0 1px 0 rgba(255,255,255,.035), 0 24px 60px rgba(0,0,0,.36);
    text-align: center;
  }
  .how-watermark { position: absolute; top: -195px; left: 50%; width: 590px; opacity: .065; transform: translateX(-50%); pointer-events: none; }
  .how-section > *:not(.how-watermark) { position: relative; z-index: 1; }
  .how-section h2 { margin-top: 18px; font-size: 40px; line-height: 54.4px; letter-spacing: -.5px; }
  .how-subtitle { margin-top: 0; color: var(--secondary); font-size: 40px; line-height: 54.4px; font-weight: 700; letter-spacing: -.5px; }
  .steps-grid { margin-top: 44px; display: grid; grid-template-columns: repeat(3, 1fr); }
  .steps-grid article { padding: 0 26px; }
  .steps-grid article + article { border-left: 1px solid var(--line); }
  .steps-grid article > span { width: 50px; height: 50px; margin: 0 auto 22px; display: grid; place-items: center; border-radius: 50%; color: #050506; background: var(--blue); font-size: 20px; font-weight: 760; }
  .steps-grid h3 { font-size: 19px; }
  .steps-grid p { max-width: 260px; margin: 9px auto 0; color: var(--muted); font-size: 15px; line-height: 1.55; }
  .how-onboarding { max-width: 780px; margin: 48px auto 0; padding-top: 42px; display: grid; grid-template-columns: 250px 1fr; gap: 44px; align-items: center; border-top: 1px solid var(--line); text-align: left; }
  .how-onboarding-stage { min-height: 350px; padding: 24px; display: grid; place-items: center; }
  .how-onboarding-stage .iphone-device { width: 138px; }
  .how-onboarding > div:last-child { display: grid; gap: 13px; }
  .how-section > .cta { margin-top: 28px; }

  .faq-section { margin-bottom: 0; text-align: center; }
  .faq-section > h2 { font-size: 40px; line-height: 54.4px; letter-spacing: -.5px; }
  .faq-section > p { margin-top: 14px; color: var(--muted); }
  .faq-card { margin-top: 48px; overflow: hidden; border: 1px solid var(--strong-border); border-radius: 17px; background: var(--surface); text-align: left; }
  .faq-item + .faq-item { border-top: 1px solid var(--line); }
  .faq-item h3 { margin: 0; }
  .faq-item button { width: 100%; min-height: 68px; padding: 19px 22px; display: flex; align-items: center; justify-content: space-between; gap: 24px; border: 0; color: var(--primary); background: transparent; font-weight: 590; text-align: left; cursor: pointer; }
  .faq-item button:hover, .faq-item button:focus-visible { background: var(--raised-surface); }
  .faq-chevron { flex: 0 0 auto; color: var(--secondary); }
  .faq-item.is-open .faq-chevron { transform: rotate(180deg); }
  .faq-answer-shell { display: grid; grid-template-rows: 0fr; transition: grid-template-rows 300ms var(--ease); }
  .faq-answer-shell > div { overflow: hidden; }
  .faq-answer-shell p { max-width: 810px; padding: 0 58px 0 22px; color: var(--muted); font-size: 15px; line-height: 1.6; opacity: 0; transform: translateY(-5px); transition: opacity 240ms var(--ease), transform 240ms var(--ease), padding 300ms var(--ease); }
  .faq-item.is-open .faq-answer-shell { grid-template-rows: 1fr; }
  .faq-item.is-open .faq-answer-shell p { padding-bottom: 22px; opacity: 1; transform: none; }

  .footer { margin-top: 1px; padding: 72px 0 40px; border-top: 1px solid var(--line); }
  .footer-inner { width: min(calc(100% - 48px), var(--rail)); margin: 0 auto; }
  .footer-links { display: grid; grid-template-columns: 1.1fr .9fr 1.2fr; gap: 60px; }
  .footer-links > div { display: grid; align-content: start; gap: 11px; }
  .footer-links h2 { margin-bottom: 5px; color: var(--secondary); font-size: 11px; text-transform: uppercase; letter-spacing: .12em; }
  .footer-links a { width: fit-content; font-size: 14px; text-decoration: none; }
  .footer-links a:hover { text-decoration: underline; text-underline-offset: 3px; }
  .footer-note p { color: var(--muted); font-size: 14px; }
  .footer-breathing-room { height: 109px; }
  .footer-bottom { padding-top: 28px; display: flex; justify-content: space-between; gap: 24px; border-top: 1px solid var(--line); }
  .footer-brand img { border-radius: 13px; box-shadow: 0 0 0 1px var(--strong-border), 0 12px 28px rgba(0, 0, 0, .46); }
  .footer-brand span { display: grid; gap: 2px; }
  .footer-brand strong { font-size: 17px; }
  .footer-brand small { color: var(--secondary); font-size: 12px; }
  .legal-links { display: flex; align-items: flex-end; gap: 26px; color: var(--secondary); font-size: 13px; }
  .legal-links a { text-decoration: none; }

  @media (min-width: 761px) {
    #today .mini-features { margin-top: 28px; }
    #today .proof-grid { margin-top: 0; }
    .faq-card { margin-top: 41px; }
  }

  @media (min-width: 761px) and (max-width: 860px) {
    .hero-mac-flow { width: calc(100% - 48px); }
    .ask-device-stage .iphone-device { transform: translateX(-10px); }
    .recorder-visual .mac-device,
    .inline-mac-stage .mac-device,
    .mini-media .mac-device { width: min(100%, 430px); }
  }

  :focus-visible { outline: 3px solid var(--blue); outline-offset: 3px; }

  @media (max-width: 760px) {
    :root { --rail: 100%; }
    .section-rail, .site-nav, .footer-inner { width: calc(100% - 48px); }
    .nav-start { gap: 14px; }
    .nav-links { gap: 12px; }
    .nav-desktop-link { display: none; }
    .nav-button { font-size: 13px; }
    .nav-cta { min-height: 32px; padding: 0 16px; }
    .features-menu { position: fixed; top: 66px; right: 24px; left: 24px; width: auto; }

    .hero { padding: 48px 0; }
    .proof-chips { margin-bottom: 24px; gap: 8px; flex-direction: column; align-items: flex-start; }
    .proof-chips span { font-size: 14px; }
    .hero h1 { font-size: 28px; line-height: 35px; letter-spacing: -.003px; }
    .hero-copy { margin-top: 20px; font-size: 18px; line-height: 28px; }
    .hero-actions { display: grid; grid-template-columns: 130px 1fr; margin-top: 20px; }
    .hero-actions .cta { min-height: 48px; padding-inline: 14px; font-size: 14px; line-height: 20px; }
    .changelog { align-items: flex-start; margin-top: 48px; }
    .hero-stage { height: 420px; min-height: 420px; margin-top: 12px; border-radius: 16px; overflow: hidden; }
    .hero-mac-flow { left: 10px; top: 22px; width: min(314px, calc(100% - 20px)); }
    .hero-phone-device { top: 196px; right: 14px; width: 100px; }
    .hero-demo-note { right: 128px; bottom: 14px; left: 18px; font-size: 10px; line-height: 1.35; text-align: left; }
    .demo-playback { right: 2%; bottom: 30%; min-height: 29px; padding: 6px; }
    .demo-playback span { display: none; }

    .capability-section { height: 144px; margin-top: 96px; margin-bottom: 128px; }
    .marquee-group { gap: 34px; padding-right: 34px; }
    .marquee-group span { font-size: 20px; }
    .marquee-group span::after { margin-left: 34px; }

    .value-promise { margin-bottom: 64px; }
    .value-promise h2 { font-size: 28px; line-height: 35px; letter-spacing: -.003px; }
    .value-promise .cta { min-height: 44px; font-size: 14px; line-height: 20px; }
    .feature-section, .outcome-section, .how-section { margin-bottom: 64px; }
    .section-header { gap: 10px; }
    .section-header h2 { font-size: 24px; line-height: 32px; letter-spacing: -.6px; }
    .editorial-block { margin-top: 38px; gap: 17px; }
    .editorial-block p, .subsection-copy p, .recorder-copy > p, .private-notes-grid p, .system-copy p, .section-intro, .mini-features p, .ask-artifact p, .mobile-flow-intro > p:last-child, .how-onboarding > div:last-child > p:last-child { font-size: 16px; line-height: 28px; }
    .proof-grid-two, .proof-grid-three { grid-template-columns: 1fr; }
    .proof-card { min-height: 0; padding: 27px 8px; }
    .proof-card + .proof-card { border-top: 1px solid var(--line); border-left: 0; }
    .proof-dot { margin-bottom: 17px; }
    .meeting-story-grid {
      min-height: 483px;
      padding: 8px 0;
      grid-template-columns: 1fr;
      align-content: space-between;
      gap: 20px;
    }
    .meeting-story-grid-final { margin-top: 48px; }
    .bordered-copy { margin-top: 48px; }

    .meeting-golden-stage { min-height: 326px; margin-top: 28px; padding: 20px 12px 58px; border-radius: 16px; }
    .meeting-golden-stage .golden-flow { width: 100%; }
    .demo-timeline { right: 12px; bottom: 14px; left: 12px; font-size: 8px; }
    .demo-timeline li { padding-top: 8px; }
    .mobile-flow-intro { margin-top: 44px; text-align: left; }
    .product-showcase { margin-right: 0; margin-left: 0; border-radius: 12px; }
    .showcase-tabs { display: flex; overflow-x: auto; scroll-snap-type: x mandatory; scrollbar-width: none; }
    .showcase-tabs::-webkit-scrollbar { display: none; }
    .showcase-tabs button { min-width: 135px; min-height: 58px; padding: 11px 9px; scroll-snap-align: start; font-size: 13px; }
    .showcase-panel, .showcase-panel-desktop, .showcase-panel-desktop-wide { min-height: 350px; height: auto; padding: 18px 12px 66px; }
    .showcase-mac-device { width: min(302px, 100%); }
    .showcase-phone-device { width: 190px; }
    .showcase-caption { bottom: 15px; z-index: 5; min-height: 34px; padding: 7px 10px; border-radius: 10px; background: rgba(7,7,8,.78); backdrop-filter: blur(10px); font-size: 11px; line-height: 1.45; }
    .phone-showcase .showcase-panel { min-height: 520px; height: auto; }

    .recorder-story { grid-template-columns: 1fr; gap: 34px; margin-top: 48px; }
    .recorder-visual { min-height: 300px; padding: 20px 12px; overflow: hidden; }
    .recorder-visual .mac-device { width: min(314px, 100%); }
    .native-stack { grid-template-columns: repeat(3, 1fr); }
    .native-stack span { min-height: 68px; border-bottom: 1px solid var(--line); }
    .native-stack span:nth-child(3n) { border-right: 0; }
    .private-notes-grid { grid-template-columns: 1fr; gap: 28px; }
    .inline-mac-stage { min-height: 300px; padding: 18px 12px; }
    .inline-mac-stage .mac-device { width: min(314px, 100%); }

    .outcome-section > h2 { max-width: 300px; font-size: 24px; line-height: 32px; letter-spacing: -.6px; }
    .milestones { display: none; }
    .milestones button { min-width: 78px; padding: 8px 12px; font-size: 13px; }
    .outcome-cards { display: block; margin-top: 64px; }
    .outcome-card { display: block; min-height: 344px; padding: 32px; }
    .outcome-card.is-active { display: block; }
    .outcome-card + .outcome-card { border-top: 1px solid var(--line); border-left: 0; }
    .outcome-card > p { display: block; }
    .outcome-card h3 { margin-top: 7px; text-align: left; }
    @keyframes card-in { from { opacity: .25; transform: translateY(5px); } }
    .outcome-section > .cta { margin-top: 36px; }
    .outcome-section > .cta { margin-top: 53px; }

    .speech-card { margin-top: 34px; font-size: 17px; }
    .ask-artifact { margin-top: 38px; padding: 24px 20px; grid-template-columns: 1fr; gap: 28px; }
    #ask { padding-bottom: 0; }
    .ask-proof-grid .proof-card { padding: 16px 8px; }
    .ask-device-stage { min-height: 396px; padding: 18px; }
    .ask-device-stage .iphone-device { width: 174px; }
    .ask-artifact h3 { font-size: 18px; }
    .ask-artifact p { font-size: 14px; }
    .artifact-kicker { font-size: 10px !important; }

    .system-copy { grid-template-columns: 1fr; gap: 14px; }
    .system-diagram { display: none; }
    .system-diagram::before, .system-diagram::after { display: none; }
    .diagram-column span { min-height: 55px; padding: 9px; font-size: 11px; }
    .diagram-center img { width: 82px; border-radius: 19px; }
    .diagram-center strong { font-size: 14px; }
    .diagram-center small { font-size: 9px; }
    .directory-grid { grid-template-columns: repeat(2, 1fr); gap: 65px 20px; }
    .directory-grid article { grid-template-columns: 40px 1fr; gap: 10px; }
    .directory-mark { width: 40px; height: 40px; }
    .directory-grid h3 { font-size: 14px; }
    .directory-grid p { font-size: 11px; }

    .knowledge-grid { grid-template-columns: 1fr; gap: 48px; }
    .knowledge-grid article { min-height: 248px; }
    .knowledge-grid h3 { margin-top: 22px; }

    .section-intro { margin-top: 34px; }
    .mini-features { grid-template-columns: 1fr; gap: 42px; }
    .mini-features p { min-height: 0; }
    .mini-media { min-height: 300px; padding: 18px 12px; }
    .mini-media .mac-device { width: min(314px, 100%); }
    .phone-mini-media .iphone-device { width: 132px; }
    .today-mobile-showcase { margin-top: 32px; }
    #today .proof-card { min-height: 0; padding: 18px 8px; }

    .how-section { width: calc(100% - 48px); min-height: 896px; padding: 64px 40px 40px; }
    .how-section h2 { font-size: 24px; line-height: 32px; letter-spacing: -.6px; }
    .how-subtitle { font-size: 24px; line-height: 32px; letter-spacing: -.6px; }
    .steps-grid { margin-top: 44px; grid-template-columns: 1fr; gap: 28px; }
    .steps-grid article + article { border-left: 0; }
    .steps-grid article > span { margin-bottom: 14px; }
    .how-onboarding { margin-top: 36px; padding-top: 34px; grid-template-columns: 1fr; gap: 24px; }
    .how-onboarding-stage { min-height: 304px; padding: 20px; }
    .how-onboarding-stage .iphone-device { width: 124px; }
    .how-section > .cta { margin-top: 24px; }

    .faq-section > h2 { font-size: 24px; line-height: 32px; letter-spacing: -.6px; }
    .faq-section > p { line-height: 1.5; }
    .faq-card { margin-right: -8px; margin-left: -8px; }
    .faq-item button { min-height: 92px; padding: 19px 18px; line-height: 1.45; }
    .faq-answer-shell p { padding-right: 42px; padding-left: 18px; }

    .footer { padding-top: 54px; }
    .footer-links { grid-template-columns: repeat(2, 1fr); gap: 44px 28px; }
    .footer-note { grid-column: 1 / -1; }
    .footer-breathing-room { height: 22px; }
    .footer-bottom { display: grid; }
    .legal-links { flex-wrap: wrap; align-items: center; gap: 18px; }
  }

  @media (max-width: 380px) {
    .section-rail, .site-nav, .footer-inner { width: calc(100% - 32px); }
    .nav-cta { padding-inline: 10px; }
    .hero h1, .value-promise h2 { font-size: 28px; line-height: 35px; }
    .section-header h2, .outcome-section > h2 { font-size: 24px; line-height: 32px; }
    .hero-actions { grid-template-columns: 126px 1fr; }
    .ask-artifact { grid-template-columns: 1fr; }
    .ask-device-stage { width: 100%; }
    .ask-device-stage .iphone-device { width: 166px; transform: translateX(-6px); }
    .iphone-device-screen .sequence-playback { left: calc(100% + 8px); }
    .hero-phone-device .sequence-playback { right: calc(100% + 14px); left: auto; }
    .system-diagram { grid-template-columns: 1fr 74px 1fr; }
    .diagram-center img { width: 68px; }
    .directory-grid { grid-template-columns: 1fr; }
  }

  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    *, *::before, *::after { animation-duration: .01ms !important; animation-iteration-count: 1 !important; scroll-behavior: auto !important; transition-duration: .01ms !important; }
    .marquee-track { width: 100%; animation: none; }
    .marquee-group { flex-wrap: wrap; }
    .marquee-group[aria-hidden="true"] { display: none; }
  }
`;
