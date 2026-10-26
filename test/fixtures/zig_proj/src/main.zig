const std = @import("std");
const root = @import("root.zig");
const pet = @import("pets/pet.zig");

pub fn main() !void {
    const p = pet.adopt(.{}, "rover");
    std.debug.print("{s} {s}\n", .{ p.name, root.version });
}
