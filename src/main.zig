const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const parser = @import("parser.zig");
const machine = @import("machine.zig");

const has_posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const TermRawMode = struct {
    original: if (has_posix) std.posix.termios else void = if (has_posix) undefined else {},
    active: bool = false,

    pub fn enable() TermRawMode {
        var self = TermRawMode{};
        if (has_posix) {
            if (std.posix.tcgetattr(0)) |orig| {
                self.original = orig;
                var raw = orig;
                raw.lflag.ICANON = false;
                raw.lflag.ECHO = false;
                if (std.posix.tcsetattr(0, .NOW, raw)) |_| {
                    self.active = true;
                } else |_| {}
            } else |_| {}
        }
        return self;
    }

    pub fn disable(self: *TermRawMode) void {
        if (has_posix and self.active) {
            _ = std.posix.tcsetattr(0, .NOW, self.original) catch {};
            self.active = false;
        }
    }
};

fn printValue(writer: *std.Io.Writer, val: Value) !void {
    try val.format(writer);
}

fn printSamplesAndPosterior(writer: *std.Io.Writer, samples: []const Value, k: u8) !void {
    const clamped_k = @min(samples.len, k);
    try writer.print("First {d} samples: ", .{clamped_k});
    for (0..clamped_k) |i| {
        if (i > 0) try writer.print(", ", .{});
        try printValue(writer, samples[i]);
    }

    var sum: f64 = 0.0;
    var numeric_count: usize = 0;
    for (samples) |res| {
        switch (res) {
            .Float => |f| {
                sum += f;
                numeric_count += 1;
            },
            .Int => |i| {
                sum += @floatFromInt(i);
                numeric_count += 1;
            },
            else => {},
        }
    }
    if (numeric_count > 0) {
        try writer.print("\nEmpirical Posterior Mean: {d:.4}\n", .{sum / @as(f64, @floatFromInt(numeric_count))});
    } else {
        try writer.print("\n", .{});
    }
}

fn runAndPrintLW(alloc: std.mem.Allocator, forms: []const Value, env: machine.Env, writer: *std.Io.Writer, seed: u64) !void {
    const result = try machine.runLW(alloc, forms, seed, env);
    try writer.print("Result: ", .{});
    try printValue(writer, result[0]);
    try writer.print(", Log-Weight: {d}\n", .{result[1]});
}

fn runAndPrintSMC(alloc: std.mem.Allocator, forms: []const Value, env: machine.Env, writer: *std.Io.Writer, seed: u64) !void {
    const N = 1000;
    var seeds = try alloc.alloc(u64, N);
    var seed_rng = std.Random.DefaultPrng.init(seed);
    for (0..N) |i| seeds[i] = seed_rng.random().int(u64);

    const results = try machine.runSMC(alloc, forms, seeds, env, N);
    try writer.print("Run complete with {d} particles.\n", .{N});
    try printSamplesAndPosterior(writer, results, 14);
}

fn runAndPrintMH(alloc: std.mem.Allocator, forms: []const Value, env: machine.Env, writer: *std.Io.Writer, seed: u64) !void {
    const steps = 20000;
    const warmup = 1000;
    const chain = try machine.runMH(alloc, forms, seed, env, steps, warmup);
    try writer.print("Run complete ({d} samples, {d} warmup).\n", .{ steps, warmup });
    try printSamplesAndPosterior(writer, chain, 45);
}

