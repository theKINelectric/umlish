const std = @import("std");
const engine = @import("engine/tune.zig");

pub const version = "1.0";

pub const Config = struct {
    loud: bool = false,
};

pub fn launch(input: []const u8) !void {
    _ = engine.tune(input);
    std.debug.print("launch\n", .{});
}
