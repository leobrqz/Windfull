import { invoke } from "@tauri-apps/api/core";

export interface FrontendErrorReport {
  kind: string;
  message: string;
  source?: string;
  line?: number;
  column?: number;
  stack?: string;
}

export function reportFrontendError(report: FrontendErrorReport) {
  void invoke("report_frontend_error", {
    kind: report.kind,
    message: report.message,
    source: report.source,
    line: report.line,
    column: report.column,
    stack: report.stack,
  }).catch(() => undefined);
}
