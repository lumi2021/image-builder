losetup -P /dev/loop0 zig-out/lumiOS.img
losetup -P /dev/loop1 zig-out/lumiOS2.img

mount /dev/loop0p1 mnt1
mount /dev/loop1p1 mnt2