// Clears the current terminal line, rewrites the prompt + buffer, and positions the cursor
fn refreshLine(writer: *std.Io.Writer, mode_symbol: []const u8, buf: []const u8, pos: usize) !void {
    try writer.print("\r\x1b[2K[{s}]> {s}", .{ mode_symbol, buf });
    const left_moves = buf.len - pos;
    if (left_moves > 0) {
        for (0..left_moves) |_| {
            try writer.writeAll("\x1b[D");
        }
    }
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(io, &stdout_buf);
    const writer = &stdout_impl.interface;

    var file_path: ?[]const u8 = null;
    var mode: enum { lw, smc, mh } = .mh;
    var seed: u64 = 42;
    var next_is_seed = false;

    for (args, 0..) |arg, idx| {
        if (idx == 0) continue;

        if (next_is_seed) {
            seed = try std.fmt.parseInt(u64, arg, 10);
            next_is_seed = false;
        } else if (std.mem.eql(u8, arg, "--lw")) {
            mode = .lw;
        } else if (std.mem.eql(u8, arg, "--smc")) {
            mode = .smc;
        } else if (std.mem.eql(u8, arg, "--mh")) {
            mode = .mh;
        } else if (std.mem.eql(u8, arg, "--seed") or std.mem.eql(u8, arg, "-s")) {
            next_is_seed = true;
        } else {
            if (file_path == null) file_path = arg;
        }
    }

    if (file_path) |path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        const parsed_forms = try parser.parse(arena, content);
        const env = try machine.createGlobalEnv(arena);

        switch (mode) {
            .lw => try runAndPrintLW(arena, parsed_forms, env, writer, seed),
            .smc => try runAndPrintSMC(arena, parsed_forms, env, writer, seed),
            .mh => try runAndPrintMH(arena, parsed_forms, env, writer, seed),
        }
        try writer.flush();
        return;
    }

    var stdin_buf: [1024]u8 = undefined;
    var stdin_impl = std.Io.File.stdin().reader(io, &stdin_buf);
    const reader = &stdin_impl.interface;

    try writer.print("Welcome to the ZPPL REPL.\n", .{});
    try writer.print("Commands:\n", .{});
    try writer.print("  /lw          - Switch to Likelihood Weighting\n", .{});
    try writer.print("  /smc         - Switch to Sequential Monte Carlo\n", .{});
    try writer.print("  /mh          - Switch to Metropolis-Hastings\n", .{});
    try writer.print("  /seed <num>  - Set or inspect random seed for REPL evaluations\n\n", .{});
    try writer.print("  /quit         - To quit\n", .{});

    var repl_mode: enum { lw, smc, mh } = .lw;
    var repl_seed: u64 = 0;

    var raw_mode = TermRawMode.enable();
    defer raw_mode.disable();

    var history: std.ArrayList([]const u8) = .empty;
    defer history.deinit(arena);

    while (true) {
        const mode_symbol = switch (repl_mode) {
            .lw => "lw",
            .smc => "smc",
            .mh => "mh",
        };
        try writer.print("[{s}]> ", .{mode_symbol});
        try writer.flush();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();
        const temp_alloc = temp_arena.allocator();

        var input_buf: std.ArrayList(u8) = .empty;
        defer input_buf.deinit(temp_alloc);

        var eof = false;
        var history_index: usize = history.items.len;
        var cursor_pos: usize = 0;

        if (!raw_mode.active) {
            while (true) {
                const char = reader.takeByte() catch |err| {
                    if (err == error.EndOfStream) {
                        eof = true;
                        break;
                    }
                    return err;
                };
                if (char == '\n') break;
                if (char != '\r') try input_buf.append(temp_alloc, char);
            }
        } else {
            while (true) {
                const char = reader.takeByte() catch |err| {
                    if (err == error.EndOfStream) {
                        eof = true;
                        break;
                    }
                    return err;
                };

                if (char == '\n' or char == '\r') {
                    try writer.writeAll("\r\n");
                    try writer.flush();
                    break;
                } else if (char == 127 or char == 8) { // Backspace
                    if (cursor_pos > 0) {
                        _ = input_buf.orderedRemove(cursor_pos - 1);
                        cursor_pos -= 1;
                        try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                    }
                } else if (char == 3) { // Ctrl+C
                    try writer.writeAll("^C\r\n");
                    try writer.flush();
                    input_buf.clearRetainingCapacity();
                    cursor_pos = 0;
                    break;
                } else if (char == 4) { // Ctrl+D
                    eof = true;
                    break;
                } else if (char == '\x1b') { // Escape sequence
                    const next1 = reader.takeByte() catch '\x00';
                    const next2 = reader.takeByte() catch '\x00';
                    if (next1 == '[') {
                        if (next2 == 'A') { // Up Arrow (History Prev)
                            if (history.items.len > 0 and history_index > 0) {
                                history_index -= 1;
                                const cmd = history.items[history_index];
                                input_buf.clearRetainingCapacity();
                                try input_buf.appendSlice(temp_alloc, cmd);
                                cursor_pos = cmd.len;
                                try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                            }
                        } else if (next2 == 'B') { // Down Arrow (History Next)
                            if (history.items.len > 0 and history_index < history.items.len) {
                                history_index += 1;
                                if (history_index == history.items.len) {
                                    input_buf.clearRetainingCapacity();
                                    cursor_pos = 0;
                                    try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                                } else {
                                    const cmd = history.items[history_index];
                                    input_buf.clearRetainingCapacity();
                                    try input_buf.appendSlice(temp_alloc, cmd);
                                    cursor_pos = cmd.len;
                                    try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                                }
                            }
                        } else if (next2 == 'C') { // Right Arrow
                            if (cursor_pos < input_buf.items.len) {
                                cursor_pos += 1;
                                try writer.writeAll("\x1b[C");
                                try writer.flush();
                            }
                        } else if (next2 == 'D') { // Left Arrow
                            if (cursor_pos > 0) {
                                cursor_pos -= 1;
                                try writer.writeAll("\x1b[D");
                                try writer.flush();
                            }
                        } else if (next2 == '3') { // Delete Key Sequence (\x1b[3~)
                            const next3 = reader.takeByte() catch '\x00';
                            if (next3 == '~') {
                                if (cursor_pos < input_buf.items.len) {
                                    _ = input_buf.orderedRemove(cursor_pos);
                                    try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                                }
                            }
                        } else if (next2 == 'H') { // Home Key (\x1b[H)
                            cursor_pos = 0;
                            try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                        } else if (next2 == 'F') { // End Key (\x1b[F)
                            cursor_pos = input_buf.items.len;
                            try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                        }
                    } else if (next1 == 'O') { // Alternatives for Home/End (e.g., \x1bOH, \x1bOF)
                        if (next2 == 'H') {
                            cursor_pos = 0;
                            try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                        } else if (next2 == 'F') {
                            cursor_pos = input_buf.items.len;
                            try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                        }
                    }
                } else if (char >= 32 and char <= 126) { // Printable characters
                    try input_buf.insert(temp_alloc, cursor_pos, char);
                    cursor_pos += 1;
                    try refreshLine(writer, mode_symbol, input_buf.items, cursor_pos);
                }
            }
        }

        const trimmed = std.mem.trim(u8, input_buf.items, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "quit") or eof) {
            try writer.print("Exiting REPL...\n", .{});
            break;
        }

        if (trimmed.len > 0) {
            if (history.items.len == 0 or !std.mem.eql(u8, history.items[history.items.len - 1], trimmed)) {
                const duped = try arena.dupe(u8, trimmed);
                try history.append(arena, duped);
            }

            var rest_input = trimmed;
            var command_only = false;

            if (std.mem.startsWith(u8, trimmed, "/lw")) {
                repl_mode = .lw;
                rest_input = std.mem.trim(u8, trimmed[3..], " \t\r\n");
                if (rest_input.len == 0) command_only = true;
            } else if (std.mem.startsWith(u8, trimmed, "/smc")) {
                repl_mode = .smc;
                rest_input = std.mem.trim(u8, trimmed[4..], " \t\r\n");
                if (rest_input.len == 0) command_only = true;
            } else if (std.mem.startsWith(u8, trimmed, "/mh")) {
                repl_mode = .mh;
                rest_input = std.mem.trim(u8, trimmed[3..], " \t\r\n");
                if (rest_input.len == 0) command_only = true;
            } else if (std.mem.startsWith(u8, trimmed, "/seed")) {
                const seed_str = std.mem.trim(u8, trimmed[5..], " \t\r\n");
                if (seed_str.len == 0) {
                    try writer.print("Current seed is: {d}\n", .{repl_seed});
                } else {
                    repl_seed = try std.fmt.parseInt(u64, seed_str, 10);
                    try writer.print("Seed changed to: {d}\n", .{repl_seed});
                }
                continue;
            }

            if (command_only) {
                const mode_name = switch (repl_mode) {
                    .lw => "Likelihood Weighting",
                    .smc => "Sequential Monte Carlo",
                    .mh => "Metropolis-Hastings",
                };
                try writer.print("Mode changed to: {s}\n", .{mode_name});
                continue;
            }

            const parsed_forms = try parser.parse(temp_alloc, rest_input);
            const env = try machine.createGlobalEnv(temp_alloc);

            switch (repl_mode) {
                .lw => runAndPrintLW(temp_alloc, parsed_forms, env, writer, repl_seed) catch {},
                .smc => runAndPrintSMC(temp_alloc, parsed_forms, env, writer, repl_seed) catch {},
                .mh => runAndPrintMH(temp_alloc, parsed_forms, env, writer, repl_seed) catch {},
            }
        }
    }
    try writer.flush();
}

