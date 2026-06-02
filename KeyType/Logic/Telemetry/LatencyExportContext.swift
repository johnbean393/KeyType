//
//  LatencyExportContext.swift
//  KeyType
//
//  App-side glue that collects the hardware/OS/engine context `LatencyExporter` can't see from
//  inside the `Personalization` package, then asks the exporter to assemble + JSON-encode a full
//  on-device latency dump. Triggered from the Settings → Statistics "Export data" button. See
//  ADR-070.
//

import Darwin
import Foundation
import Personalization

@MainActor
enum LatencyExportContext {
    /// Build a JSON payload from the current telemetry store and live settings. Returns `nil` only
    /// if `JSONEncoder` itself throws, which would be a programmer error in `LatencyExport`'s
    /// `Codable` shape rather than a runtime user-facing failure.
    static func makeExportData(
        telemetry: CompletionTelemetryStore,
        settings: SettingsStore,
        now: Date = Date()
    ) -> Data? {
        let export = LatencyExporter.makeExport(
            telemetry: telemetry,
            device: currentDeviceInfo(),
            engine: currentEngineInfo(settings: settings),
            now: now
        )
        return try? LatencyExporter.encodeJSON(export)
    }

    private static func currentDeviceInfo() -> LatencyExportDeviceInfo {
        let process = ProcessInfo.processInfo
        let osv = process.operatingSystemVersion
        let osString = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        let bundleInfo = Bundle.main.infoDictionary
        return LatencyExportDeviceInfo(
            osVersion: osString,
            machineModel: sysctlString("hw.model"),
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            physicalMemoryBytes: process.physicalMemory,
            processorCount: process.processorCount,
            appVersion: bundleInfo?["CFBundleShortVersionString"] as? String,
            appBuild: bundleInfo?[kCFBundleVersionKey as String] as? String
        )
    }

    private static func currentEngineInfo(settings: SettingsStore) -> LatencyExportEngineInfo {
        LatencyExportEngineInfo(
            modelFilename: settings.selectedModelFilename,
            completionLengthLabel: settings.completionLength.rawValue
        )
    }

    /// `sysctlbyname` wrapper that returns the C string for the given key (e.g. `hw.model`) or
    /// `nil` when the key is unavailable on this kernel. Used for hardware/CPU identification in
    /// the export — these strings vary between Apple silicon generations and Intel Macs and are the
    /// most useful single piece of context for explaining per-token decode cost.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
