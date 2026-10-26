const root = @import("../root.zig");

pub const Pet = struct {
    name: []const u8,
};

pub fn adopt(cfg: root.Config, name: []const u8) Pet {
    _ = cfg;
    return .{ .name = name };
}
