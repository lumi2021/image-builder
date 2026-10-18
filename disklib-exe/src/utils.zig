const std = @import("std");
const Io = std.Io;

pub const SectorAllocator = struct {
    first: u32,
    length: u32,

    pub fn getOne(s: *@This()) u32 {
        if (s.length == 0) std.debug.panic("No more sectors left!", .{});
        s.first += 1;
        s.length -= 1;
        return s.first - 1;
    }
    pub fn peek(s: @This()) u32 {
        return s.first;
    }
    pub fn canFit(s: @This(), len: usize) bool {
        return s.length >= len;
    }
};

pub inline fn gotoSector(f: *Io.File.Writer, sector: usize) void {
    f.seekTo(sector * 0x200) catch unreachable;
}
pub inline fn gotoOffset(f: *Io.File.Writer, sector: usize, offset: usize) void {
    f.seekTo(sector * 0x200 + offset) catch unreachable;
}
pub inline fn gotoSectorR(f: *Io.File.Reader, sector: usize) void {
    f.seekTo(sector * 0x200) catch unreachable;
}
pub inline fn gotoOffsetR(f: *Io.File.Reader, sector: usize, offset: usize) void {
    f.seekTo(sector * 0x200 + offset) catch unreachable;
}

pub inline fn writeI(w: *Io.File.Writer, comptime T: type, value: T) void {
    w.interface.writeInt(T, value, .little) catch unreachable;
}
