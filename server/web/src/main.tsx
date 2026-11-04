import React from "react";
import ReactDOM from "react-dom/client";
import { reportFrontendError } from "./diagnostics";
import App from "./App";
import "./styles.css";

window.addEventListener("error", event => {
  reportFrontendError({
    kind: "window-error",
    message: event.message || String(event.error ?? "Unknown window error"),
    source: event.filename,
    line: event.lineno || undefined,
    column: event.colno || undefined,
    stack: event.error instanceof Error ? event.error.stack : undefined,
  });
});

window.addEventListener("unhandledrejection", event => {
  const reason = event.reason;
  reportFrontendError({
    kind: "unhandled-rejection",
    message: reason instanceof Error ? reason.message : String(reason ?? "Unknown rejection"),
    source: window.location.href,
    stack: reason instanceof Error ? reason.stack : undefined,
  });
});

ReactDOM.createRoot(document.getElementById("root")!).render(<React.StrictMode><App /></React.StrictMode>);
