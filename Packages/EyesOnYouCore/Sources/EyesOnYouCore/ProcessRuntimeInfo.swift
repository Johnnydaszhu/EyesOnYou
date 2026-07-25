import Foundation
import Darwin

/// Live kernel facts about a running process: working directory, argv, parent PID.
///
/// `lsof` tells us *which* process holds a socket but not *what it is working on*.
/// A coding agent's cwd is the project it is editing, so reading it turns a
/// `node` / `claude` row into `Claude Code → EyesOnYou` without guessing.
///
/// All lookups only succeed for processes owned by the current user (no root, no
/// entitlements). Callers must treat `nil` as "unknown", never as an error.
public enum ProcessRuntimeInfo {
    /// Current working directory of a same-user process.
    ///
    /// Uses `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. Returns `nil` for other users'
    /// processes, for kernel tasks, and when the vnode path is unavailable.
    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, Int32(size))
        }
        guard written == Int32(size) else { return nil }

        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Full `argv` of a same-user process via `sysctl(KERN_PROCARGS2)`.
    ///
    /// Needed because `lsof` truncates COMMAND to ~9 characters and because
    /// `npm exec <tool>` only names its tool in argv.
    public static func arguments(pid: Int32) -> [String] {
        procArgs2(pid: pid)?.arguments ?? []
    }

    /// Executable path recorded in `KERN_PROCARGS2`, which — unlike `proc_pidpath`
    /// — survives for scripts launched through a runtime wrapper.
    public static func executablePathFromArgs(pid: Int32) -> String? {
        let path = procArgs2(pid: pid)?.executablePath
        return (path?.isEmpty ?? true) ? nil : path
    }

    /// Read **only** the named environment variables of a process.
    ///
    /// A process environment routinely holds API keys and tokens, so this never
    /// returns the full block: values are matched against `keys` while parsing and
    /// everything else is discarded. Callers must keep `keys` to non-secret,
    /// workspace-identifying names (e.g. `CURSOR_WORKSPACE_LABEL`).
    public static func environmentValues(pid: Int32, keys: Set<String>) -> [String: String] {
        guard !keys.isEmpty, let parsed = procArgs2(pid: pid) else { return [:] }
        var found: [String: String] = [:]
        for entry in parsed.environment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<separator])
            guard keys.contains(name) else { continue }
            found[name] = String(entry[entry.index(after: separator)...])
            if found.count == keys.count { break }
        }
        return found
    }

    /// Parent PID via `proc_pidinfo(PROC_PIDTBSDINFO)`.
    public static func parentPID(pid: Int32) -> Int32? {
        guard let info = bsdInfo(pid: pid) else { return nil }
        let ppid = Int32(bitPattern: info.pbi_ppid)
        return ppid > 0 ? ppid : nil
    }

    /// Process start time (seconds since epoch), used to detect PID reuse before
    /// serving a cached identity.
    public static func startTime(pid: Int32) -> UInt64? {
        guard let info = bsdInfo(pid: pid) else { return nil }
        return UInt64(info.pbi_start_tvsec)
    }

    /// Ancestor PIDs from the immediate parent outward, stopping at `launchd` (pid 1).
    ///
    /// MCP servers and build tools are spawned by the agent, so the owning app is
    /// a few hops up rather than in the child's own executable path.
    public static func ancestors(of pid: Int32, maxDepth: Int = 6) -> [Int32] {
        var result: [Int32] = []
        var seen: Set<Int32> = [pid]
        var current = pid
        while result.count < maxDepth {
            guard let parent = parentPID(pid: current), parent > 1 else { break }
            // Defensive: a cycle should be impossible, but never spin on one.
            if seen.contains(parent) { break }
            seen.insert(parent)
            result.append(parent)
            current = parent
        }
        return result
    }

    // MARK: - Internals

    private static func bsdInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard written == Int32(size) else { return nil }
        return info
    }

    private struct ProcArgs {
        var executablePath: String
        var arguments: [String]
        var environment: [String]
    }

    /// Parse `KERN_PROCARGS2`:
    /// `argc | exec_path\0 | padding\0* | argv[0]\0 … argv[argc-1]\0 | env\0 …`
    private static func procArgs2(pid: Int32) -> ProcArgs? {
        guard let buffer = procArgs2Buffer(pid: pid),
              buffer.count > MemoryLayout<Int32>.size
        else { return nil }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        let execStart = cursor
        while cursor < buffer.count, buffer[cursor] != 0 { cursor += 1 }
        let executablePath = String(decoding: buffer[execStart..<cursor], as: UTF8.self)
        // Skip the terminator plus any alignment padding before argv[0].
        while cursor < buffer.count, buffer[cursor] == 0 { cursor += 1 }

        var strings: [String] = []
        var start = cursor
        while cursor < buffer.count {
            if buffer[cursor] == 0 {
                strings.append(String(decoding: buffer[start..<cursor], as: UTF8.self))
                cursor += 1
                start = cursor
            } else {
                cursor += 1
            }
        }
        if start < buffer.count {
            strings.append(String(decoding: buffer[start..<buffer.count], as: UTF8.self))
        }

        let argCount = min(Int(argc), strings.count)
        return ProcArgs(
            executablePath: executablePath,
            arguments: Array(strings.prefix(argCount)),
            environment: Array(strings.dropFirst(argCount)).filter { !$0.isEmpty }
        )
    }

    private static func procArgs2Buffer(pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        if size < buffer.count {
            buffer.removeLast(buffer.count - size)
        }
        return buffer
    }
}
