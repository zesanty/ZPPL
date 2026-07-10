const std = @import("std");
const Io = std.Io;

const parser = @import("parser.zig");
const machine = @import("machine.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_impl = std.Io.File.stdout().writer(io, &stdout_buf);
    const writer = &stdout_impl.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_impl = std.Io.File.stdin().reader(io, &stdin_buf);
    const reader = &stdin_impl.interface;

    try writer.print("Welcome to the ZPPL REPL.\n", .{});
    try writer.print("Commands:\n", .{});
    try writer.print("  /lw          - Switch to Likelihood Weighting\n", .{});
    try writer.print("  /smc         - Switch to Sequential Monte Carlo\n", .{});
    try writer.print("  /mh          - Switch to Metropolis-Hastings\n", .{});
    try writer.print("  (Type inline commands like `/mh <expr>` to run once and switch)\n\n", .{});

    var mode: enum { lw, smc, mh } = .lw;

    while (true) {
        const mode_symbol = switch (mode) {
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

        while (true) {
            const char = reader.takeByte() catch |err| {
                if (err == error.EndOfStream) {
                    eof = true;
                    break;
                }
                try writer.print("Read error: {s}\n", .{@errorName(err)});
                break;
            };
            if (char == '\n') break;
            if (char != '\r') {
                try input_buf.append(temp_alloc, char);
            }
        }

        const trimmed = std.mem.trim(u8, input_buf.items, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "quit") or eof) {
            try writer.print("Exiting REPL...\n", .{});
            break;
        }

        if (trimmed.len > 0) {
            var rest_input = trimmed;
            var command_only = false;

            if (std.mem.startsWith(u8, trimmed, "/lw")) {
                mode = .lw;
                rest_input = std.mem.trim(u8, trimmed[3..], " \t\r\n");
                if (rest_input.len == 0) command_only = true;
            } else if (std.mem.startsWith(u8, trimmed, "/smc")) {
                mode = .smc;
                rest_input = std.mem.trim(u8, trimmed[4..], " \t\r\n");
                if (rest_input.len == 0) command_only = true;
            } else if (std.mem.startsWith(u8, trimmed, "/mh")) {
                mode = .mh;
                rest_input = std.mem.trim(u8, trimmed[3..], " \t\r\n");
                if (rest_input.len == 0) command_only = true;
            }

            if (command_only) {
                const mode_name = switch (mode) {
                    .lw => "Likelihood Weighting",
                    .smc => "Sequential Monte Carlo",
                    .mh => "Metropolis-Hastings",
                };
                try writer.print("Mode changed to: {s}\n", .{mode_name});
                continue;
            }

            const parsed_forms = parser.parse(temp_alloc, rest_input) catch |err| {
                try writer.print("Parse error: {s}\n", .{@errorName(err)});
                continue;
            };

            const env = try machine.createGlobalEnv(temp_alloc);

            switch (mode) {
                .lw => {
                    const result = machine.runLW(temp_alloc, parsed_forms, 42, env) catch |err| {
                        try writer.print("LW Runtime error: {s}\n", .{@errorName(err)}); // TODO: improve error types
                        continue;
                    };
                    try writer.print("Result: {f}, Log-Weight: {d}\n", .{ result[0], result[1] });
                },
                .smc => {
                    const N = 100;
                    var seeds = try temp_alloc.alloc(u64, N);
                    var seed_rng = std.Random.DefaultPrng.init(42);
                    for (0..N) |i| seeds[i] = seed_rng.random().int(u64);

                    const results = machine.runSMC(temp_alloc, parsed_forms, seeds, env, N) catch |err| {
                        try writer.print("SMC Runtime error: {s}\n", .{@errorName(err)});
                        continue;
                    };

                    try writer.print("Run complete with {d} particles.\nFirst 5 samples: ", .{N});
                    for (0..@min(N, 5)) |i| {
                        if (i > 0) try writer.print(", ", .{});
                        try writer.print("{f}", .{results[i]});
                    }

                    var sum: f64 = 0.0;
                    var numeric_count: usize = 0;
                    for (results) |res| {
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
                },
                .mh => {
                    // const steps = 10000;
                    // const warmup = 10000;
                    // const chain = machine.runMH(temp_alloc, parsed_forms, 42, env, steps, warmup) catch |err| {
                    //     try stdout_writer.print("MH Runtime error: {s}\n", .{@errorName(err)});
                    //     continue;
                    // };
                    //
                    // try stdout_writer.print("Run complete ({d} samples, {d} warmup).\nFirst 5 samples: ", .{ steps, warmup });
                    // for (0..@min(chain.len, 5)) |i| {
                    //     if (i > 0) try stdout_writer.print(", ", .{});
                    //     try stdout_writer.print("{f}", .{chain[i]});
                    // }
                    //
                    // var sum: f64 = 0.0;
                    // var numeric_count: usize = 0;
                    // for (chain) |res| {
                    //     switch (res) {
                    //         .Float => |f| {
                    //             sum += f;
                    //             numeric_count += 1;
                    //         },
                    //         .Int => |i| {
                    //             sum += @floatFromInt(i);
                    //             numeric_count += 1;
                    //         },
                    //         else => {},
                    //     }
                    // }
                    // if (numeric_count > 0) {
                    //     try stdout_writer.print("\nEmpirical Posterior Mean: {d:.4}\n", .{sum / @as(f64, @floatFromInt(numeric_count))});
                    // } else {
                    //     try stdout_writer.print("\n", .{});
                    // }
                },
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
            .Float => |f| { sum += f; numeric_count += 1; },
            .Int => |i| { sum += @floatFromInt(i); numeric_count += 1; },
            else => {},
        }
    }
    const mean = sum / @as(f64, @floatFromInt(numeric_count));

    // Verify convergence to the exact analytical posterior within statistical margin
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

fn primMul(alloc: std.mem.Allocator, args: []const Value) !Value {
    _ = alloc;
    var prod: f64 = 1.0;
    for (args) |a| {
        prod *= switch (a) {
            .Float => |f| f,
            .Int => |i| @floatFromInt(i),
            else => 1.0,
        };
    }
    return Value{ .Float = prod };
}

test "Eval HOF" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (let [apply (fn [f val] (f val))] (apply (fn [x] (* x 2)) 21))
    const parsed = try parser.parse(alloc, "(let [apply (fn [f val] (f val))] (apply (fn [x] (* x 2)) 21))");
    const env = try machine.createGlobalEnv(alloc);
    try env.put("*", Value{ .Primitive = primMul }); // Inject local primitive multiplier
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
    const trace_res = try machine.runTrace(alloc, parsed, 42, env, null, std.StringHashMap(Value).init(alloc));

    // Test matches: self assert: result trace sampleValues size equals: 1.
    try std.testing.expectEqual(@as(usize, 1), trace_res.X.count());
}

test "Eval Observe Trace" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parser.parse(alloc, "(observe (normal 0.0 1.0) 5.0)");
    const env = try machine.createGlobalEnv(alloc);
    const trace_res = try machine.runTrace(alloc, parsed, 42, env, null, std.StringHashMap(Value).init(alloc));

    // Test matches: self assert: result trace observeDensities size equals: 1.
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
    
    // Steps: 1000, Warmup: 200
    const chain = try machine.runMH(alloc, parsed, 42, env, 1000, 200);

    var sum: f64 = 0.0;
    var numeric_count: usize = 0;
    for (chain) |res| {
        switch (res) {
            .Float => |f| { sum += f; numeric_count += 1; },
            .Int => |i| { sum += @floatFromInt(i); numeric_count += 1; },
            else => {},
        }
    }
    const posterior_mean = sum / @as(f64, @floatFromInt(numeric_count));

    try std.testing.expect(posterior_mean >= 0.9 and posterior_mean <= 1.4);
}