const ValueTag = parser.ValueTag;
const Value = parser.Value;
// TEST SUITE

test "closure test example" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const shift = "(let [make-shift (fn [mu] (fn [x] (+ x mu)))  f (make-shift 10.0)] (f 3.0))";
    const shift_parsed = try parser.parse(alloc, shift);
    const env1 = try machine.createGlobalEnv(alloc);
    const shift_res = try machine.runLW(alloc, shift_parsed, 0, env1);

    try std.testing.expectEqual(@as(f64, 13.0), shift_res[0].Float);
}

test "geometric mean test" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const geom = "(defn geom [] (if (sample (bernoulli 0.3)) 0 (+ 1 (geom)))) (geom)";
    const geom_parsed = try parser.parse(alloc, geom);

    var seed_rng = std.Random.DefaultPrng.init(1);
    const N = 200000;
    var sum: f64 = 0.0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const env_geom = try machine.createGlobalEnv(alloc);
        const res = try machine.runLW(alloc, geom_parsed, seed_rng.random().int(u64), env_geom);
        switch (res[0]) {
            .Float => |f| sum += f,
            .Int => |val| sum += @floatFromInt(val),
            else => unreachable,
        }
    }
    const mean = sum / @as(f64, @floatFromInt(N));

    try std.testing.expect(mean >= 2.31 and mean <= 2.35);
}

