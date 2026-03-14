const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `show-hierarchy` command prints a JSON snapshot of Ghostty's current
/// window, tab, and terminal hierarchy.
///
/// This command is intended for external automation tools that need a stable,
/// machine-readable view of the current Ghostty layout. The output includes
/// stable IDs and membership relationships for windows, tabs, and terminals.
///
/// On macOS, this queries the running Ghostty app through its AppleScript
/// automation interface. Ghostty must already be running.
///
/// Only supported on macOS.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    if (builtin.os.tag != .macos) {
        var stderr: std.fs.File = .stderr();
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = stderr.writer(&stderr_buffer);
        try stderr_writer.interface.writeAll("+show-hierarchy is only supported on macOS.\n");
        try stderr_writer.end();
        return 1;
    }

    return runMacOS(alloc);
}

fn runMacOS(alloc: Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const exe_path = try std.fs.selfExePathAlloc(arena_alloc);
    const macos_path = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    const contents_path = std.fs.path.dirname(macos_path) orelse return error.InvalidExecutablePath;
    const app_path = std.fs.path.dirname(contents_path) orelse return error.InvalidExecutablePath;

    const app_name_with_ext = std.fs.path.basename(app_path);
    const app_name = if (std.mem.endsWith(u8, app_name_with_ext, ".app"))
        app_name_with_ext[0 .. app_name_with_ext.len - 4]
    else
        app_name_with_ext;

    const set_running = "set ghosttyRunning to false";
    const check_running = try std.fmt.allocPrint(
        arena_alloc,
        "tell application \"System Events\" to set ghosttyRunning to (name of processes) contains \"{s}\"",
        .{app_name},
    );
    const ensure_running = "if ghosttyRunning is false then error \"Ghostty is not running\"";
    const begin_terms = try std.fmt.allocPrint(
        arena_alloc,
        "using terms from application \"{s}\"",
        .{app_path},
    );
    const dump_hierarchy = try std.fmt.allocPrint(
        arena_alloc,
        "tell application \"{s}\" to dump hierarchy",
        .{app_path},
    );

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{
            "osascript",
            "-e",
            set_running,
            "-e",
            check_running,
            "-e",
            ensure_running,
            "-e",
            begin_terms,
            "-e",
            dump_hierarchy,
            "-e",
            "end using terms from",
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer {
        alloc.free(result.stdout);
        alloc.free(result.stderr);
    }

    var stdout: std.fs.File = .stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buffer);

    var stderr: std.fs.File = .stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_buffer);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                try stdout_writer.interface.writeAll(result.stdout);
                if (result.stdout.len == 0 or result.stdout[result.stdout.len - 1] != '\n') {
                    try stdout_writer.interface.writeAll("\n");
                }
                try stdout_writer.end();
                return 0;
            }

            if (result.stderr.len > 0) {
                try stderr_writer.interface.writeAll(result.stderr);
                if (result.stderr[result.stderr.len - 1] != '\n') {
                    try stderr_writer.interface.writeAll("\n");
                }
            } else {
                try stderr_writer.interface.print(
                    "Ghostty hierarchy query failed with exit code {}.\n",
                    .{code},
                );
            }
            try stderr_writer.end();
            return 1;
        },

        else => {
            try stderr_writer.interface.print(
                "Ghostty hierarchy query terminated unexpectedly: {any}\n",
                .{result.term},
            );
            try stderr_writer.end();
            return 1;
        },
    }
}
