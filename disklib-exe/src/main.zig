const std = @import("std");
const disklib = @import("disklib");

const arg_parser = @import("./arg-parser.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 2) {
        std.log.err("uso: disklib create <saida> [size=..] [table=gpt] [label=..] [part ... endpart]...", .{});
        return error.MissingCommand;
    }

    const cmd = argv[1];
    if (!std.mem.eql(u8, cmd, "create")) {
        std.log.err("comando desconhecido: '{s}'", .{cmd});
        return error.UnknownCommand;
    }

    const disk = try arg_parser.parseCreate(gpa, io, argv[2..]);
    try disklib.process.make(gpa, io, disk);
}
