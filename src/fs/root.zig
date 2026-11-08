//! stdx.fs: Cross-platform filesystem extensions and portable C-stdio fallback.

pub const stdio = @import("stdio.zig");
pub const fileExists = stdio.fileExists;
pub const readFileAlloc = stdio.readFileAlloc;
pub const writeFile = stdio.writeFile;
pub const makeDir = stdio.makeDir;

test {
    _ = stdio;
}
