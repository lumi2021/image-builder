// This structure is here only for allowing documentation
const SizeConstantsType = struct {
    /// 1 Kebibyte
    KiB: usize,
    /// 1 Mebibyte
    MiB: usize,
    /// 1 Gibibyte
    GiB: usize,
    /// GPT reserved sectors padding
    GPT_reserved_sectors: usize
};

pub const size_constants: SizeConstantsType = .{
    .KiB = 2,
    
    .MiB = 1024 * 2,
    .GiB = 1024 * 1024 * 2,

    // MBR + GPT header + 32-sectors table
    // + GPT backup + 32-sectors table backup + 1
    .GPT_reserved_sectors = 1 + 1 + 32 + 1 + 32 + 1,
};
