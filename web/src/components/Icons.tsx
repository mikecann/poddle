// Line icons in the design's style (24px grid, round caps).

type P = { className?: string };
const base = { viewBox: "0 0 24 24", "aria-hidden": true } as const;

export const PlayIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.2-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5Z" fill="currentColor" stroke="none" /></svg>
);
export const PauseIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><rect x="6.5" y="5" width="4" height="14" rx="1.3" fill="currentColor" stroke="none" /><rect x="13.5" y="5" width="4" height="14" rx="1.3" fill="currentColor" stroke="none" /></svg>
);
export const BackIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3" /><path d="M4.5 4.5v3.7h3.7" /></svg>
);
export const ForwardIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3" /><path d="M19.5 4.5v3.7h-3.7" /></svg>
);
export const LinkIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><path d="M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1 1" /><path d="M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1-1" /></svg>
);
export const AppIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><path d="M14 4h6v6" /><path d="M20 4l-8.5 8.5" /><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4" /></svg>
);
export const LockIcon = ({ className = "i" }: P) => (
  <svg {...base} className={className}><rect x="5" y="11" width="14" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>
);
export const AppleLogo = ({ className = "i" }: P) => (
  <svg viewBox="0 0 24 24" aria-hidden className={className}><path fill="currentColor" stroke="none" d="M16.37 12.6c-.02-2.2 1.8-3.26 1.88-3.31-1.03-1.5-2.62-1.7-3.18-1.73-1.35-.14-2.65.8-3.33.8-.7 0-1.75-.78-2.88-.76-1.48.02-2.85.86-3.61 2.19-1.55 2.68-.4 6.63 1.1 8.8.74 1.06 1.61 2.25 2.75 2.2 1.11-.04 1.52-.71 2.86-.71 1.33 0 1.71.71 2.87.69 1.19-.02 1.94-1.07 2.66-2.14.85-1.23 1.19-2.43 1.21-2.49-.03-.01-2.31-.89-2.33-3.54ZM14.2 6.17c.6-.74 1.01-1.75.9-2.77-.87.04-1.94.59-2.56 1.32-.56.64-1.05 1.69-.92 2.68.97.08 1.97-.49 2.58-1.23Z" /></svg>
);
export const GoogleLogo = ({ className = "i" }: P) => (
  <svg viewBox="0 0 24 24" aria-hidden className={className}>
    <path fill="#4285F4" d="M21.6 12.23c0-.68-.06-1.36-.18-2.02H12v3.83h5.4a4.6 4.6 0 0 1-2 3.02v2.5h3.23c1.9-1.75 2.97-4.32 2.97-7.33Z" />
    <path fill="#34A853" d="M12 22c2.7 0 4.97-.9 6.63-2.43l-3.23-2.5c-.9.6-2.05.95-3.4.95-2.6 0-4.81-1.76-5.6-4.12H3.07v2.58A10 10 0 0 0 12 22Z" />
    <path fill="#FBBC04" d="M6.4 13.9a6 6 0 0 1 0-3.8V7.52H3.07a10 10 0 0 0 0 8.96L6.4 13.9Z" />
    <path fill="#EA4335" d="M12 5.98c1.47-.02 2.88.53 3.95 1.54l2.86-2.86A9.6 9.6 0 0 0 12 2a10 10 0 0 0-8.93 5.52L6.4 10.1C7.19 7.74 9.4 5.98 12 5.98Z" />
  </svg>
);