// Helper combinations lookup for n=8
fn comb8(k: usize) f64 {
    const vals = [_]f64{ 1, 8, 28, 56, 70, 56, 28, 8, 1 };
    return vals[k];
}

test "bits MCMC test" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bits_prog =
        \\(let [b1 (if (sample (bernoulli 0.5)) 1 0)
        \\      b2 (if (sample (bernoulli 0.5)) 1 0)
        \\      b3 (if (sample (bernoulli 0.5)) 1 0)
        \\      b4 (if (sample (bernoulli 0.5)) 1 0)
        \\      b5 (if (sample (bernoulli 0.5)) 1 0)
        \\      b6 (if (sample (bernoulli 0.5)) 1 0)
        \\      b7 (if (sample (bernoulli 0.5)) 1 0)
        \\      b8 (if (sample (bernoulli 0.5)) 1 0)
        \\      total (+ b1 b2 b3 b4 b5 b6 b7 b8)]
        \\  (observe (normal 7.0 2.0) total)
        \\  total)
    ;

    const parsed = try parser.parse(alloc, bits_prog);
    const env = try machine.createGlobalEnv(alloc);

    // Compute analytical exact mean
    var sum_num: f64 = 0.0;
    var sum_den: f64 = 0.0;
    var k: usize = 0;
    while (k <= 8) : (k += 1) {
        const k_f = @as(f64, @floatFromInt(k));
        const diff = (k_f - 7.0) / 2.0;
        const w = comb8(k) * @exp(-0.5 * diff * diff);
        sum_num += k_f * w;
        sum_den += w;
    }
    const exact_mean = sum_num / sum_den;

    const steps = 40000;
    const warmup = 3000;
    const chain = try machine.runMH(alloc, parsed, 1, env, steps, warmup);

    var sum: f64 = 0.0;
    var numeric_count: usize = 0;
    for (chain) |res| {
        switch (res) {
            .Float => |f| {
                sum += f;
                numeric_count += 1;
            },
            .Int => |i| {
                sum += @floatFromInt(i);
                numeric_count += 1;
            },
            else => {},
        }
    }
    const mean = sum / @as(f64, @floatFromInt(numeric_count));

    try std.testing.expect(mean >= exact_mean - 0.05 and mean <= exact_mean + 0.05);
}

