import CoreHaptics
import Foundation
#if os(iOS)
import Flutter
#elseif os(macOS)
import AppKit
import FlutterMacOS
#endif

public typealias CHFFIEngineCallback = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

private let notSupportedCode: Int32 = 1
private let engineCode: Int32 = 2
private let invalidHandleCode: Int32 = 3
private let invalidArgumentCode: Int32 = 4
private let patternErrorCode: Int32 = 5
private let playerErrorCode: Int32 = 6
private let ioErrorCode: Int32 = 7
private let decodeErrorCode: Int32 = 8
private let runtimeErrorCode: Int32 = 9
private let unknownErrorCode: Int32 = 255

private let eventStopped: Int32 = 1
private let eventReset: Int32 = 2
private let eventInterrupted: Int32 = 3
private let eventRestarted: Int32 = 4

private func setMessage(_ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ text: String) {
    guard let message = message else { return }
    message.pointee = strdup(text)
}

private func supportsHaptics() -> Bool {
    CHHapticEngine.capabilitiesForHardware().supportsHaptics
}

private final class EngineBox {
    let engine: CHHapticEngine
    let queue: DispatchQueue
    let callback: CHFFIEngineCallback?
    let context: UnsafeMutableRawPointer?
    var callbacksEnabled: Bool = true

    init(engine: CHHapticEngine, callback: CHFFIEngineCallback?, context: UnsafeMutableRawPointer?) {
        self.engine = engine
        self.callback = callback
        self.context = context
        self.queue = DispatchQueue(label: "core.haptics.ffi.engine.\(UUID().uuidString)")
    }
}

private final class PatternBox {
    let pattern: CHHapticPattern

    init(pattern: CHHapticPattern) {
        self.pattern = pattern
    }
}

private final class PlayerBox {
    let player: CHHapticAdvancedPatternPlayer

    init(player: CHHapticAdvancedPatternPlayer) {
        self.player = player
    }
}

private func toHandle<T: AnyObject>(_ value: T) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(Unmanaged.passRetained(value).toOpaque())
}

private func fromHandle<T: AnyObject>(_ handle: UnsafeMutableRawPointer?) -> T? {
    guard let handle else { return nil }
    return Unmanaged<T>.fromOpaque(handle).takeUnretainedValue()
}

private func releaseHandle(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<AnyObject>.fromOpaque(handle).release()
}

private func mapError(_ error: Error, message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    if let err = error as? CHHapticError {
        switch err.code {
        case .engineNotRunning, .engineStartTimeout, .serverInitFailed:
            setMessage(message, err.localizedDescription)
            return engineCode
        case .notSupported:
            setMessage(message, err.localizedDescription)
            return notSupportedCode
        default:
            setMessage(message, err.localizedDescription)
            return runtimeErrorCode
        }
    }
    setMessage(message, error.localizedDescription)
    return unknownErrorCode
}

@_cdecl("chffi_string_free")
public func chffi_string_free(_ message: UnsafePointer<CChar>?) -> Int32 {
    guard let message else { return 0 }
    free(UnsafeMutablePointer(mutating: message))
    return 0
}

@_cdecl("chffi_engine_create")
public func chffi_engine_create(
    _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ callback: CHFFIEngineCallback?,
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard supportsHaptics() else {
        setMessage(message, "Haptics not supported on this device")
        return notSupportedCode
    }

    do {
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = false
        let box = EngineBox(engine: engine, callback: callback, context: context)

        engine.resetHandler = { [weak engine] in
            guard box.callbacksEnabled, let callback = callback else { return }
            callback(eventReset, nil, context)
            if let engine = engine {
                try? engine.start()
                callback(eventRestarted, nil, context)
            }
        }

        engine.stoppedHandler = { reason in
            guard box.callbacksEnabled, let callback = callback else { return }
            switch reason {
            case .audioSessionInterrupt:
                callback(eventInterrupted, nil, context)
            default:
                callback(eventStopped, nil, context)
            }
        }

        outHandle?.pointee = toHandle(box)
        return 0
    } catch {
        return mapError(error, message: message)
    }
}

@_cdecl("chffi_engine_start")
public func chffi_engine_start(
    _ handle: UnsafeMutableRawPointer?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let box: EngineBox = fromHandle(handle) else { return invalidHandleCode }
    var startError: Int32 = 0
    box.queue.sync {
        do {
            try box.engine.start()
        } catch {
            startError = mapError(error, message: message)
        }
    }
    return startError
}

