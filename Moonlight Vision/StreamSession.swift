//
//  StreamSession.swift
//  Moonlight Vision
//
//  One stream's connection lifecycle, shared by the RealityKit and UIKit stream views.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import Synchronization

/// Owns one stream's connection: the `StreamManager`, `ControllerSupport`, the IDR watchdog,
/// reconnects, background suspend/resume and teardown. A stream view plugs in a `Port`
/// (renderer and UI callbacks) and draws itself from `phase`.
///
/// Every method is main-actor, non-blocking and idempotent; a call that doesn't fit the current
/// phase is ignored. Only one connection runs per process: a new attempt waits for the previous
/// connection's stop to finish. `ended` is terminal.
@MainActor
final class StreamSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case running
        case reconnecting(attempt: Int)
        case suspended
        case stopping
        case ended(End)
    }

    enum End: Equatable {
        case stopped(StopReason)
        /// The first connection attempt failed, or the previous connection never finished stopping.
        case startFailed(message: String)
        /// The connection dropped and couldn't be re-established (host offline or retries exhausted).
        case connectionLost(message: String)
    }

    enum StopReason: Equatable {
        /// The user stopped the stream.
        case user
        /// The stream window or immersive space went away.
        case windowClosed
    }

    /// What a stream view plugs in.
    struct Port {
        /// Receives every connection callback except connectionTerminated, stageFailed and
        /// launchFailed, which the session handles and reports through `phase`.
        let callbacks: ConnectionCallbacks
        let controllerDelegate: ControllerSupportDelegate
        /// Wait before each connection attempt, so the view and the host can settle.
        let startDelay: TimeInterval
        /// Called on main before each attempt with that attempt's `ControllerSupport` and callbacks.
        /// StreamManager calls the returned factory (on main) to create the renderer, which must be
        /// given those callbacks so the session sees the first frame.
        let prepareAttempt: (ControllerSupport, ConnectionCallbacks) -> () -> AnyVideoDecoderRenderer
    }

    static let maxReconnectAttempts = 3
    private static let reconnectDelay: TimeInterval = 2.5
    /// How long a stop may take before the UI moves on without it.
    private static let stopTimeout: TimeInterval = 5.0
    /// How long a new attempt waits for the previous connection to finish stopping before the
    /// session gives up and tells the user. A healthy stop takes well under a second.
    private static let previousStopTimeout: TimeInterval = 20.0
    /// How long an attempt may take to show its first frame (app launch, handshake and first IDR)
    /// before it counts as failed.
    private static let connectTimeout: TimeInterval = 45.0

    @Published private(set) var phase: Phase = .idle
    /// The current attempt's controller support; replaced on every reconnect.
    @Published private(set) var controllerSupport: ControllerSupport?
    let config: StreamConfiguration
    /// Called once, when the session reaches `.ended`.
    var onEnded: ((End) -> Void)?

    private let host: TemporaryHost?
    private var port: Port?
    private var manager: StreamManager?
    private var renderer: AnyVideoDecoderRenderer?
    private let managerQueue = OperationQueue()
    private var reconnectCount = 0
    /// Bumped whenever the current attempt is superseded, so callbacks and timers from an old one are dropped.
    private var generation = 0
    private var attemptCallbacks: AttemptCallbacks?
    private var idrWatchdogs: [Timer] = []
    private var connectWatchdog: Timer?

    // Process-wide: connections whose stop hasn't returned yet, and attempts waiting for them.
    private static var stopsInFlight = 0
    private static var stopWaiters: [() -> Void] = []

    /// `host` is used to check whether the host is still online before reconnecting.
    init(config: StreamConfiguration, host: TemporaryHost?) {
        self.config = config
        self.host = host
    }

    var isLive: Bool {
        switch phase {
        case .stopping, .ended: return false
        default: return true
        }
    }

    // MARK: - Interface

    func start(port: Port) {
        guard phase == .idle else { return }
        self.port = port
        phase = .connecting
        scheduleAttempt(after: port.startDelay)
    }

    func stop(_ reason: StopReason) {
        switch phase {
        case .stopping, .ended:
            return
        default:
            teardown(ending: .stopped(reason))
        }
    }

    /// Stops the connection but keeps the session, for the app going to the background.
    func suspend() {
        switch phase {
        case .connecting, .running, .reconnecting:
            break
        default:
            return
        }
        print("[StreamSession] Suspending")
        supersedeAttempt()
        phase = .suspended
        reconnectCount = 0
        stopConnection(resetAudio: true, completion: {})
    }

    func resume() {
        guard phase == .suspended, let port else { return }
        print("[StreamSession] Resuming")
        phase = .connecting
        scheduleAttempt(after: port.startDelay)
    }

    func statsOverlayText() -> String? {
        manager?.getStatsOverlayText()
    }

    // MARK: - Attempts

    /// Drops everything the current attempt still has in flight: pending timers and closures check
    /// `generation`, and its callbacks stop reaching the port.
    private func supersedeAttempt() {
        generation += 1
        attemptCallbacks?.supersede()
        attemptCallbacks = nil
    }

    private func scheduleAttempt(after delay: TimeInterval) {
        supersedeAttempt()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.whenPreviousStopFinished { finished in
                guard gen == self.generation else { return }
                if finished {
                    self.launchAttempt()
                } else {
                    print("[StreamSession] Previous connection is still stopping; giving up")
                    self.teardown(ending: .startFailed(message: MainViewModel.localizedStatic("previous_stream_still_stopping")))
                }
            }
        }
    }

    private func launchAttempt() {
        guard let port else { return }
        guard let support = ControllerSupport(config: config, delegate: port.controllerDelegate) else {
            teardown(ending: .startFailed(message: "Couldn't set up controller support"))
            return
        }
        let gen = generation
        controllerSupport = support
        let callbacks = AttemptCallbacks(session: self, generation: gen, port: port.callbacks, controllerSupport: support)
        attemptCallbacks = callbacks
        let makeRenderer = port.prepareAttempt(support, callbacks)
        guard let manager = StreamManager(
            config: config,
            rendererProvider: { [weak self] in
                let renderer = makeRenderer()
                self?.renderer = renderer
                return renderer
            },
            connectionCallbacks: callbacks
        ) else {
            teardown(ending: .startFailed(message: "Couldn't create the stream"))
            return
        }
        self.manager = manager
        managerQueue.addOperation(manager)
        armIdrWatchdog(generation: gen)
        armConnectWatchdog(generation: gen)
    }

    /// Fail the attempt if it never shows a first frame, so `.connecting` can't hang.
    private func armConnectWatchdog(generation gen: Int) {
        connectWatchdog?.invalidate()
        connectWatchdog = Timer.scheduledTimer(withTimeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                print("[StreamSession] No first frame after \(Self.connectTimeout)s")
                self.connectionFailed(generation: gen, message: MainViewModel.localizedStatic("connect_timed_out"), afterStart: false)
            }
        }
    }

    /// Ask for an IDR frame if the first frame is slow to arrive.
    private func armIdrWatchdog(generation gen: Int) {
        cancelIdrWatchdog()
        idrWatchdogs = [0.5, 0.9].map { delay in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, self.phase != .running else { return }
                    LiRequestIdrFrame()
                }
            }
        }
    }

    private func cancelIdrWatchdog() {
        idrWatchdogs.forEach { $0.invalidate() }
        idrWatchdogs = []
    }

    // MARK: - Connection events

    fileprivate func firstFrameShown(generation gen: Int) {
        guard gen == generation else { return }
        switch phase {
        case .connecting, .reconnecting:
            cancelIdrWatchdog()
            connectWatchdog?.invalidate()
            connectWatchdog = nil
            reconnectCount = 0
            phase = .running
        default:
            break
        }
    }

    /// `afterStart` is true for connectionTerminated, false for stage and launch failures.
    fileprivate func connectionFailed(generation gen: Int, message: String, afterStart: Bool) {
        guard gen == generation else { return }
        switch phase {
        case .connecting where !afterStart:
            print("[StreamSession] Start failed: \(message)")
            teardown(ending: .startFailed(message: message))
        case .connecting, .running, .reconnecting:
            handleLostConnection(message: message)
        default:
            break
        }
    }

    private func handleLostConnection(message: String) {
        // Supersede the failed attempt so its other callbacks are ignored.
        supersedeAttempt()
        let gen = generation
        guard reconnectCount < Self.maxReconnectAttempts else {
            print("[StreamSession] Reconnect attempts exhausted")
            teardown(ending: .connectionLost(message: message))
            return
        }
        probeHostOnline { [weak self] isOnline in
            guard let self, gen == self.generation, self.isLive, self.phase != .suspended else { return }
            guard isOnline else {
                print("[StreamSession] Host offline, not reconnecting")
                self.teardown(ending: .connectionLost(message: message))
                return
            }
            self.reconnectCount += 1
            print("[StreamSession] Connection lost, reconnect attempt \(self.reconnectCount)/\(Self.maxReconnectAttempts)")
            self.phase = .reconnecting(attempt: self.reconnectCount)
            self.stopConnection(resetAudio: false) { [weak self] in
                guard let self, gen == self.generation, let port = self.port else { return }
                self.scheduleAttempt(after: Self.reconnectDelay + port.startDelay)
            }
        }
    }

    private func probeHostOnline(_ completion: @escaping (Bool) -> Void) {
        guard let host, let httpManager = HttpManager(host: host) else {
            completion(true) // No host to ask; retry as normal.
            return
        }
        let serverInfoResponse = ServerInfoResponse()
        let request = HttpRequest(
            for: serverInfoResponse,
            with: httpManager.newServerInfoRequest(false),
            fallbackError: 401,
            fallbackRequest: httpManager.newHttpServerInfoRequest()
        )
        DispatchQueue.global(qos: .userInitiated).async {
            httpManager.executeRequestSynchronously(request)
            let isOnline = serverInfoResponse.isStatusOk()
            DispatchQueue.main.async { completion(isOnline) }
        }
    }

    // MARK: - Teardown

    private func teardown(ending end: End) {
        supersedeAttempt()
        phase = .stopping
        stopConnection(resetAudio: true) { [weak self] in
            self?.finish(end)
        }
    }

    private func finish(_ end: End) {
        guard phase == .stopping else { return }
        port = nil
        phase = .ended(end)
        let onEnded = self.onEnded
        self.onEnded = nil
        onEnded?(end)
    }

    /// Teardown order: render gate, timers and input, stop, wait, audio reset. `completion` runs
    /// on main once the stop returns or `stopTimeout` passes, whichever is first. The audio reset
    /// and the next attempt always wait for the real stop, however long it takes.
    private func stopConnection(resetAudio: Bool, completion: @escaping () -> Void) {
        (renderer as? DrawableVideoDecoder)?.isRenderingEnabled = false
        renderer = nil
        cancelIdrWatchdog()
        connectWatchdog?.invalidate()
        connectWatchdog = nil
        controllerSupport?.cleanup()
        controllerSupport = nil

        guard let manager else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        self.manager = nil

        var completed = false
        let complete = {
            guard !completed else { return }
            completed = true
            completion()
        }
        Self.stopsInFlight += 1
        manager.stopStream(completion: {
            // The UI may move on; on a stuck stop this fires before the connection has stopped.
            MainActor.assumeIsolated { complete() }
        }, stopped: {
            MainActor.assumeIsolated {
                print("[StreamSession] Connection stopped")
                if resetAudio {
                    AudioHelpers.resetAudioSession()
                }
                Self.stopsInFlight -= 1
                if Self.stopsInFlight == 0 {
                    let waiters = Self.stopWaiters
                    Self.stopWaiters = []
                    waiters.forEach { $0() }
                }
                complete()
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopTimeout) {
            if !completed {
                print("[StreamSession] Stop timed out after \(Self.stopTimeout)s; moving on")
            }
            complete()
        }
    }

    /// Calls `body(true)` once no connection is stopping, or `body(false)` after `previousStopTimeout`.
    private func whenPreviousStopFinished(_ body: @escaping (Bool) -> Void) {
        guard Self.stopsInFlight > 0 else {
            body(true)
            return
        }
        print("[StreamSession] Waiting for the previous connection to stop")
        var called = false
        Self.stopWaiters.append {
            guard !called else { return }
            called = true
            body(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previousStopTimeout) {
            guard !called else { return }
            called = true
            body(false)
        }
    }
}

/// One attempt's ConnectionCallbacks. Failures and the first frame go to the session, tagged with
/// the attempt's generation; everything else passes through to the port. Once the session
/// supersedes the attempt, nothing reaches the port or the session any more, so a stale
/// StreamManager can't affect the current one.
private final class AttemptCallbacks: NSObject, ConnectionCallbacks {
    private weak var session: StreamSession?
    private let generation: Int
    private let port: ConnectionCallbacks
    private weak var controllerSupport: ControllerSupport?
    /// Callbacks arrive on main, the VT thread and the connection threads, so this is atomic.
    private let isCurrent = Atomic<Bool>(true)

    init(session: StreamSession, generation: Int, port: ConnectionCallbacks, controllerSupport: ControllerSupport) {
        self.session = session
        self.generation = generation
        self.port = port
        self.controllerSupport = controllerSupport
    }

    func supersede() {
        isCurrent.store(false, ordering: .releasing)
    }

    private var current: Bool {
        isCurrent.load(ordering: .acquiring)
    }

    private func toSession(_ body: @escaping @MainActor (StreamSession) -> Void) {
        guard current else { return }
        Task { @MainActor [weak session] in
            guard let session else { return }
            body(session)
        }
    }

    func connectionStarted() {
        guard current else { return }
        port.connectionStarted()
    }

    func connectionTerminated(_ errorCode: Int32) {
        print("Connection terminated with error code: \(errorCode)")
        let gen = generation
        toSession { $0.connectionFailed(generation: gen, message: "Connection terminated with error code: \(errorCode)", afterStart: true) }
    }

    func stageStarting(_ stageName: UnsafePointer<CChar>!) {
        guard current else { return }
        port.stageStarting(stageName)
    }

    func stageComplete(_ stageName: UnsafePointer<CChar>!) {
        guard current else { return }
        port.stageComplete(stageName)
    }

    func stageFailed(_ stageName: UnsafePointer<CChar>!, withError errorCode: Int32, portTestFlags: Int32) {
        let message: String
        if let stageName {
            let stage = String(cString: stageName)
            message = "Stage \(stage) failed with error \(errorCode)"
            print("Stage failed: \(stage), Error code: \(errorCode), Port test flags: \(portTestFlags)")
        } else {
            message = "Stage failed with error \(errorCode)"
        }
        let gen = generation
        toSession { $0.connectionFailed(generation: gen, message: message, afterStart: false) }
    }

    func launchFailed(_ message: String!) {
        let message = message ?? "Unknown error"
        print("Launch failed: \(message)")
        let gen = generation
        toSession { $0.connectionFailed(generation: gen, message: message, afterStart: false) }
    }

    func rumble(_ controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        guard current else { return }
        controllerSupport?.rumble(controllerNumber, lowFreqMotor: lowFreqMotor, highFreqMotor: highFreqMotor)
    }

    func rumbleTriggers(_ controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16) {
        guard current else { return }
        controllerSupport?.rumbleTriggers(controllerNumber, leftTrigger: leftTrigger, rightTrigger: rightTrigger)
    }

    func connectionStatusUpdate(_ status: Int32) {
        guard current else { return }
        port.connectionStatusUpdate(status)
    }

    func setHdrMode(_ enabled: Bool) {
        guard current else { return }
        port.setHdrMode(enabled)
    }

    func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        guard current else { return }
        port.setMotionEventState(controllerNumber, motionType: motionType, reportRateHz: reportRateHz)
    }

    func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        guard current else { return }
        port.setControllerLed(controllerNumber, r: r, g: g, b: b)
    }

    func videoContentShown() {
        guard current else { return }
        port.videoContentShown()
        let gen = generation
        toSession { $0.firstFrameShown(generation: gen) }
    }
}
