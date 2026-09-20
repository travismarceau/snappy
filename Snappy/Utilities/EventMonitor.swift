/// EventMonitor.swift

import Cocoa
import IOKit.hid

protocol EventMonitor {
    var running: Bool { get }
    
    func start()
    func stop()
}

public class PassiveEventMonitor: EventMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent) -> Void

    var running: Bool { localMonitor != nil && globalMonitor != nil }
    
    public init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        self.mask = mask
        self.handler = handler
    }
    
    deinit {
        stop()
    }
    
    public func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            self.handler(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }
    
    public func stop() {
        if localMonitor != nil {
            NSEvent.removeMonitor(localMonitor!)
            localMonitor = nil
        }
        if globalMonitor != nil {
            NSEvent.removeMonitor(globalMonitor!)
            globalMonitor = nil
        }
    }
}

public class ActiveEventMonitor: EventMonitor {
    // start(), stop() and the tap's own re-enable can all run at once - the
    // last of those arrives on the tap's thread while the others come from
    // the main thread - so the port and its thread are guarded.
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let mask: NSEvent.EventTypeMask
    public let filterer: (NSEvent) -> Bool
    public let handler: (NSEvent) -> Void
    let diagnostics = EventTapDiagnostics()

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    public init(mask: NSEvent.EventTypeMask, filterer: @escaping (NSEvent) -> Bool, handler: @escaping (NSEvent) -> Void) {
        self.mask = mask
        self.filterer = filterer
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard tap == nil else { return }
        // Only a trusted process can create a tap. Failing silently here
        // leaves every consumer of this monitor looking simply broken, with
        // nothing anywhere to say why.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask.rawValue, callback: tapCallback, userInfo: CUtil.bridge(obj: self))
        else {
            Logger.log("Unable to create an event tap - accessibility may no longer be authorized")
            return
        }

        // A CGEventTap delivers through the CFMachPort's *callback*, which only
        // runs if a CFRunLoopSource built from that port is on a live run loop.
        //
        // This used to be `runLoop.add(tap, forMode:)`. CFMachPort and NSPort
        // are toll-free bridged, so that compiled -- and installed NSPort's
        // message-delivery machinery instead of the port's callback. The tap was
        // created, the WindowServer had it registered, `running` reported true,
        // and tapCallback was never called once: every event sailed past
        // unfiltered until the WindowServer timed the tap out. Nothing in the
        // app said so, because from the inside a tap that sees no events is
        // indistinguishable from a quiet keyboard.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Logger.log("Unable to build a run loop source for the event tap")
            CFMachPortInvalidate(tap)
            return
        }
        // The main run loop, in common modes.
        //
        // This used to run on a dedicated RunLoopThread, and the callback was
        // never invoked once -- tap created, tap enabled, zero deliveries. The
        // callback itself is trivial (take a lock, read a bool, return), so
        // there is nothing to gain from a private thread and a whole class of
        // "is that run loop actually spinning" to lose. Common modes so the tap
        // keeps delivering while menus are open and windows are being dragged,
        // which is exactly when this app is used.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Accessibility is not sufficient for a keyboard tap. Listening to key
        // events is gated on Input Monitoring (TCC's kTCCServiceListenEvent),
        // and the failure is silent in the worst way: tapCreate returns a real
        // port, tapIsEnabled reports true, and the callback is simply never
        // invoked. From inside the app that is indistinguishable from nobody
        // typing. Ask for it, and record what we were told.
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        UserDefaults.standard.set(hidAccess.rawValue, forKey: "lastInputMonitoringAccess")
        UserDefaults.standard.set(CGEvent.tapIsEnabled(tap: tap), forKey: "lastTapIsEnabled")
        if hidAccess != kIOHIDAccessTypeGranted {
            Logger.log("Input Monitoring not granted (access=\(hidAccess.rawValue)) — key events will not reach the tap. Requesting…")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        Logger.log("Event tap created; enabled=\(CGEvent.tapIsEnabled(tap: tap)) inputMonitoring=\(hidAccess.rawValue)")

        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let tap = tap else { return }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        CGEvent.tapEnable(tap: tap, enable: false)
        // CoreGraphics holds internal references to the CFMachPort from tapCreate, so
        // releasing ours never deallocates it; without an explicit invalidate, the
        // WindowServer keeps the (disabled) tap registration until the process exits.
        // stop()/start() cycles (app switches while snapping is active, and the
        // tapDisabledByTimeout recovery below) would otherwise each leak one entry,
        // degrading system-wide input latency once they accumulate.
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    /// macOS disables a tap whose callback ran long, or on some user input.
    /// Re-enabling the existing port is both the documented remedy and safer
    /// than tearing the monitor down from inside its own callback, which
    /// races any concurrent stop().
    fileprivate func reEnable() {
        lock.lock()
        defer { lock.unlock() }
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

/// Per-monitor delivery counters, so one tap cannot make another look healthy.
final class EventTapDiagnostics {
    struct Snapshot {
        let callbackInvocations: Int
        let disableNotices: Int

        static let zero = Snapshot(callbackInvocations: 0, disableNotices: 0)
    }

    private let lock = NSLock()
    private var callbackInvocations = 0
    private var disableNotices = 0

    func record(_ type: CGEventType) {
        lock.lock()
        callbackInvocations += 1
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disableNotices += 1
        }
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(callbackInvocations: callbackInvocations,
                        disableNotices: disableNotices)
    }
}

fileprivate func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    var filtered = false
    if let ptr = refcon {
        let eventMonitor = CUtil.bridge(ptr: ptr) as ActiveEventMonitor
        eventMonitor.diagnostics.record(type)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            eventMonitor.reEnable()
        } else {
            if let nsEvent = NSEvent(cgEvent: event) {
                filtered = eventMonitor.filterer(nsEvent)
                DispatchQueue.main.async { eventMonitor.handler(nsEvent) }
            }
        }
    }
    return filtered ? nil : Unmanaged.passUnretained(event)
}
