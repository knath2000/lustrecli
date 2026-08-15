"use client";

import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

export type Toast = {
  id: string;
  kind: "success" | "info" | "warning" | "error";
  title: string;
  message: string;
  duration?: number;
  action?: { label: string; run: () => void | Promise<void> };
};

export function ToastStack({ toasts, dismiss }: { toasts: Toast[]; dismiss: (id: string) => void }) {
  return <div className="toast-stack" role="region" aria-label="Notifications">
    <AnimatePresence initial={false}>
      {toasts.map((toast) => <ToastItem key={toast.id} toast={toast} dismiss={dismiss} />)}
    </AnimatePresence>
  </div>;
}

function ToastItem({ toast, dismiss }: { toast: Toast; dismiss: (id: string) => void }) {
  const reduced = useReducedMotion();
  const [paused, setPaused] = useState(false);
  const duration = toast.duration ?? 5_000;
  const remaining = useRef(duration);
  const startedAt = useRef(0);
  useEffect(() => {
    if (paused) return;
    startedAt.current = performance.now();
    const timer = window.setTimeout(() => dismiss(toast.id), remaining.current);
    return () => window.clearTimeout(timer);
  }, [dismiss, paused, toast.id]);
  function pause() {
    remaining.current = Math.max(0, remaining.current - (performance.now() - startedAt.current));
    setPaused(true);
  }
  return <motion.article
    className={`toast ${toast.kind}`}
    initial={reduced ? { opacity: 0 } : { opacity: 0, x: 42, scale: .96 }}
    animate={{ opacity: 1, x: 0, scale: 1 }}
    exit={reduced ? { opacity: 0 } : { opacity: 0, x: 34, scale: .97 }}
    transition={{ duration: reduced ? .12 : .26, ease: [0.22, 1, 0.36, 1] }}
    onMouseEnter={pause}
    onMouseLeave={() => setPaused(false)}
    onFocusCapture={pause}
    onBlurCapture={() => setPaused(false)}
    role={toast.kind === "error" ? "alert" : "status"}
    aria-live={toast.kind === "error" ? "assertive" : "polite"}
  >
    <span className="toast-symbol">{toast.kind === "success" ? "✓" : toast.kind === "error" ? "!" : toast.kind === "warning" ? "△" : "i"}</span>
    <div><strong>{toast.title}</strong><p>{toast.message}</p>{toast.action && <button onClick={async () => { await toast.action?.run(); dismiss(toast.id); }}>{toast.action.label}</button>}</div>
    <button className="toast-close" onClick={() => dismiss(toast.id)} aria-label="Dismiss notification">×</button>
    <span className="toast-timer" style={{ animationDuration: `${duration}ms`, animationPlayState: paused ? "paused" : "running" }} />
  </motion.article>;
}
