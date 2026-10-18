const std = @import("std");
const disklib = @import("disklib");

const DiskBuilder = disklib.DiskBuilder;

// chave da CLI -> campo da struct da lib
const disk_aliases = .{
    .table = "layout",
    .size = "size_sectors",
    .guid = "identifier",
};
const part_aliases = .{
    .fs = "filesystem",
    .id = "name",
    .src = "path",
    .size = "size_sectors",
    .guid = "identifier",
};

const DiskBuilderOpts = OptBuilder(DiskBuilder.Options);
const PartBuilderOpts = OptBuilder(disklib.Partition.PartitionOptions);

fn OptBuilder(comptime T: type) type {
    return struct {
        const Self = @This();
        const info = @typeInfo(T).@"struct";
        const names = info.field_names;
        const types = info.field_types;
        const attrs = info.field_attrs;

        value: T,
        seen: [names.len]bool,

        fn init() Self {
            var v: T = undefined;
            inline for (names, types, attrs) |name, FT, attr| {
                if (attr.defaultValue(FT)) |d| @field(v, name) = d;
            }
            return .{ .value = v, .seen = @splat(false) };
        }

        /// Atribui um campo diretamente (sem parsing de texto).
        fn put(self: *Self, comptime name: []const u8, v: @FieldType(T, name)) void {
            inline for (names, 0..) |n, i| {
                if (comptime std.mem.eql(u8, n, name)) {
                    @field(self.value, n) = v;
                    self.seen[i] = true;
                    return;
                }
            }
            @compileError("campo inexistente: " ++ name);
        }

        fn set(self: *Self, key: []const u8, val: []const u8, comptime aliases: anytype) !void {
            const wanted = canonical(aliases, key);
            inline for (names, types, 0..) |name, FT, i| {
                if (std.mem.eql(u8, name, wanted)) {
                    @field(self.value, name) = try parseValue(FT, val);
                    self.seen[i] = true;
                    return;
                }
            }
            std.log.err("opção desconhecida: '{s}'", .{key});
            return error.UnknownOption;
        }

        fn finish(self: *Self) !T {
            inline for (names, types, attrs, 0..) |name, FT, attr, i| {
                if (attr.defaultValue(FT) == null and !self.seen[i]) {
                    std.log.err("opção obrigatória ausente: {s}", .{name});
                    return error.MissingOption;
                }
            }
            return self.value;
        }
    };
}

fn canonical(comptime aliases: anytype, key: []const u8) []const u8 {
    inline for (@typeInfo(@TypeOf(aliases)).@"struct".field_names) |name| {
        if (std.mem.eql(u8, name, key)) return @field(aliases, name);
    }
    return key;
}

// ---------- values ----------

fn parseSizeSectors(s: []const u8) !u64 {
    const sector_size: u64 = 512;
    if (s.len == 0) return error.InvalidSize;

    const suffix_mult: ?u64 = switch (std.ascii.toUpper(s[s.len - 1])) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => null,
    };

    const digits = if (suffix_mult != null) s[0 .. s.len - 1] else s;
    const bytes_per_unit = suffix_mult orelse sector_size;

    const n = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidSize;
    const bytes = std.math.mul(u64, n, bytes_per_unit) catch return error.InvalidSize;
    if (bytes % sector_size != 0) return error.SizeNotSectorAligned;
    return bytes / sector_size;
}

fn parseEnum(comptime E: type, s: []const u8) !E {
    inline for (std.enums.values(E)) |v| {
        const name = @tagName(v);
        if (name[0] == '_') continue; // ignora _unused e similares
        if (std.ascii.eqlIgnoreCase(name, s)) return v;
    }
    std.log.err("valor inválido '{s}'. Válidos:", .{s});
    inline for (std.enums.values(E)) |v| {
        const name = @tagName(v);
        if (name[0] != '_') std.log.err("  {s}", .{name});
    }
    return error.InvalidValue;
}

fn parseValue(comptime T: type, val: []const u8) !T {
    switch (@typeInfo(T)) {
        .optional => |o| return try parseValue(o.child, val),
        .int => return std.math.cast(T, try parseSizeSectors(val)) orelse error.InvalidSize,
        .@"enum" => return try parseEnum(T, val),
        .pointer => {
            if (T == []const u8) return val;
            @compileError("tipo não suportado: " ++ @typeName(T));
        },
        else => @compileError("tipo não suportado: " ++ @typeName(T)),
    }
}

fn splitKv(arg: []const u8) !struct { key: []const u8, val: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse {
        std.log.err("expected key=value, found '{s}'", .{arg});
        return error.ExpectedKeyValue;
    };
    return .{ .key = arg[0..eq], .val = arg[eq + 1 ..] };
}

// ---------- create ----------

pub fn parseCreate(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !*DiskBuilder {
    if (args.len == 0) return error.MissingOutputPath;

    var disk_opts = DiskBuilderOpts.init();
    disk_opts.put("output_path", args[0]);

    var disk: ?*DiskBuilder = null;
    var part: ?PartBuilderOpts = null;

    for (args[1..]) |arg| {
        if (part) |*p| {
            if (std.mem.eql(u8, arg, "endpart")) {
                disk.?.addPartition(try p.finish());
                part = null;
            } else {
                const kv = try splitKv(arg);
                try p.set(kv.key, kv.val, part_aliases);
            }
        } else if (std.mem.eql(u8, arg, "part")) {
            if (disk == null) disk = DiskBuilder.create(gpa, io, try disk_opts.finish());
            part = PartBuilderOpts.init();
        } else {
            if (disk != null) {
                std.log.err("disk options must come before partitions: '{s}'", .{arg});
                return error.DiskOptionAfterPart;
            }
            const kv = try splitKv(arg);
            try disk_opts.set(kv.key, kv.val, disk_aliases);
        }
    }

    if (part != null) {
        std.log.err("'part' with no 'endpart'", .{});
        return error.UnterminatedPart;
    }

    return disk orelse DiskBuilder.create(gpa, io, try disk_opts.finish());
}
