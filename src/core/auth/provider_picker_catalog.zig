//! Column contents for the `/provider` picker.
//!
//! The column holds whitespace-free tokens that are also the labels shown to
//! the user, so what the picker writes into the composer is exactly what the
//! row displays.

const provider_catalog = @import("provider_catalog.zig");

pub const max_provider_options = provider_catalog.entries.len;

/// Writes the visible provider slugs into `out` and returns how many landed.
pub fn providerOptions(out: *[max_provider_options][]const u8) usize {
    var count: usize = 0;
    for (&provider_catalog.entries) |*entry| {
        out[count] = entry.slug;
        count += 1;
    }
    return count;
}