@_cdecl("chffi_engine_stop")
public func chffi_engine_stop(
    _ handle: UnsafeMutableRawPointer?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let box: EngineBox = fromHandle(handle) else { return invalidHandleCode }
    var stopError: Int32 = 0
    box.queue.sync {
        box.engine.stop(completionHandler: { _ in })
    }
    return stopError
}

@_cdecl("chffi_engine_release")
public func chffi_engine_release(_ handle: UnsafeMutableRawPointer?) {
    guard let box: EngineBox = fromHandle(handle) else {
        releaseHandle(handle as UnsafeMutableRawPointer?)
        return
    }
    box.callbacksEnabled = false
    box.engine.resetHandler = {}
    box.engine.stoppedHandler = { _ in }
    box.engine.stop(completionHandler: { _ in })
    releaseHandle(handle as UnsafeMutableRawPointer?)
}

private func makePattern(from data: Data) throws -> CHHapticPattern {
    let rawObject = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = rawObject as? [String: Any] else {
        throw NSError(domain: "chffi", code: 1, userInfo: nil)
    }
    var keyed: [CHHapticPattern.Key: Any] = [:]
    for (k, v) in dict {
        let key = CHHapticPattern.Key(rawValue: k)
        keyed[key] = v
    }
    return try CHHapticPattern(dictionary: keyed)
}

@_cdecl("chffi_pattern_from_ahap_data")
public func chffi_pattern_from_ahap_data(
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int32,
    _ outPattern: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let bytes, length > 0 else {
        setMessage(message, "Invalid AHAP buffer")
        return invalidArgumentCode
    }
    do {
        let data = Data(bytes: bytes, count: Int(length))
        let pattern = try makePattern(from: data)
        outPattern?.pointee = toHandle(PatternBox(pattern: pattern))
        return 0
    } catch {
        return mapError(error, message: message)
    }
}

@_cdecl("chffi_pattern_from_ahap_file")
public func chffi_pattern_from_ahap_file(
    _ path: UnsafePointer<CChar>?,
    _ outPattern: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let path else {
        setMessage(message, "Path is null")
        return invalidArgumentCode
    }
    do {
        let url = URL(fileURLWithPath: String(cString: path))
        let data = try Data(contentsOf: url)
        let pattern = try makePattern(from: data)
        outPattern?.pointee = toHandle(PatternBox(pattern: pattern))
        return 0
    } catch {
        return mapError(error, message: message)
    }
}

@_cdecl("chffi_pattern_release")
public func chffi_pattern_release(_ handle: UnsafeMutableRawPointer?) {
    releaseHandle(handle as UnsafeMutableRawPointer?)
}

@_cdecl("chffi_player_create")
public func chffi_player_create(
    _ engineHandle: UnsafeMutableRawPointer?,
    _ patternHandle: UnsafeMutableRawPointer?,
    _ outPlayer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let engineBox: EngineBox = fromHandle(engineHandle) else { return invalidHandleCode }
    guard let patternBox: PatternBox = fromHandle(patternHandle) else { return invalidHandleCode }
    var result: Int32 = 0
    engineBox.queue.sync {
        do {
            let player = try engineBox.engine.makeAdvancedPlayer(with: patternBox.pattern)
            outPlayer?.pointee = toHandle(PlayerBox(player: player))
        } catch {
            result = mapError(error, message: message)
        }
    }
    return result
}

@_cdecl("chffi_player_play")
public func chffi_player_play(
    _ playerHandle: UnsafeMutableRawPointer?,
    _ atTime: Double,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let playerBox: PlayerBox = fromHandle(playerHandle) else { return invalidHandleCode }
    do {
        try playerBox.player.start(atTime: atTime)
        return 0
    } catch {
        return mapError(error, message: message)
    }
}

@_cdecl("chffi_player_stop")
public func chffi_player_stop(
    _ playerHandle: UnsafeMutableRawPointer?,
    _ atTime: Double,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let playerBox: PlayerBox = fromHandle(playerHandle) else { return invalidHandleCode }
    do {
        try playerBox.player.stop(atTime: atTime)
        return 0
    } catch {
        return mapError(error, message: message)
    }
}

@_cdecl("chffi_player_set_loop")
public func chffi_player_set_loop(
    _ playerHandle: UnsafeMutableRawPointer?,
    _ enabled: Int32,
    _ loopStart: Double,
    _ loopEnd: Double,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let playerBox: PlayerBox = fromHandle(playerHandle) else { return invalidHandleCode }
    // macOS Core Haptics does not expose loopStart/loopEnd on CHHapticAdvancedPatternPlayer.
    setMessage(message, "Loop configuration not supported on this platform")
    playerBox.player.loopEnabled = enabled != 0
    return notSupportedCode
}

