const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const Crc32 = std.hash.Crc32;

pub fn AddBuildImage(b: *Build, comptime size: []const u8, out_path: []const u8) *ImageBuilder {
    comptime var str_size: []const u8 = undefined;
    var multiplier: usize = 1;

    if (comptime std.ascii.isAlphabetic(size[size.len - 1])) {
        str_size = comptime size[0..(size.len - 1)];

        switch (size[size.len - 1]) {
            'k' => multiplier = 1024,
            'm' => multiplier = 1024 * 1024,
            'g' => multiplier = 1024 * 1024 * 1024,
            else => @compileError("unexpected size indicator '" ++ size[size.len - 1 .. size.len] ++ "'"),
        }
    } else str_size = size;

    const int_size = comptime std.fmt.parseInt(usize, str_size, 16) catch @compileError("\"" ++ str_size ++ "\" is a not valid hexadecimal unsigned number!");

    return ImageBuilder.create(b, int_size * multiplier, out_path);
}

pub const ImageBuilder = struct {
    build: *Build,
    step: Step,
    size_bytes: usize,
    output_path: []const u8,

    pub fn create(b: *Build, size_bytes: usize, output_path: []const u8) *@This() {
        const self = b.allocator.create(@This()) catch unreachable;
        self.* = .{ .build = b, .step = Build.Step.init(.{ .id = .custom, .name = "Build Image", .owner = b, .makeFn = make }), .output_path = output_path, .size_bytes = size_bytes };

        return self;
    }
};

fn make(step: *Step, progress: std.Progress.Node) anyerror!void {
    const builder: *ImageBuilder = @fieldParentPtr("step", step);
    const b = builder.build;

    var n = progress.start("creating image file", 1);

    const paths = [_][]const u8{ b.install_path, builder.output_path };
    const img_out_file = std.fs.path.joinZ(b.allocator, &paths) catch unreachable;
    defer b.allocator.free(img_out_file);
    const img_out_path = std.fs.path.dirname(img_out_file).?;

    // Create the out directory if it do not exists
    _ = fs.accessAbsolute(img_out_path, .{ .mode = .read_write })
        catch fs.cwd().makeDir(img_out_path) catch unreachable;
    
    // Create the file
    const img_file = fs.cwd().createFile(img_out_file, .{ .read = true }) catch unreachable;
    defer img_file.close();

    // Set the file the requested disk size
    img_file.setEndPos(builder.size_bytes) catch unreachable;

    var w = img_file.writer();
    const r = img_file.reader();

    // random data
    const sectors_count = builder.size_bytes / 512;

    n.end();
    n = progress.start("writing sectors", 1);
    {
        
        var n2 = n.start("MBR", 1);
        {
            gotoOffset(img_file, 0, 0x1FE);
            _ = img_file.write("\x55\xAA") catch unreachable;
            n2.end();
        }

        n2 = n.start("GPT", 1);
        {
            gotoSector(img_file, 1);
            
            _ = w.write("EFI PART") catch unreachable;             // Signature
            _ = w.write("\x00\x01\x00\x00") catch unreachable;     // Revision

            writeI(&w, u64, 96);                        // Header size
            writeI(&w, u32, 0 );                        // header CRC32 (temp)

            writeI(&w, u64, 1);                         // Primary LBA Header
            writeI(&w, u64, 1);                         // Secondary LBA Header

            writeI(&w, u64, 1);                         // Secondary LBA Header

            writeI(&w, u64, 34);                        // First usable LBA
            writeI(&w, u64, sectors_count);             // Last usable LBA

            writeI(&w, u128, genGuid());                // Disk UUID

            writeI(&w, u32, 2);                         // Partition table LBA
            writeI(&w, u32, 128);                       // Partition count
            writeI(&w, u32, 128);                       // Partition entry size
            writeI(&w, u32, 0 );                        // partition table CRC32 (temp)
            n2.end();
        }

        n2 = n.start("Partitions Table", 1);
        {
            gotoSector(img_file, 2);
            _ = w.write("TODO PARTITIONS TABLE :3") catch unreachable;
            n2.end();
        }

        n2 = n.start("GPT CRC32", 2);
        {
            // back a little to calculate header CRC32
            gotoSector(img_file, 1);
            var header: [96]u8 = undefined;
            _ = r.read(&header) catch unreachable;
            const hash = Crc32.hash(&header);
            gotoOffset(img_file, 1, 0x10);
            writeI(&w, u32, hash);
            n2.completeOne();

            // back a little to calculate partition CRC32

            n2.end();
        }

        n2 = undefined;
    }
    n.end();
}

inline fn gotoSector(f: fs.File, sector: u32) void {
    f.seekTo(sector * 0x200) catch unreachable;
}
inline fn gotoOffset(f: fs.File, sector: u32, offset: u32) void {
    f.seekTo(sector * 0x200 + offset) catch unreachable;
}

inline fn writeI(w: *fs.File.Writer, comptime T: type, value: T) void {
    w.writeInt(T, value, .little) catch unreachable;
}

inline fn genGuid() u128 {
    return @intCast(std.time.nanoTimestamp());
}