test "Normal logProb" {
    const dist = machine.Distribution{ .Normal = .{ .mu = 0.0, .sigma = 1.0 } };
    const prob = dist.logProb(Value{ .Float = 0.0 });

    try std.testing.expect(@abs(prob - -0.918938) < 0.0001);
}

test "Normal sample" {
    var rng = std.Random.DefaultPrng.init(42);
    const dist = machine.Distribution{ .Normal = .{ .mu = 10.0, .sigma = 2.0 } };
    const sample_val = dist.sample(rng.random());

    try std.testing.expectEqual(ValueTag.Float, @as(ValueTag, sample_val));
}

test "Eval Literal" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "100");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 100), result[0].Int);
}

test "Eval Symbol" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "y");
    const env = try machine.createGlobalEnv(alloc);
    try env.put("y", Value{ .Int = 42 });
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 42), result[0].Int);
}

test "Eval If True" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(if true 2 1)");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 2), result[0].Int);
}

test "Eval If False" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(if false 2 1)");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 1), result[0].Int);
}

test "Eval Let" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(let [x 1] x)");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 1), result[0].Int);
}

test "Eval Let Multiple Bindings" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(let [x 2 y 5] y)");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 5), result[0].Int);
}

test "Eval Discard" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(let [x 1] 10 99)");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 99), result[0].Int);
}

test "Eval Fn" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "((fn [x] x) 42)");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(i64, 42), result[0].Int);
}

test "Eval Closure" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(let [x 10] (let [f (fn [y] (+ x y))] (f 5)))");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(f64, 15.0), result[0].Float);
}

test "Eval HOF" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(let [apply (fn [f val] (f val))] (apply (fn [x] (* x 2)) 21))");
    const env = try machine.createGlobalEnv(alloc);
    const result = try machine.runLW(alloc, parsed, 42, env);

    try std.testing.expectEqual(@as(f64, 42.0), result[0].Float);
}

test "Eval Sample Trace" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(sample (normal 0.0 1.0))");
    const env = try machine.createGlobalEnv(alloc);
    const trace_res = try machine.runTrace(alloc, parsed, 42, env, null, machine.AddrValueMap.init(alloc));

    try std.testing.expectEqual(@as(usize, 1), trace_res.X.count());
}

test "Eval Observe Trace" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(observe (normal 0.0 1.0) 5.0)");
    const env = try machine.createGlobalEnv(alloc);
    const trace_res = try machine.runTrace(alloc, parsed, 42, env, null, machine.AddrValueMap.init(alloc));

    try std.testing.expectEqual(@as(usize, 1), trace_res.O.count());
}