private func toParameterId(_ parameterId: Int32) -> CHHapticDynamicParameter.ID? {
    switch parameterId {
    case 1: return CHHapticDynamicParameter.ID(rawValue: "HapticIntensity")
    case 2: return CHHapticDynamicParameter.ID(rawValue: "HapticSharpness")
    case 3: return CHHapticDynamicParameter.ID(rawValue: "AttackTime")
    case 4: return CHHapticDynamicParameter.ID(rawValue: "DecayTime")
    case 5: return CHHapticDynamicParameter.ID(rawValue: "ReleaseTime")
    case 6: return CHHapticDynamicParameter.ID(rawValue: "Sustained")
    case 7: return CHHapticDynamicParameter.ID(rawValue: "AudioVolume")
    case 8: return CHHapticDynamicParameter.ID(rawValue: "AudioPan")
    case 9: return CHHapticDynamicParameter.ID(rawValue: "AudioPitch")
    case 10: return CHHapticDynamicParameter.ID(rawValue: "AudioBrightness")
    default: return nil
    }
}

@_cdecl("chffi_player_send_parameter")
public func chffi_player_send_parameter(
    _ playerHandle: UnsafeMutableRawPointer?,
    _ parameterId: Int32,
    _ value: Double,
    _ atTime: Double,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let playerBox: PlayerBox = fromHandle(playerHandle) else { return invalidHandleCode }
    guard let id = toParameterId(parameterId) else {
        setMessage(message, "Unsupported parameter id \(parameterId)")
        return invalidArgumentCode
    }
    do {
        let parameter = CHHapticDynamicParameter(parameterID: id, value: Float(value), relativeTime: 0)
        try playerBox.player.sendParameters([parameter], atTime: atTime)
        return 0
    } catch {
        return mapError(error, message: message)
    }
}

@_cdecl("chffi_player_release")
public func chffi_player_release(_ handle: UnsafeMutableRawPointer?) {
    releaseHandle(handle as UnsafeMutableRawPointer?)
}

@_cdecl("chffi_supports_haptics")
public func chffi_supports_haptics() -> Int32 {
    #if os(macOS)
    return 1
    #else
    return CHHapticEngine.capabilitiesForHardware().supportsHaptics ? 1 : 0
    #endif
}

#if canImport(UIKit)
import UIKit
#endif

@_cdecl("chffi_impact_light")
public func chffi_impact_light() {
    #if canImport(UIKit) && !os(tvOS)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #elseif os(macOS)
    macTap(4)
    #endif
}

@_cdecl("chffi_impact_medium")
public func chffi_impact_medium() {
    #if canImport(UIKit) && !os(tvOS)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #elseif os(macOS)
    macTap(6)
    #endif
}

@_cdecl("chffi_impact_heavy")
public func chffi_impact_heavy() {
    #if canImport(UIKit) && !os(tvOS)
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    #elseif os(macOS)
    macTap(6)
    #endif
}

@_cdecl("chffi_impact_soft")
public func chffi_impact_soft() {
    #if canImport(UIKit) && !os(tvOS)
    if #available(iOS 13.0, *) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    #elseif os(macOS)
    macTap(4)
    #endif
}

@_cdecl("chffi_impact_rigid")
public func chffi_impact_rigid() {
    #if canImport(UIKit) && !os(tvOS)
    if #available(iOS 13.0, *) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
    #elseif os(macOS)
    macTap(6)
    #endif
}

@_cdecl("chffi_notification_success")
public func chffi_notification_success() {
    #if canImport(UIKit) && !os(tvOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #elseif os(macOS)
    macTap(4)
    #endif
}

@_cdecl("chffi_notification_warning")
public func chffi_notification_warning() {
    #if canImport(UIKit) && !os(tvOS)
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    #elseif os(macOS)
    macTap(6)
    #endif
}

@_cdecl("chffi_notification_error")
public func chffi_notification_error() {
    #if canImport(UIKit) && !os(tvOS)
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    #elseif os(macOS)
    macTap(6)
    #endif
}

@_cdecl("chffi_selection")
public func chffi_selection() {
    #if canImport(UIKit) && !os(tvOS)
    UISelectionFeedbackGenerator().selectionChanged()
    #elseif os(macOS)
    macTap(3)
    #endif
}

