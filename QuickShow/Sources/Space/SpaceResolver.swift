import Cocoa
import Darwin

/// Resolves "the macOS Space where Claude lives" for a given sidecar
/// session — and places the session's HUD window there.
///
/// Strategy (per the feasibility plan): walk up the process tree from
/// the sidecar's `parent_pid`, find an ancestor that owns a normal
/// on-screen window, ask the private CGS layer which Space contains
/// that window, then call `CGSAddWindowsToSpaces` to move the HUD
/// onto that Space.
///
/// Graceful degradation chain:
///  1. parent_pid missing / process tree dead    → cached last Space
///  2. no ancestor with a window                 → cached last Space
///  3. CGS lookup fails / empty result           → cached last Space
///  4. no cached Space yet                       → active Space (now)
///  5. CGS symbols unavailable (`CGSPrivate.isAvailable == false`)
///                                               → skip, today's behaviour
@MainActor
enum SpaceResolver {
    /// Try to place `window` on the Space that contains a visible
    /// window owned by `parentPid` (or any of its ancestors). Returns
    /// the Space id that was used so callers can cache it for later
    /// fallback. Returns `nil` only when CGS is unavailable.
    @discardableResult
    static func placeOnClaudeSpace(
        window: NSWindow,
        parentPid: pid_t?,
        cachedSpace: UInt64?
    ) -> UInt64? {
        guard CGSPrivate.isAvailable else {
            NSLog("QuickShow: SpaceResolver — CGS symbols unavailable, skipping placement")
            return nil
        }
        let resolved = resolveSpaceID(for: parentPid) ?? cachedSpace ?? CGSPrivate.activeSpace()
        guard let target = resolved else {
            NSLog("QuickShow: SpaceResolver — no target Space resolved (parent_pid=\(parentPid.map(String.init) ?? "nil")), letting OS decide")
            return nil
        }
        let windowID = CGWindowID(window.windowNumber)
        let currentSpaceForOurWindow = CGSPrivate.spaceForWindow(windowID)
        if currentSpaceForOurWindow != target {
            CGSPrivate.moveWindow(windowID, toSpace: target)
            NSLog("QuickShow: SpaceResolver — moved HUD to Space \(target) (was \(currentSpaceForOurWindow.map(String.init) ?? "?"), parent_pid=\(parentPid.map(String.init) ?? "nil"))")
        }
        return target
    }

    /// Walks up from `pid` collecting ancestors, then enumerates all
    /// windows and returns the Space id of the first window owned by
    /// any ancestor with `kCGWindowLayer == 0` (normal window level).
    /// Returns `nil` when no such window exists (terminal minimised,
    /// SSH session, headless Claude run).
    static func resolveSpaceID(for pid: pid_t?) -> UInt64? {
        guard let startPid = pid, startPid > 1 else { return nil }
        let ancestors = ancestorPids(of: startPid)
        guard !ancestors.isEmpty else { return nil }

        let listOptions = CGWindowListOption([]) // == kCGWindowListOptionAll, returns off-screen windows too
        guard let raw = CGWindowListCopyWindowInfo(listOptions, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Iterate ancestors closest-first — that's the immediate
        // terminal, not Finder or launchd.
        let ancestorSet = Set(ancestors)
        for entry in raw {
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32,
                  ancestorSet.contains(pid_t(owner)) else { continue }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0 else { continue }
            guard let windowNumber = entry[kCGWindowNumber as String] as? Int else { continue }
            if let space = CGSPrivate.spaceForWindow(CGWindowID(windowNumber)) {
                return space
            }
        }
        return nil
    }

    /// Walk the process tree upward via `sysctl(KERN_PROC_PID)` and
    /// return `[pid, ppid, gpid, …]` stopping at PID 1 / launchd.
    /// Cap at 16 hops as a sanity guard against pathological loops.
    static func ancestorPids(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        for _ in 0..<16 {
            if current <= 1 { break }
            chain.append(current)
            guard let parent = parentPid(of: current) else { break }
            if parent == current { break }
            current = parent
        }
        return chain
    }

    /// Single `sysctl(KERN_PROC_PID)` lookup returning the `ppid` of
    /// the given pid. Returns `nil` on lookup failure (process gone).
    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, u_int(buf.count), &info, &size, nil, 0)
        }
        if r != 0 || size == 0 { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
