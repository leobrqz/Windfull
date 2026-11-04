import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import windfullMark from "../../../app/assets/brand/windfull-mark.svg";
import type { AvailableUpdate, HostViewState, UpdateContext } from "./types";

type Tab = "controls" | "appliance" | "phones" | "network" | "energy" | "automation" | "updates";
const tabs: { id: Tab; label: string }[] = [
  { id: "appliance", label: "Aparelho" }, { id: "phones", label: "Celulares" },
  { id: "network", label: "Rede" }, { id: "energy", label: "Energia" },
  { id: "automation", label: "Timer" }, { id: "updates", label: "Atualizações" },
];
const command = <T,>(name: string, args?: Record<string, unknown>) => invoke<T>(name, args);
const show = (value: number | null | undefined, digits = 0) => value == null || !Number.isFinite(value) ? "—" : value.toFixed(digits);
const date = (value?: string | null) => value ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "—";
const modeName = (v: string) => ({ auto: "Auto", cool: "Resfriar", heat: "Aquecer", dry: "Seco", fan: "Ventilar", wind: "Ventilar", purify: "Purificar" }[v.toLowerCase()] ?? v.replaceAll("_", " "));
const featureGlyph = (id: string) => String.fromCodePoint(({ windfree: 0x2248, swing: 0x2195, vertical_swing: 0x2195, horizontal_swing: 0x2194, sleep: 0x263e, display: 0x25c9, beep: 0x266b, auto_clean: 0x2727 } as Record<string, number>)[id.toLowerCase()] ?? 0x2726);

