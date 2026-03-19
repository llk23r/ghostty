//! Replay backend for terminal IO. This backend does NOT spawn a subprocess
//! or allocate a PTY. Instead, terminal output data is fed externally via
//! the `replay_data` mailbox message, which routes through the IO thread
//! and calls Termio.processOutput(). This enables "replay surfaces" that
//! render remote terminal data using the same rendering pipeline as live
//! terminals.
//!
//! Write operations (keyboard input) are silently dropped.
const Replay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_replay);

/// Initialize the replay backend. This is a no-op since there is no
/// subprocess or PTY to set up.
pub fn init() Replay {
    return .{};
}

pub fn deinit(self: *Replay) void {
    _ = self;
}

/// No terminal initialization needed for replay mode.
pub fn initTerminal(self: *Replay, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

/// Thread enter — no read thread to spawn, no subprocess to start.
pub fn threadEnter(
    self: *Replay,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .replay = .{} };
}

/// Thread exit — nothing to clean up.
pub fn threadExit(self: *Replay, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

/// Focus changes are ignored in replay mode.
pub fn focusGained(
    self: *Replay,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

/// Resize is a no-op — the replay surface size is controlled by the viewer.
pub fn resize(
    self: *Replay,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

/// Writes are silently dropped in replay mode. In the future, we could
/// route these to an input callback for remote terminal interaction.
pub fn queueWrite(
    self: *Replay,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc;
    _ = td;
    _ = data;
    _ = linefeed;
}

/// No subprocess to exit abnormally.
pub fn childExitedAbnormally(
    self: *Replay,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Replay backend thread data. Intentionally minimal — no PTY, no
/// process watcher, no write streams.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

/// Configuration for the replay backend. Currently empty since replay
/// surfaces are configured externally.
pub const Config = struct {};