#if os(macOS)
// Trackpad actuator adapted from Tactile (https://github.com/Mason363/Tactile),
// MIT License, Copyright (c) 2026 Mason Chen. See NOTICE.
// Loaded with dlopen at runtime; nothing is linked at build time.

private let macTapQueue = DispatchQueue(label: "core.haptics.mac.tap", qos: .userInteractive)

private final class MacTrackpadActuator {
    typealias CreateFunc = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    typealias OpenCloseFunc = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias ActuateFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    typealias DeviceListFunc = @convention(c) () -> Unmanaged<CFArray>?
    typealias DeviceIDFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32

    static let shared = MacTrackpadActuator()

    private static let rescanInterval: CFAbsoluteTime = 2

    private var actuators: [UnsafeMutableRawPointer] = []
    private var knownIDs: Set<UInt64> = []
    private var lastScan: CFAbsoluteTime = 0

    private let create: CreateFunc?
    private let open: OpenCloseFunc?
    private let actuate: ActuateFunc?
    private let listDevices: DeviceListFunc?
    private let getDeviceID: DeviceIDFunc?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        let handle = dlopen(path, RTLD_NOW)
        create = MacTrackpadActuator.symbol(handle, "MTActuatorCreateFromDeviceID", CreateFunc.self)
        open = MacTrackpadActuator.symbol(handle, "MTActuatorOpen", OpenCloseFunc.self)
        actuate = MacTrackpadActuator.symbol(handle, "MTActuatorActuate", ActuateFunc.self)
        listDevices = MacTrackpadActuator.symbol(handle, "MTDeviceCreateList", DeviceListFunc.self)
        getDeviceID = MacTrackpadActuator.symbol(handle, "MTDeviceGetDeviceID", DeviceIDFunc.self)
        scan()
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    /// Opens an actuator for every haptic trackpad not seen yet.
    private func scan() {
        lastScan = CFAbsoluteTimeGetCurrent()
        guard let create, let open, let listDevices, let getDeviceID,
              let scanned = listDevices()?.takeRetainedValue() as? [AnyObject] else { return }
        for device in scanned {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            var deviceID: UInt64 = 0
            guard getDeviceID(pointer, &deviceID) == 0, deviceID != 0, !knownIDs.contains(deviceID),
                  let actuator = create(deviceID) else { continue }
            guard open(actuator) == 0 else {
                Unmanaged<AnyObject>.fromOpaque(actuator).release()
                continue
            }
            knownIDs.insert(deviceID)
            actuators.append(actuator)
        }
    }

    /// Returns false when no trackpad actuator is available.
    func tick(_ actuationID: Int32) -> Bool {
        if actuators.isEmpty, CFAbsoluteTimeGetCurrent() - lastScan > MacTrackpadActuator.rescanInterval {
            scan()
        }
        guard let actuate, !actuators.isEmpty else { return false }
        for actuator in actuators {
            _ = actuate(actuator, actuationID, 0, 0, 0)
        }
        return true
    }
}

/// Plays one tap on the trackpad. Actuation IDs: 3 weak, 4 medium, 6 strong.
/// Falls back to the public API when no trackpad actuator is available.
private func macTap(_ actuationID: Int32) {
    macTapQueue.async {
        if MacTrackpadActuator.shared.tick(actuationID) { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern =
            actuationID >= 6 ? .levelChange : actuationID >= 4 ? .generic : .alignment
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}
#endif

public class CoreHapticsPlugin: NSObject, FlutterPlugin {
    private static let symbols: [Any] = [
        chffi_string_free as Any,
        chffi_engine_create as Any,
        chffi_engine_start as Any,
        chffi_engine_stop as Any,
        chffi_engine_release as Any,
        chffi_pattern_from_ahap_data as Any,
        chffi_pattern_from_ahap_file as Any,
        chffi_pattern_release as Any,
        chffi_player_create as Any,
        chffi_player_play as Any,
        chffi_player_stop as Any,
        chffi_player_set_loop as Any,
        chffi_player_send_parameter as Any,
        chffi_player_release as Any,
        chffi_supports_haptics as Any,
        chffi_impact_light as Any,
        chffi_impact_medium as Any,
        chffi_impact_heavy as Any,
        chffi_impact_soft as Any,
        chffi_impact_rigid as Any,
        chffi_notification_success as Any,
        chffi_notification_warning as Any,
        chffi_notification_error as Any,
        chffi_selection as Any,
    ]

    public static func register(with registrar: FlutterPluginRegistrar) {
        _ = registrar
        _ = symbols
    }
}

