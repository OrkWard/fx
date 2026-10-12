import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

// The first `zig build` against an empty cache compiles Zig's build runner,
// which can take longer than a single test's timeout.
export const ZIG_BUILD_WARMUP_TIMEOUT_MS = 300_000;

// Resolves the global cache the way `zig` does for this process, so a test
// that isolates HOME can keep reusing it.
export function zigGlobalCacheDir(): string {
  if (process.env.ZIG_GLOBAL_CACHE_DIR) return process.env.ZIG_GLOBAL_CACHE_DIR;
  if (process.env.XDG_CACHE_HOME) return join(process.env.XDG_CACHE_HOME, "zig");
  return join(homedir(), ".cache", "zig");
}

