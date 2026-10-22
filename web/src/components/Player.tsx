import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from "react";
import { clock } from "../lib/format";
import { BackIcon, ForwardIcon, LinkIcon, PauseIcon, PlayIcon } from "./Icons";

// The episode page's player: the app's Now Playing transport (skip back 15,
// play, skip forward 30, a speed button) around a plain <audio> element.

const SPEEDS = [1, 1.25, 1.5, 1.75, 2, 2.5, 3];
const SKIP_BACK = 15;
const SKIP_FORWARD = 30;

export type PlayerHandle = { seek: (seconds: number, play?: boolean) => void; position: () => number };

type Props = {
  src: string;
  type?: string;
  title: string;
  show: string;
  artwork?: string;
  /** From `?t=`. */
  startAt: number | null;
  /** The feed's length, until the audio says otherwise. */
  duration?: number;
  /** Called with the current position when someone copies a link at it. */
  onCopyLink: (position: number) => void;
};

export const Player = forwardRef<PlayerHandle, Props>(function Player(
  { src, type, title, show, artwork, startAt, duration: feedDuration, onCopyLink },
  ref,
) {
  const audio = useRef<HTMLAudioElement>(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(startAt ?? 0);
  const [duration, setDuration] = useState(feedDuration ?? 0);
  const [speed, setSpeed] = useState(1);
  const [waiting, setWaiting] = useState(false);
  const [failed, setFailed] = useState(false);
  const [dragging, setDragging] = useState<number | null>(null);
  const pendingStart = useRef<number | null>(startAt);

  const seek = useCallback((seconds: number, play = false) => {
    const el = audio.current;
    if (!el) return;
    const to = Math.max(0, Math.min(seconds, el.duration || duration || seconds));
    if (el.readyState >= 1) el.currentTime = to;
    else pendingStart.current = to;
    setPosition(to);
    if (play) void el.play().catch(() => {});
  }, [duration]);

  useImperativeHandle(ref, () => ({ seek, position: () => audio.current?.currentTime ?? position }), [seek, position]);

  useEffect(() => {
    const el = audio.current;
    if (!el) return;
    const onMeta = () => {
      if (Number.isFinite(el.duration) && el.duration > 0) setDuration(el.duration);
      if (pendingStart.current !== null) {
        el.currentTime = pendingStart.current;
        pendingStart.current = null;
      }
    };
    const onTime = () => setPosition(el.currentTime);
    const onPlay = () => setPlaying(true);
    const onPause = () => setPlaying(false);
    const onWaiting = () => setWaiting(true);
    const onPlaying = () => setWaiting(false);
    const onError = () => setFailed(true);
    el.addEventListener("loadedmetadata", onMeta);
    el.addEventListener("timeupdate", onTime);
    el.addEventListener("play", onPlay);
    el.addEventListener("pause", onPause);
    el.addEventListener("waiting", onWaiting);
    el.addEventListener("playing", onPlaying);
    el.addEventListener("error", onError);
    return () => {
      el.removeEventListener("loadedmetadata", onMeta);
      el.removeEventListener("timeupdate", onTime);
      el.removeEventListener("play", onPlay);
      el.removeEventListener("pause", onPause);
      el.removeEventListener("waiting", onWaiting);
      el.removeEventListener("playing", onPlaying);
      el.removeEventListener("error", onError);
    };
  }, []);

  // Lock screen and headphone controls.
  useEffect(() => {
    if (!("mediaSession" in navigator)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title,
      artist: show,
      album: show,
      artwork: artwork ? [{ src: artwork, sizes: "600x600" }] : [],
    });
    const el = audio.current;
    navigator.mediaSession.setActionHandler("seekbackward", () => el && seek(el.currentTime - SKIP_BACK));
    navigator.mediaSession.setActionHandler("seekforward", () => el && seek(el.currentTime + SKIP_FORWARD));
    navigator.mediaSession.setActionHandler("seekto", (d) => d.seekTime !== undefined && seek(d.seekTime));
  }, [title, show, artwork, seek]);

  const toggle = () => {
    const el = audio.current;
    if (!el) return;
    setFailed(false);
    if (el.paused) void el.play().catch(() => setFailed(true));
    else el.pause();
  };

  const cycleSpeed = () => {
    const next = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length]!;
    setSpeed(next);
    if (audio.current) audio.current.playbackRate = next;
  };

  const shown = dragging ?? position;
  const total = duration || 0;
  const pct = total > 0 ? Math.min(100, (shown / total) * 100) : 0;

  return (
    <section className="player" aria-label="Player">
      <audio ref={audio} preload="metadata">
        <source src={src} type={type} />
      </audio>
      <div className="scrub">
        <input
          type="range"
          className="track"
          min={0}
          max={Math.max(total, 1)}
          step={1}
          value={Math.min(shown, Math.max(total, 1))}
          style={{ "--p": `${pct}%` } as React.CSSProperties}
          aria-label="Position"
          aria-valuetext={`${clock(shown)} of ${clock(total)}`}
          onChange={(e) => setDragging(Number(e.target.value))}
          onPointerUp={() => { if (dragging !== null) { seek(dragging); setDragging(null); } }}
          onKeyUp={() => { if (dragging !== null) { seek(dragging); setDragging(null); } }}
          onBlur={() => { if (dragging !== null) { seek(dragging); setDragging(null); } }}
        />
        <div className="times">
          <span>{clock(shown)}</span>
          <b>{failed ? "Couldn't play this one" : waiting && playing ? "Loading…" : speed !== 1 ? `${speed}×` : ""}</b>
          <span>{total > 0 ? `-${clock(Math.max(0, total - shown))}` : ""}</span>
        </div>
      </div>
      <div className="transport">
        <button className="skip" onClick={() => seek(shown - SKIP_BACK)} aria-label={`Back ${SKIP_BACK} seconds`}>
          <BackIcon /><em>{SKIP_BACK}</em>
        </button>
        <button className="bigplay" onClick={toggle} aria-label={playing ? "Pause" : "Play"}>
          {playing ? <PauseIcon /> : <PlayIcon />}
        </button>
        <button className="skip" onClick={() => seek(shown + SKIP_FORWARD)} aria-label={`Forward ${SKIP_FORWARD} seconds`}>
          <ForwardIcon /><em>{SKIP_FORWARD}</em>
        </button>
      </div>
      <div className="utils">
        <button className="util" onClick={cycleSpeed} aria-label={`Speed ${speed}×`}>
          <span className="ic speed">{speed}×</span>
          Speed
        </button>
        <button className="util" onClick={() => onCopyLink(audio.current?.currentTime ?? shown)}>
          <span className="ic"><LinkIcon /></span>
          Link at {clock(shown)}
        </button>
      </div>
    </section>
  );
});
