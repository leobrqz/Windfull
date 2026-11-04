import React, { Component } from "react";
import { reportFrontendError } from "./diagnostics";

interface Props {
  children: React.ReactNode;
  onOpenLogs: () => void;
}

interface State {
  error: Error | null;
}

export default class SectionErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    reportFrontendError({
      kind: "react-render",
      message: error.message || String(error),
      source: window.location.href,
      stack: `${error.stack ?? ""}\n${info.componentStack ?? ""}`,
    });
  }

  render() {
    if (this.state.error) {
      return (
        <div className="section-error" role="alert">
          <h3>Esta seção não carregou</h3>
          <p>O WindFull registrou o erro. Você pode abrir os logs ou escolher outra seção.</p>
          <button className="quiet-btn" onClick={() => this.setState({ error: null })}>Tentar novamente</button>
          <button className="text-action" onClick={this.props.onOpenLogs}>Abrir logs</button>
        </div>
      );
    }
    return this.props.children;
  }
}
