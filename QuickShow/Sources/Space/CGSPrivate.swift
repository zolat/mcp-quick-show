import Cocoa

/// `dlopen`/`dlsym` shim for the private Core Graphics Server (CGS)
/// space APIs used by `SpaceResolver`. These are the same symbols
/// Hammerspoon, Yabai, and AltTab call to read and assign window
/// Spaces — there is no public AppKit equivalent.
///
/// We resolve every symbol lazily and cache. If any resolve returns
/// `nil` (future macOS that drops the symbol), `isAvailable` flips to
/// `false` and `SpaceResolver` skips placement — the panel lands on
/// whichever Space the OS picks (today's behaviour), no crash.
///
/// Acceptable here because QuickShow is distributed outside the App
/// Store. App Store review rejects builds that reference private
/// frameworks; notarization is unaffected.
enum CGSPrivate {
    /// Pseudo-mask covering user + fullscreen + system Spaces. Matches
    /// the value Hammerspoon's `hs.spaces` uses; sufficient for finding
    /// the Space containing a normal terminal window.
    static let allSpacesMask: Int32 = 0x7

    typealias CGSConnectionID = UInt32

    private typealias MainConnFn = @convention(c) () -> CGSConnectionID
    private typealias GetActiveFn = @convention(c) (CGSConnectionID) -> UInt64
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias AddWindowsToSpacesFn = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
    private typealias RemoveWindowsFromSpacesFn = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
    private typealias MoveWindowsToManagedSpaceFn = @convention(c) (CGSConnectionID, CFArray, UInt64) -> Void

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = {
        // CoreGraphics is loaded by the AppKit umbrella; opening it
        // again is a no-op in terms of refcount, just gives us a
        // handle to dlsym against. RTLD_LAZY mirrors the standard
        // pattern from dyld(3).
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    }()

    private static let mainConnFn: MainConnFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: MainConnFn.self)
    }()

    private static let getActiveFn: GetActiveFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSGetActiveSpace") else { return nil }
        return unsafeBitCast(sym, to: GetActiveFn.self)
    }()

    private static let copySpacesFn: CopySpacesForWindowsFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(sym, to: CopySpacesForWindowsFn.self)
    }()

    private static let addWindowsFn: AddWindowsToSpacesFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSAddWindowsToSpaces") else { return nil }
        return unsafeBitCast(sym, to: AddWindowsToSpacesFn.self)
    }()

    private static let removeWindowsFn: RemoveWindowsFromSpacesFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSRemoveWindowsFromSpaces") else { return nil }
        return unsafeBitCast(sym, to: RemoveWindowsFromSpacesFn.self)
    }()

    private static let moveWindowsFn: MoveWindowsToManagedSpaceFn? = {
        guard let h = handle, let sym = dlsym(h, "CGSMoveWindowsToManagedSpace") else { return nil }
        return unsafeBitCast(sym, to: MoveWindowsToManagedSpaceFn.self)
    }()

    /// Required symbols for read paths resolved. `moveWindow` /
    /// `addWindow` / `removeWindow` may individually be unavailable
    /// on future macOS — callers handle that with their own fallback
    /// chain (move → add+remove → no-op).
    static var isAvailable: Bool {
        mainConnFn != nil && getActiveFn != nil && copySpacesFn != nil
    }

    /// CGS connection for the current process. Returns 0 if the
    /// symbol is unavailable (caller should check `isAvailable`
    /// first).
    static func mainConnection() -> CGSConnectionID {
        mainConnFn?() ?? 0
    }

    /// The Space the user is currently looking at. Returns `nil` if
    /// the symbol couldn't be resolved.
    static func activeSpace() -> UInt64? {
        guard let fn = getActiveFn else { return nil }
        let id = fn(mainConnection())
        return id == 0 ? nil : id
    }

    /// All Spaces containing the given window IDs. Returns the first
    /// Space id when the window is on exactly one Space (the common
    /// case for normal terminal windows). `nil` if the lookup failed
    /// or returned an empty list.
    static func spaceForWindow(_ windowID: CGWindowID) -> UInt64? {
        guard let fn = copySpacesFn else { return nil }
        let windows: CFArray = [NSNumber(value: windowID)] as CFArray
        guard let cfArr = fn(mainConnection(), allSpacesMask, windows) else { return nil }
        let arr = cfArr.takeRetainedValue() as? [NSNumber] ?? []
        return arr.first?.uint64Value
    }

    /// Move `windowID` to `spaceID` exclusively — removes it from
    /// whichever Space it currently lives on. Falls back to
    /// add+remove when the unified `Move` symbol is unavailable.
    /// Returns `true` when at least one of the placement strategies
    /// fired so callers can log the outcome.
    @discardableResult
    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) -> Bool {
        let cid = mainConnection()
        let windows: CFArray = [NSNumber(value: windowID)] as CFArray
        if let move = moveWindowsFn {
            move(cid, windows, spaceID)
            return true
        }
        // Fallback path used on macOS versions where the unified
        // Move symbol is absent — remove from every Space we can
        // see the window on, then add to target. Equivalent net
        // effect for normal (non-`canJoinAllSpaces`) windows.
        guard let add = addWindowsFn, let remove = removeWindowsFn else {
            return false
        }
        if let currentSpaces = currentSpacesForWindow(windowID), !currentSpaces.isEmpty {
            let asCF: CFArray = currentSpaces.map { NSNumber(value: $0) } as CFArray
            remove(cid, windows, asCF)
        }
        let targetSpaces: CFArray = [NSNumber(value: spaceID)] as CFArray
        add(cid, windows, targetSpaces)
        return true
    }

    /// All Spaces containing the given window IDs — multi-Space
    /// variant of `spaceForWindow`. Used by `moveWindow`'s fallback
    /// path so it can pull the window off every Space it was added
    /// to (e.g. windows that had `.canJoinAllSpaces`).
    private static func currentSpacesForWindow(_ windowID: CGWindowID) -> [UInt64]? {
        guard let fn = copySpacesFn else { return nil }
        let windows: CFArray = [NSNumber(value: windowID)] as CFArray
        guard let cfArr = fn(mainConnection(), allSpacesMask, windows) else { return nil }
        let arr = cfArr.takeRetainedValue() as? [NSNumber] ?? []
        return arr.map(\.uint64Value)
    }
}
