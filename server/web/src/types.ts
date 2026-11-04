export type HostStatus = "starting" | "ready" | "error" | "stopped";
export type ApplianceConnectionStatus = "unknown" | "connected" | "disconnected" | "error";
export interface ApplianceFeatureState { label: string; enabled: boolean }
export interface ApplianceState {
  id: string; name: string; host: string; isPoweredOn?: boolean | null;
  targetTemperature?: number | null; roomTemperature?: number | null; humidity?: number | null;
  instantaneousPowerW?: number | null; cumulativeEnergyWh?: number | null;
  minimumTemperature?: number | null; maximumTemperature?: number | null; temperatureStep?: number | null;
  mode?: string | null; supportedModes: string[]; fanSpeed?: string | null; fanSpeeds: string[];
  features: Record<string, ApplianceFeatureState>;
}
export interface DiscoveredAppliance { id: string; name: string; host: string; isReachable?: boolean | null; isPoweredOn?: boolean | null; targetTemperature?: number | null; roomTemperature?: number | null }
export interface EnergyUsageState { todayKWh: number; hourlyKWh: number[]; pricePerKWh: number; monthlyEstimate: number; meterKWh?: number | null; lastSampleAt?: string | null; hasBaseline: boolean }
export interface PendingPairingRequest { id: string; deviceName: string; verificationCode: string; expiresAt: string; deviceDescription?: string | null }
export interface PairedDevice { id: string; name: string; pairedAt: string; description?: string | null; lastSeenAt?: string | null }
export interface HostViewState {
  status: HostStatus; serverError?: string | null; localAddresses: string[]; serverPort?: number | null; certificateFingerprint?: string | null;
  isDiscovering: boolean; hasSearchedForAppliances: boolean; discoveredAppliances: DiscoveredAppliance[]; discoveryError?: string | null;
  selectedApplianceId?: string | null; applianceConnection: ApplianceConnectionStatus; applianceError?: string | null; appliance?: ApplianceState | null;
  energyUsage: EnergyUsageState; pendingPairings: PendingPairingRequest[]; pairedDevices: PairedDevice[]; busyActions: string[]; startWithWindows: boolean;
  offTimerEndsAt?: string | null; filterRuntimeHours: number; filterReminderDue: boolean; filterReminderIntervalHours: number; alertsEnabled: boolean;
}
export interface UpdateContext { currentVersion: string; managed: boolean; packageId: string; channel: string }
export interface AvailableUpdate { version: string; notes: string; packageId: string; channel: string; releaseUrl: string }
