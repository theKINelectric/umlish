const std = @import("std");

pub const Mode = enum { quiet, loud };

fn hidden(input: []const u8) u8 {
    _ = input;
    return 0;
}

pub fn tune(input: []const u8) u8 {
    _ = input;
    return 1;
}