export default function App() {
  const [host, setHost] = useState<HostViewState | null>(null);
  const [tab, setTab] = useState<Tab>("controls");
  const [settings, setSettings] = useState(false);
  const [actionError, setActionError] = useState("");
  const [actionBusy, setActionBusy] = useState("");
  const [ip, setIp] = useState("");
  const [deviceName, setDeviceName] = useState("");
  const [draftTemperature, setDraftTemperature] = useState<number | null>(null);
  const [price, setPrice] = useState("");
  const [confirmPair, setConfirmPair] = useState<string | null>(null);
  const [typedCode, setTypedCode] = useState("");
  const [updateContext, setUpdateContext] = useState<UpdateContext | null>(null);
  const [update, setUpdate] = useState<AvailableUpdate | null>(null);
  const [updateStatus, setUpdateStatus] = useState("Preparando atualizações");
  const [updatePercent, setUpdatePercent] = useState(0);
  const [updateDownloaded, setUpdateDownloaded] = useState(false);
  const [updateError, setUpdateError] = useState("");
  const [hostAlert, setHostAlert] = useState<{ type: string; title: string; message: string; createdAt: string } | null>(null);

  const refresh = useCallback(async () => {
    const state = await command<HostViewState>("get_host_state");
    setHost(state);
  }, []);
  const run = useCallback(async (name: string, args?: Record<string, unknown>) => {
    setActionError(""); setActionBusy(name);
    try { await command(name, args); await refresh(); }
    catch (e) { setActionError(String(e)); }
    finally { setActionBusy(""); }
  }, [refresh]);
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let unlistenAlert: (() => void) | undefined;
    void (async () => {
      try { await refresh(); }
      catch (e) { setActionError(`Não foi possível carregar o estado do host: ${String(e)}`); }
      try { unlisten = await listen<HostViewState>("host-state-changed", event => setHost(event.payload)); }
      catch (e) { setActionError(`Não foi possível assinar eventos do host: ${String(e)}`); }
      try { unlistenAlert = await listen<{ type: string; title: string; message: string; createdAt: string }>("host-alert", event => setHostAlert(event.payload)); }
      catch (e) { setActionError(`Não foi possível assinar alertas do host: ${String(e)}`); }
    })();
    return () => { unlisten?.(); unlistenAlert?.(); };
  }, [refresh]);
  useEffect(() => {
    void (async () => {
      try {
        const ctx = await command<UpdateContext>("get_update_context"); setUpdateContext(ctx);
        if (!ctx.managed) { setUpdateStatus("Instalação portátil"); return; }
        setUpdateStatus("Verificando versões");
        const next = await command<AvailableUpdate | null>("check_for_updates");
        setUpdate(next); setUpdateStatus(next ? "Atualização disponível" : "WindFull atualizado");
      } catch (e) { setUpdateStatus("Verificação interrompida"); setUpdateError(String(e)); }
    })();
    let stop: (() => void) | undefined;
    void listen<{ percent?: number; error?: string }>("update-progress", e => {
      if (typeof e.payload.percent === "number") { setUpdatePercent(e.payload.percent); setUpdateStatus("Baixando pacote"); }
      if (e.payload.error) { setUpdateError(e.payload.error); setUpdateStatus("Atualização interrompida"); }
    }).then(x => { stop = x; }).catch(e => setUpdateError(String(e)));
    return () => stop?.();
  }, []);
  useEffect(() => { if (host?.energyUsage) setPrice(String(host.energyUsage.pricePerKWh)); }, [host?.energyUsage.pricePerKWh]);

  const appliance = host?.appliance ?? null;
  const connected = host?.applianceConnection === "connected" && appliance !== null;
  const powered = appliance?.isPoweredOn === true;
  const busy = (key: string) => Boolean(host?.busyActions.includes(key)) || actionBusy === key || actionBusy === ({ power: "set_power", temperature: "set_target_temperature", mode: "set_operating_mode", fanSpeed: "set_fan_speed", windFree: "set_feature" } as Record<string, string>)[key];
  const openSettings = (next: Tab) => { setTab(next); setSettings(true); };
  const modes = appliance?.supportedModes ?? [];
  const fanSpeeds = appliance?.fanSpeeds ?? [];
  const features = useMemo(() => Object.entries(appliance?.features ?? {}), [appliance?.features]);
  const tempAvailable = connected && appliance?.targetTemperature != null && appliance.minimumTemperature != null && appliance.maximumTemperature != null && appliance.temperatureStep != null && appliance.temperatureStep > 0 && !["fan", "wind", "purify", "purifier"].includes((appliance.mode ?? "").toLowerCase());

  const updateAction = async (name: string) => {
    setUpdateError("");
    try {
      if (name === "check_for_updates") {
        setUpdateStatus("Verificando versões"); setUpdateDownloaded(false); const next = await command<AvailableUpdate | null>(name);
        setUpdate(next); setUpdateStatus(next ? "Atualização disponível" : "WindFull atualizado");
      } else if (name === "download_update") {
        setUpdateStatus("Baixando pacote"); setUpdatePercent(0); await command(name); setUpdateDownloaded(true); setUpdateStatus("Pronto para instalar");
      } else if (name === "apply_update") { setUpdateStatus("Instalando e reiniciando"); await command(name); }
      else { await command(name); }
    } catch (e) { setUpdateStatus("Atualização interrompida"); setUpdateError(String(e)); }
  };

  return <main className="panel">
    <header className="topbar">
      <button className="brand" onClick={() => { setSettings(false); setTab("controls"); }} aria-label="Voltar aos controles">
        <img className="brand-mark" src={windfullMark} alt="" />
        <span><strong>WindFull</strong><small>Controle local</small></span>
      </button>
      <div className="top-actions">
        {host?.status === "error" && <button className="icon-btn" title="Tentar iniciar servidor" onClick={() => void run("retry_server")}>&#x21bb;</button>}
        <button className={`icon-btn ${settings ? "selected" : ""}`} title="Ajustes" onClick={() => settings ? setSettings(false) : openSettings("appliance")}>{String.fromCodePoint(settings ? 0x2039 : 0x2699)}</button>
        <button className="icon-btn" title="Minimizar painel" onClick={() => void getCurrentWindow().hide().catch(e => setActionError(String(e)))}>-</button>
      </div>
    </header>
    {actionError && <div className="error-strip"><span>!</span><span>{actionError}</span><button onClick={() => setActionError("")}>×</button></div>}
    {hostAlert && <div className="alert-strip"><b>{hostAlert.title}</b><span>{hostAlert.message}</span><button onClick={() => setHostAlert(null)}>×</button></div>}
    {!settings ? <section className="scroll-area controls-view">
      {host?.status === "error" && <div className="notice"><b>Servidor local parado</b><span>{host.serverError || "O host não iniciou."}</span><button onClick={() => void run("retry_server")}>Tentar de novo</button></div>}
      {host?.applianceError && <div className="notice subtle"><b>Conexão com o aparelho</b><span>{host.applianceError}</span><button onClick={() => openSettings("appliance")}>Configurar</button></div>}
      <div className="device-row">
        <div className="device-titles"><strong>{appliance?.name ?? "Ar-condicionado"}</strong><small>{connected ? appliance?.host : host ? connectionLabel(host.applianceConnection) : "Conectando ao host…"}</small></div>
        {appliance?.isPoweredOn != null && <button className={`power ${powered ? "on" : ""}`} disabled={!connected || busy("power")} title={powered ? "Desligar" : "Ligar"} onClick={() => void run("set_power", { enabled: !powered })}><span>&#x23fb;</span></button>}
      </div>
      <div className={`climate-scene ${powered ? "active" : ""}`}>
        <svg className="air-unit" viewBox="0 0 320 112" role="img" aria-label="Ilustração do ar-condicionado">
          <defs>
            <linearGradient id="unit-face" x1="0" y1="0" x2="0.9" y2="1"><stop stopColor="#f2f3f4"/><stop offset=".48" stopColor="#d9dbde"/><stop offset="1" stopColor="#aeb2b7"/></linearGradient>
            <linearGradient id="unit-vent" x1="0" y1="0" x2="0" y2="1"><stop stopColor="#858a90"/><stop offset="1" stopColor="#45494f"/></linearGradient>
            <filter id="unit-shadow" x="-15%" y="-30%" width="130%" height="190%"><feDropShadow dx="0" dy="9" stdDeviation="7" floodColor="#000" floodOpacity=".34"/></filter>
          </defs>
          <g filter="url(#unit-shadow)">
            <path d="M30 34 Q32 20 48 18 L272 18 Q288 20 290 34 L284 72 Q282 82 269 84 L51 84 Q38 82 36 72Z" fill="url(#unit-face)"/>
            <path d="M51 26 Q160 22 269 26" fill="none" stroke="#fff" strokeOpacity=".72" strokeWidth="2"/>
            <path d="M42 68 Q160 76 278 68 L272 79 Q160 87 49 79Z" fill="url(#unit-vent)"/>
            <path d="M55 74 Q160 81 265 74" fill="none" stroke="#dfe1e4" strokeOpacity=".62" strokeWidth="1.5"/>
            <circle cx="268" cy="42" r="2" fill={powered ? "#f3f5f7" : "#8c9095"}/>
          </g>
        </svg>
        <div className="scene-readout"><span><small>Ambiente</small><b>{show(appliance?.roomTemperature, 1)}°</b></span><i/><span><small>Umidade</small><b>{show(appliance?.humidity)}%</b></span></div>
      </div>
      <div className="temperature-row">
        <div><span className="eyebrow">Temperatura</span><div className="temp-number">{show(appliance?.targetTemperature, appliance?.targetTemperature != null && appliance.targetTemperature % 1 !== 0 ? 1 : 0)}<sup>°</sup></div></div>
        {appliance?.features.windFree && <button className={`windfree ${appliance.features.windFree.enabled ? "active" : ""}`} role="switch" aria-checked={appliance.features.windFree.enabled} disabled={!connected || !powered || busy("windFree")} onClick={() => void run("set_feature", { featureId: "windFree", enabled: !appliance.features.windFree!.enabled })}><span className="wind-glyph">≈</span><b>WindFree</b><i className="toggle-track"><i /></i></button>}
      </div>
      {tempAvailable && appliance && <div className="temp-adjust">
        <button className="round-btn" disabled={!powered || busy("temperature") || appliance.targetTemperature! - appliance.temperatureStep! < appliance.minimumTemperature!} onClick={() => void run("set_target_temperature", { temperature: appliance.targetTemperature! - appliance.temperatureStep! })}>-</button>
        <input aria-label="Temperatura alvo" type="range" min={appliance.minimumTemperature!} max={appliance.maximumTemperature!} step={appliance.temperatureStep!} value={Math.min(appliance.maximumTemperature!, Math.max(appliance.minimumTemperature!, draftTemperature ?? appliance.targetTemperature!))} disabled={!powered || busy("temperature")} onChange={e => setDraftTemperature(Number(e.target.value))} onPointerUp={e => { const temperature = Number(e.currentTarget.value); setDraftTemperature(null); void run("set_target_temperature", { temperature }); }} onKeyUp={e => { if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(e.key)) { const temperature = Number(e.currentTarget.value); setDraftTemperature(null); void run("set_target_temperature", { temperature }); } }} style={{ "--range-progress": `${(((draftTemperature ?? appliance.targetTemperature!) - appliance.minimumTemperature!) / (appliance.maximumTemperature! - appliance.minimumTemperature!)) * 100}%` } as React.CSSProperties} />
        <button className="round-btn" disabled={!powered || busy("temperature") || appliance.targetTemperature! + appliance.temperatureStep! > appliance.maximumTemperature!} onClick={() => void run("set_target_temperature", { temperature: appliance.targetTemperature! + appliance.temperatureStep! })}>+</button>
      </div>}
      <div className="quick-controls">
        {modes.length > 0 && <div className="control-select"><span className="eyebrow">Modo</span><select aria-label="Modo de operação" value={appliance?.mode ?? ""} disabled={!connected || !powered || busy("mode")} onChange={e => void run("set_operating_mode", { mode: e.target.value })}><option value="" disabled>Desconhecido</option>{modes.map(m => <option key={m} value={m}>{modeName(m)}</option>)}</select></div>}
        {fanSpeeds.length > 0 && <div className="control-select"><span className="eyebrow">Ventilação</span><select aria-label="Velocidade do ventilador" value={appliance?.fanSpeed ?? ""} disabled={!connected || !powered || busy("fanSpeed")} onChange={e => void run("set_fan_speed", { speed: e.target.value })}><option value="" disabled>Desconhecida</option>{fanSpeeds.map(s => <option key={s} value={s}>{modeName(s)}</option>)}</select></div>}
      </div>
      {features.filter(([id]) => id.toLowerCase() !== "windfree").length > 0 && <div className="feature-wrap"><span className="eyebrow">Recursos</span><div className="feature-list">{features.filter(([id]) => id.toLowerCase() !== "windfree").map(([id, f]) => <button key={id} className={`feature ${f.enabled ? "on" : ""}`} disabled={!connected || !powered || busy(`feature.${id}`)} onClick={() => void run("set_feature", { featureId: id, enabled: !f.enabled })}><span>{featureGlyph(id)}</span>{f.label}</button>)}</div></div>}
      <div className="bottom-strip"><span>{connected ? "Conectado" : "Aparelho não conectado"}</span><button onClick={() => openSettings("energy")}>Hoje <b>{host?.energyUsage.hasBaseline ? `${show(host.energyUsage.todayKWh, 1)} kWh` : "— kWh"}</b></button></div>
      {!appliance && <div className="empty-link"><span>Conecte seu aparelho para começar</span><button onClick={() => openSettings("appliance")}>Configurar</button></div>}
    </section> : <section className="settings-view">
      <div className="settings-head"><h2>Ajustes</h2></div>
      <nav className="settings-nav" aria-label="Seções de ajustes">{tabs.map(t => <button key={t.id} className={tab === t.id ? "active" : ""} onClick={() => setTab(t.id)}>{t.label}</button>)}</nav>
      <div className="scroll-area settings-content">
        {tab === "appliance" && <>
          <SectionTitle title="Aparelho" action={<button className="text-action" disabled={host?.isDiscovering} onClick={() => void run("discover_appliances")}>{host?.isDiscovering ? "Buscando…" : "⌕ Buscar na rede"}</button>} />
          <div className="current-device"><div><b>{appliance?.name ?? "Nenhum aparelho conectado"}</b><small>{appliance?.host ?? host?.applianceError ?? "Busque na rede ou informe um IP."}</small></div><span className="device-status">{connected ? "Conectado" : "Desconectado"}</span></div>
          {host?.discoveryError && <p className="muted-line">{host.discoveryError}</p>}
          {host?.discoveredAppliances.map(d => <div className="list-row" key={d.id}><span className="mini-icon">&#x2301;</span><div className="row-main"><b>{d.name}</b><small>{d.host} · {d.isReachable == null ? "alcance desconhecido" : d.isReachable ? "alcançável" : "sem resposta"}</small></div><button disabled={busy("appliance.connect")} onClick={() => void run("select_appliance", { applianceId: d.id })}>Usar</button></div>)}
          {host?.hasSearchedForAppliances && host.discoveredAppliances.length === 0 && !host.isDiscovering && <p className="muted-line">Nenhum aparelho respondeu nesta busca.</p>}
          <SectionTitle title="Configurar por endereço" />
          <form className="form-stack" onSubmit={e => { e.preventDefault(); void run("configure_appliance_manually", { host: ip.trim(), ...(deviceName.trim() ? { name: deviceName.trim() } : {}) }); }}><label>IP local<input placeholder="192.168.1.50" value={ip} onChange={e => setIp(e.target.value)} required /></label><label>Nome opcional<input placeholder="Sala" value={deviceName} onChange={e => setDeviceName(e.target.value)} /></label><button className="primary-btn" disabled={!ip.trim() || Boolean(actionBusy)}>Conectar aparelho <span>&rarr;</span></button></form>
        </>}
        {tab === "phones" && <>
          <SectionTitle title={`Pedidos pendentes · ${host?.pendingPairings.length ?? "—"}`} />
          {host?.pendingPairings.length ? host.pendingPairings.map(r => <div className="pair-card" key={r.id}><div className="pair-heading"><div><b>{r.deviceName}</b><small>{r.deviceDescription ?? "Novo dispositivo Android"}</small></div><em>Aguardando</em></div><p>Compare este código com o exibido no celular antes de aprovar.</p><div className="verify-code">{r.verificationCode}</div><small className="expires">Expira em {date(r.expiresAt)}</small>{confirmPair === r.id ? <div className="confirm-inline"><label>Digite o código para confirmar<input inputMode="numeric" maxLength={6} value={typedCode} onChange={e => setTypedCode(e.target.value.replace(/\D/g, ""))} placeholder="000000" /></label><button className="primary-btn" disabled={typedCode !== r.verificationCode || Boolean(actionBusy)} onClick={() => { void run("approve_pairing_request", { requestId: r.id }); setConfirmPair(null); setTypedCode(""); }}>Os códigos conferem</button><button className="text-action" onClick={() => setConfirmPair(null)}>Cancelar</button></div> : <div className="pair-actions"><button className="quiet-btn" onClick={() => void run("reject_pairing_request", { requestId: r.id })}>Recusar</button><button className="primary-btn" onClick={() => setConfirmPair(r.id)}>Conferir e aprovar</button></div>}</div>) : <EmptyState title="Nenhum pedido agora" detail="Quando um celular solicitar acesso, ele aparecerá aqui para sua aprovação." />}
          <SectionTitle title={`Celulares autorizados · ${host?.pairedDevices.length ?? "—"}`} />
          {host?.pairedDevices.length ? host.pairedDevices.map(d => <div className="list-row paired" key={d.id}><div className="row-main"><b>{d.name}</b><small>Pareado em {date(d.pairedAt)} · visto {date(d.lastSeenAt)}</small></div><button className="danger-action" disabled={busy(`revoke.${d.id}`)} onClick={() => { if (confirm(`Revogar o acesso de ${d.name}?`)) void run("revoke_paired_device", { deviceId: d.id }); }}>Revogar</button></div>) : <EmptyState title="Nenhum celular autorizado" detail="A aprovação acontece sempre neste computador." />}
        </>}
        {tab === "network" && <>
          <SectionTitle title="Servidor local" action={host?.status === "error" ? <button className="text-action" onClick={() => void run("retry_server")}>&#x21bb; Tentar novamente</button> : undefined} />
          <div className="network-hero"><div><b>{statusName(host?.status)}</b><small>{host?.serverError ?? "A comunicação com o Android acontece pela rede local."}</small></div></div>
          <div className="data-table"><DataRow label="Endereço(s)" value={host?.localAddresses.length ? host.localAddresses.join(" · ") : "Indisponível"} /><DataRow label="Porta" value={host?.serverPort ?? "—"} /><DataRow label="Identidade TLS" value={host?.certificateFingerprint ?? "Indisponível"} copy /></div>
          <div className="info-note">A identidade do servidor e os pareamentos devem permanecer consistentes entre atualizações. O Android precisa estar na mesma rede.</div>
          <SectionTitle title="Inicialização" />
          <div className="startup-row"><div><b>Iniciar com o Windows</b><small>Abre o WindFull ao entrar na sua conta.</small></div><button className={`switch ${host?.startWithWindows ? "checked" : ""}`} role="switch" aria-checked={host?.startWithWindows ?? false} disabled={!host || actionBusy === "set_start_with_windows"} onClick={() => void run("set_start_with_windows", { enabled: !host?.startWithWindows })}><i /></button></div>
        </>}
        {tab === "energy" && host && <>
          <SectionTitle title="Consumo medido" />
          <div className="energy-top"><div><span className="eyebrow">Hoje</span><strong>{host.energyUsage.hasBaseline ? show(host.energyUsage.todayKWh, 2) : "—"}<small> kWh</small></strong></div><div className="energy-estimate"><span className="eyebrow">Estimativa mensal</span><b>{host.energyUsage.hasBaseline ? `R$ ${show(host.energyUsage.monthlyEstimate, 2)}` : "—"}</b></div></div>
          {host.energyUsage.hasBaseline && host.energyUsage.hourlyKWh.length ? <div className="chart"><div className="chart-label"><span>Consumo por hora</span><small>kWh · hoje</small></div><div className="bars">{host.energyUsage.hourlyKWh.map((v, i) => <div className="bar-column" key={i}><span title={`${show(v, 2)} kWh`} style={{ height: `${Math.max(3, (v / Math.max(...host.energyUsage.hourlyKWh, 0.01)) * 100)}%` }} /><small>{i % 4 === 0 ? `${String(i).padStart(2, "0")}h` : ""}</small></div>)}</div></div> : <EmptyState title="Sem histórico horário" detail="O gráfico aparece quando o host fornecer amostras de consumo." />}
          <SectionTitle title="Tarifa de energia" />
          <form className="price-form" onSubmit={e => { e.preventDefault(); const n = Number(price.replace(",", ".")); if (Number.isFinite(n) && n > 0 && n < 100) void run("set_energy_price_per_kwh", { price: n }); }}><label>Preço por kWh<input inputMode="decimal" value={price} onChange={e => setPrice(e.target.value)} /></label><span>R$ / kWh</span><button className="small-save" disabled={!price || Boolean(actionBusy)}>Salvar</button></form>
          <p className="muted-line">Última amostra: {date(host.energyUsage.lastSampleAt)} · Medidor: {host.energyUsage.meterKWh == null ? "—" : `${show(host.energyUsage.meterKWh, 2)} kWh`}</p>
        </>}
        {tab === "automation" && host && <>
          <SectionTitle title="Desligar automaticamente" />
          <div className="timer-setting"><div><b>{host.offTimerEndsAt ? "Timer ativo" : "Desligamento programado"}</b><small>{host.offTimerEndsAt ? `Desliga em ${timeLeft(host.offTimerEndsAt)}` : "O cronômetro segue ativo com o painel fechado."}</small></div><select aria-label="Desligamento automático" value={timerSelection(host.offTimerEndsAt)} disabled={Boolean(actionBusy)} onChange={e => void run("set_off_timer", { hours: Number(e.target.value) })}><option value="0">Nunca</option><option value="1">1 hora</option><option value="2">2 horas</option><option value="4">4 horas</option><option value="8">8 horas</option></select></div>
          <SectionTitle title="Lembrete de limpeza" />
          <div className="filter-card"><div className="filter-dial"><b>{show(host.filterRuntimeHours)}</b><small>h</small></div><div className="filter-copy"><b>{host.filterReminderDue ? "Filtro precisa de limpeza" : "Uso acumulado do aparelho"}</b><small>Lembrete por {host.filterReminderIntervalHours} horas de funcionamento. O aparelho não expõe sensor de filtro.</small></div></div>
          {host.filterReminderDue && <button className="quiet-btn full" disabled={Boolean(actionBusy)} onClick={() => void run("reset_filter_reminder")}>Filtro limpo · reiniciar contagem</button>}
          {!host.filterReminderDue && <button className="text-action reset-filter" disabled={Boolean(actionBusy)} onClick={() => void run("reset_filter_reminder")}>Marcar filtro limpo e zerar uso acumulado</button>}
          <SectionTitle title="Alertas do aparelho" />
          <div className="startup-row"><div><b>Avisar se o ar ficar offline</b><small>Notificação do Windows enquanto o WindFull está na bandeja.</small></div><button className={`switch ${host.alertsEnabled ? "checked" : ""}`} role="switch" aria-checked={host.alertsEnabled} disabled={Boolean(actionBusy)} onClick={() => void run("set_alerts_enabled", { enabled: !host.alertsEnabled })}><i /></button></div>
        </>}
        {tab === "updates" && <>
          <SectionTitle title="Atualizações do WindFull" action={<button className="text-action" disabled={updateStatus === "Verificando versões"} onClick={() => void updateAction("check_for_updates")}>&#x21bb; Verificar</button>} />
          <div className="update-card"><span className="update-emblem">&#x21bb;</span><div><b>{updateStatus}</b><small>Versão instalada {updateContext?.currentVersion ?? "—"} · {updateContext?.channel ?? "canal —"}</small></div></div>
          {updatePercent > 0 && updateStatus === "Baixando pacote" && <div className="progress-track"><i style={{ width: `${updatePercent}%` }} /></div>}
          {updateError && <div className="inline-error">{updateError}</div>}
          {update && <div className="release-notes"><span className="eyebrow">Versão {update.version}</span><p>{update.notes || "Sem notas para esta versão."}</p></div>}
          {updateContext?.managed ? updateDownloaded ? <button className="primary-btn full" disabled={actionBusy !== ""} onClick={() => void updateAction("apply_update")}>Instalar e reiniciar <span>↻</span></button> : update ? <button className="primary-btn full" disabled={actionBusy !== "" || updateStatus === "Baixando pacote"} onClick={() => void updateAction("download_update")}>Baixar atualização <span>↓</span></button> : <button className="quiet-btn full" disabled={updateStatus === "Verificando versões"} onClick={() => void updateAction("check_for_updates")}>Verificar atualizações</button> : updateContext && <><div className="info-note">Esta instalação não oferece atualização automática. Use o pacote oficial para manter seus dados locais.</div><button className="quiet-btn full" onClick={() => void updateAction("open_release_page")}>Abrir pacote oficial ↗</button></>}
        </>}
      </div>
    </section>}
    <footer className="panel-footer">{host?.status === "ready" ? "Servidor ativo" : statusName(host?.status)}</footer>
  </main>;
}
function connectionLabel(value: HostViewState["applianceConnection"]) { return ({ unknown: "Nenhum aparelho selecionado", connected: "Conectado", disconnected: "Desconectado", error: "Conexão indisponível" })[value]; }
function statusName(value?: HostViewState["status"]) { return ({ ready: "Servidor ativo", starting: "Iniciando servidor", error: "Servidor indisponível", stopped: "Servidor parado" } as Record<string, string>)[value ?? ""] ?? "Estado desconhecido"; }
function timerSelection(end?: string | null) { if (!end) return "0"; const hours = Math.max(0, (new Date(end).getTime() - Date.now()) / 3_600_000); return String([1, 2, 4, 8].reduce((closest, value) => Math.abs(value - hours) < Math.abs(closest - hours) ? value : closest, 1)); }
function timeLeft(end: string) { const minutes = Math.max(0, Math.ceil((new Date(end).getTime() - Date.now()) / 60_000)); return minutes >= 60 ? `${Math.floor(minutes / 60)} h ${minutes % 60} min` : `${minutes} min`; }
function SectionTitle({ title, action }: { title: string; action?: React.ReactNode }) { return <div className="section-title"><h3>{title}</h3>{action}</div>; }
function EmptyState({ title, detail }: { title: string; detail: string }) { return <div className="empty-state"><b>{title}</b><p>{detail}</p></div>; }
function DataRow({ label, value, copy }: { label: string; value: string | number; copy?: boolean }) { const text = String(value); return <div className="data-row"><span>{label}</span><b title={text}>{text}</b>{copy && text !== "Indisponível" && text !== "—" && <button title="Copiar" onClick={() => void navigator.clipboard?.writeText(text).catch(() => undefined)}>&#x2398;</button>}</div>; }