test "SSMH MCMC Gaussian-Gaussian Conjugate" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const program = "(let [mu (sample (normal 0.0 1.0))] (observe (normal mu 1.0) 2.3) mu)";
    const parsed = try parser.parse(alloc, program);
    const env = try machine.createGlobalEnv(alloc);

    const chain = try machine.runMH(alloc, parsed, 42, env, 1000, 200);

    var sum: f64 = 0.0;
    var numeric_count: usize = 0;
    for (chain) |res| {
        switch (res) {
            .Float => |f| {
                sum += f;
                numeric_count += 1;
            },
            .Int => |i| {
                sum += @floatFromInt(i);
                numeric_count += 1;
            },
            else => {},
        }
    }
    const posterior_mean = sum / @as(f64, @floatFromInt(numeric_count));

    try std.testing.expect(posterior_mean >= 0.9 and posterior_mean <= 1.4);
}

test "Initial Trace Registers Samples" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(sample (normal 0.0 1.0))");
    const env = try machine.createGlobalEnv(alloc);
    const trace_res = try machine.runTrace(alloc, parsed, 42, env, null, machine.AddrValueMap.init(alloc));

    try std.testing.expectEqual(@as(usize, 1), trace_res.X.count());
    try std.testing.expectEqual(@as(usize, 1), trace_res.S.count());
    const empty_addr = try alloc.alloc(machine.AddrItem, 0);
    try std.testing.expect(trace_res.X.contains(empty_addr));
}

test "Initial Trace Registers Observes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(observe (normal 0.0 1.0) 5.0)");
    const env = try machine.createGlobalEnv(alloc);
    const trace_res = try machine.runTrace(alloc, parsed, 0, env, null, machine.AddrValueMap.init(alloc));

    try std.testing.expectEqual(@as(usize, 1), trace_res.O.count());
}

test "Cache Reuse At Non-Redraw Address" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(sample (normal 0.0 1.0))");
    const env = try machine.createGlobalEnv(alloc);

    var cache = machine.AddrValueMap.init(alloc);
    const empty_addr = try alloc.alloc(machine.AddrItem, 0);
    try cache.put(empty_addr, Value{ .Int = 42 });

    var another_addr = try alloc.alloc(machine.AddrItem, 1);
    another_addr[0] = .{ .then = {} };
    const trace_res = try machine.runTrace(alloc, parsed, 12, env, another_addr, cache);

    try std.testing.expectEqual(@as(i64, 42), trace_res.value.Int);
    try std.testing.expectEqual(@as(i64, 42), trace_res.X.get(empty_addr).?.Int);
}

test "Redraw Site Forces New Sample" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(sample (normal 0.0 1.0))");
    const env = try machine.createGlobalEnv(alloc);

    var cache = machine.AddrValueMap.init(alloc);
    const empty_addr = try alloc.alloc(machine.AddrItem, 0);
    try cache.put(empty_addr, Value{ .Int = 42 });

    const trace_res = try machine.runTrace(alloc, parsed, 4542, env, empty_addr, cache);

    try std.testing.expect(trace_res.value.Float != 42.0);
}

test "Absent Address In Cache Forces New Sample" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(sample (normal 0.0 1.0))");
    const env = try machine.createGlobalEnv(alloc);

    const cache = machine.AddrValueMap.init(alloc);

    var another_addr = try alloc.alloc(machine.AddrItem, 1);
    another_addr[0] = .{ .then = {} };
    const trace_res = try machine.runTrace(alloc, parsed, 142, env, another_addr, cache);

    const empty_addr = try alloc.alloc(machine.AddrItem, 0);
    try std.testing.expect(trace_res.X.contains(empty_addr));
    try std.testing.expect(trace_res.X.get(empty_addr).?.Float != 42.0);
}

test "Deterministic Trace Handling" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "42");
    const env = try machine.createGlobalEnv(alloc);

    const chain = try machine.runMH(alloc, parsed, 3442, env, 5, 2);
    try std.testing.expectEqual(@as(usize, 5), chain.len);
    for (chain) |val| {
        try std.testing.expectEqual(@as(i64, 42), val.Int);
    }
}
