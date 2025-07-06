const std = @import("std");
const imageBuilder = @import("../imageBuilder.zig");
const layouts = @import("layouts.zig");
const Crc32 = std.hash.Crc32;

pub fn write_headers(
    img_file: std.fs.File,
    builder: *imageBuilder.DiskBuilder,
    _: *std.Build,
    progress: *const std.Progress.Node,
) !layouts.Limits {

    var w = img_file.writer();

    // random data
    const sectors_count: usize = builder.size_sectors;
    const first_sector = 1;
    const last_sector: u32 = @intCast(sectors_count - 1);

    var n = progress.start("Writing Master Boot Record", 1);
    {
        const partitions = builder.partitions.items;

        var p_start: u32 = 1;

        // Writing partition entries
        for (partitions, 0..) |p, i| {
            const p_end: u32 = @truncate(p_start + p.size);

            gotoOffset(img_file, 0, 0x1BE + i * 16);
            writeI(&w, u8, 0x80);

            const cylinder_0 = p_start / (255 * 63);
            const temp_0 = p_start % (255 * 63);
            const head_0: u8 = @truncate(temp_0 / 63);
            const sector_0 = (temp_0 % 63) + 1;
            const addr_0: u16 = @truncate((sector_0 & 0x3F) | ((std.math.shr(usize, cylinder_0, p_start)) & 0xC0));

            writeI(&w, u8, head_0); // start CHS head (legacy)
            writeI(&w, u16, addr_0); // start CHS addr (legacy)

            writeI(&w, u8, get_partition_type(p));

            const cylinder_1 = p_end / (255 * 63);
            const temp_1 = p_end % (255 * 63);
            const head_1: u8 = @truncate(temp_1 / 63);
            const sector_1 = (temp_1 % 63) + 1;
            const addr_1: u16 = @truncate((sector_1 & 0x3F) | ((cylinder_1 >> 2) & 0xC0));

            writeI(&w, u8, head_1); // end CHS head (legacy)
            writeI(&w, u16, addr_1); // end CHS (legacy)

            writeI(&w, u32, p_start); // first sector
            writeI(&w, u32, p_end); // last sector

            p_start = p_end + 1;
        }

        // BOOT sector signature
        gotoOffset(img_file, 0, 0x1FE);
        _ = img_file.write("\x55\xAA") catch unreachable;
    }
    n.end();

    return .{
        .limit_start = first_sector,
        .limit_end = last_sector,
    };

}

fn get_partition_type(partition: *const imageBuilder.Partition) u8 {

    switch (partition.filesystem) {
        .vFAT => {

            const MiB = 1024 * 2;
            const GiB = 1024 * MiB;

            if (partition.size < 16*MiB) return 0x01;    // FAT12
            if (partition.size < 512*MiB) return 0x04;   // FAT16 CHS
            if (partition.size < 2 * GiB) return 0x06;   // FAT16 LBA
            if (partition.size <= 32 * GiB) return 0x0B; // FAT32 CHS (mas LBA é comum também)
            
            return 0x0C; // FAT32 LBA

        },

        //else => std.debug.panic("MBR partition type not implemented for file system {s}!", .{@tagName(partition.filesystem)})
    }

}

// utils
const gotoSector = imageBuilder.gotoSector;
const gotoOffset = imageBuilder.gotoOffset;
const writeI = imageBuilder.writeI;
const genGuid = imageBuilder.genGuid;
