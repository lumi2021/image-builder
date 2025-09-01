const std = @import("std");
const root = @import("root");

pub const Guid = packed struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: u64,

    pub fn fromInt(value: u128) Guid {
        return @bitCast(value);
    }

    pub fn fromSlice(bytes: []const u8) !Guid {
        if (bytes.len != 16) return error.InvalidLength;
        return std.mem.bytesToValue(Guid, bytes);
    }

    // format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pub fn fromString(str: []const u8) !Guid {
        var buf: [16]u8 = undefined;
        const len = str.len;
        if (len != 36) return error.InvalidFormat;

        var i: usize = 0;
        var j: usize = 0;
        while (i < len) {
            if (str[i] == '-') {
                i += 1;
                continue;
            }
            if (i + 1 >= len or j >= 16) return error.InvalidFormat;
            const b = try std.fmt.parseInt(u8, str[i..i+2], 16);
            buf[j] = b;
            i += 2;
            j += 1;
        }
        if (j != 16) return error.InvalidFormat;
        return fromSlice(&buf);
    }

    /// format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pub fn format(s: *const @This(), comptime _: []const u8, _: std.fmt.FormatOptions, fmt: anytype) !void {
        const bytes: [16]u8 = s.toBytes();

        try fmt.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2}-",
            .{
                bytes[3], bytes[2],
                bytes[1], bytes[0],
            }
        );
        try fmt.print("{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-",
            .{
                bytes[5], bytes[4],
                bytes[7], bytes[6],
            }
        );
        try fmt.print("{x:0>2}{x:0>2}-", .{bytes[8], bytes[9]});
        try fmt.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                bytes[10], bytes[11],
                bytes[12], bytes[13],
                bytes[14], bytes[15],
            }
        );
    }

    fn toBytes(self: *const Guid) [16]u8 {
        var out: [16]u8 = undefined;
        std.mem.writeInt(u32, out[0.. 4], self.data1, .big);
        std.mem.writeInt(u16, out[4.. 6], self.data2, .big);
        std.mem.writeInt(u16, out[6.. 8], self.data3, .big);
        std.mem.writeInt(u64, out[8..16], self.data4, .little);
        return out;
    }

    pub fn isZero(self: @This()) bool {
        return @as(u128, @bitCast(self)) == 0;
    }
    pub fn eql(a: @This(), b: @This()) bool {
        return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
    }

    pub fn new() Guid {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 1 (RFC 4122)

        return Guid.fromSlice(&bytes) catch unreachable;
    }
    pub inline fn zero() Guid {
        return @bitCast(@as(u128, 0));
    }
};
