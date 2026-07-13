const std = @import("std");
const Allocator = std.mem.Allocator;
const machine = @import("machine.zig");

const Value = machine.Value;
const Machine = machine.Machine;
const Env = machine.Env;
const Addr = machine.Addr;
const AddrContext = machine.AddrContext;
const AddrValueMap = machine.AddrValueMap;
const AddrFloatMap = machine.AddrFloatMap;
const stepMachine = machine.stepMachine;
const initialMachine = machine.initialMachine;

// ---------------------------------------------------------
// Likelihood Weighting
// ---------------------------------------------------------
pub fn runLW(alloc: Allocator, program_forms: []const Value, seed: u64, init_env: Env) !struct { Value, f64 } {
    const m = try initialMachine(alloc, program_forms, seed, init_env);
    while (true) {
        const msg = try stepMachine(m);
        switch (msg) {
            .done => |val| return .{ val, m.log_w },
            .sample => |s| try m.send(s.d.sample(m.rng.random())),
            .observe => |o| {
                m.log_w += o.d.logProb(o.y);
                try m.send(o.y);
            },
        }
    }
}

// ---------------------------------------------------------
// Sequential Monte Carlo
// ---------------------------------------------------------
pub fn advance(m: *Machine) !machine.MachineMessage {
    var msg = try stepMachine(m);
    while (msg == .sample) {
        try m.send(msg.sample.d.sample(m.rng.random()));
        msg = try stepMachine(m);
    }
    return msg;
}

pub fn runSMC(alloc: Allocator, program_forms: []const Value, seeds: []const u64, init_env: Env, N: usize) ![]Value {
    var particles = try alloc.alloc(*Machine, N);
    for (0..N) |i| particles[i] = try initialMachine(alloc, program_forms, seeds[i], init_env);

    var final_values = try alloc.alloc(Value, N);

    while (true) {
        var log_inc = try alloc.alloc(f64, N);
        var done_count: usize = 0;

        for (0..N) |i| {
            const msg = try advance(particles[i]);
            switch (msg) {
                .done => |val| {
                    done_count += 1;
                    final_values[i] = val;
                },
                .observe => |o| {
                    const lp = o.d.logProb(o.y);
                    particles[i].log_w += lp;
                    log_inc[i] = lp;
                    try particles[i].send(o.y);
                },
                .sample => unreachable,
            }
        }

        if (done_count == N) {
            return final_values;
        } else if (done_count > 0) {
            return error.SMCParticlesMisaligned;
        }

        var max_w = -std.math.inf(f64);
        for (log_inc) |w| if (w > max_w) {
            max_w = w;
        };
        var sum_w: f64 = 0.0;
        var probs = try alloc.alloc(f64, N);
        for (log_inc, 0..) |w, i| {
            probs[i] = @exp(w - max_w);
            sum_w += probs[i];
        }
        for (probs, 0..) |p, i| probs[i] = p / sum_w;

        var next_particles = try alloc.alloc(*Machine, N);
        var parent_rng = std.Random.DefaultPrng.init(seeds[0]);

        for (0..N) |i| {
            const r = parent_rng.random().float(f64);
            var parent_idx: usize = 0;
            var cumul: f64 = 0;
            for (probs, 0..) |p, j| {
                cumul += p;
                if (r <= cumul) {
                    parent_idx = j;
                    break;
                }
            }
            next_particles[i] = try particles[parent_idx].fork(parent_rng.random().int(u64));
        }
        particles = next_particles;
    }
}

// ---------------------------------------------------------
// Single-Site Metropolis-Hastings
// ---------------------------------------------------------
pub const TraceRunResult = struct {
    value: Value,
    X: AddrValueMap,
    S: AddrFloatMap,
    O: AddrFloatMap,
};

pub fn runTrace(alloc: Allocator, program_forms: []const Value, seed: u64, init_env: Env, x0: ?Addr, cache: AddrValueMap) !TraceRunResult {
    const m = try initialMachine(alloc, program_forms, seed, init_env);
    var X = AddrValueMap.init(alloc);
    var S = AddrFloatMap.init(alloc);
    var O = AddrFloatMap.init(alloc);
    while (true) {
        const msg = try stepMachine(m);
        switch (msg) {
            .done => |val| {
                return TraceRunResult{ .value = val, .X = X, .S = S, .O = O };
            },
            .sample => |s| {
                const addr = s.addr;
                const should_redraw = if (x0) |x0_addr| AddrContext.eql(.{}, addr, x0_addr) else true;
                var x: Value = undefined;
                if (should_redraw or !cache.contains(addr)) {
                    x = s.d.sample(m.rng.random());
                } else {
                    x = cache.get(addr).?;
                }
                try X.put(addr, x);
                try S.put(addr, s.d.logProb(x));
                try m.send(x);
            },
            .observe => |o| {
                const addr = o.addr;
                const lp = o.d.logProb(o.y);
                try O.put(addr, lp);
                try m.send(o.y);
            },
        }
    }
}

pub fn runMH(alloc: Allocator, program_forms: []const Value, seed: u64, init_env: Env, steps: usize, warmup: usize) ![]Value {
    var rng = std.Random.DefaultPrng.init(seed);
    const r_rand = rng.random();

    var current = try runTrace(alloc, program_forms, r_rand.int(u64), init_env, null, AddrValueMap.init(alloc));

    var chain: std.ArrayList(Value) = .empty;
    errdefer chain.deinit(alloc);

    const total_steps = steps + warmup;
    for (0..total_steps) |i| {
        if (current.X.count() == 0) {
            if (i >= warmup) try chain.append(alloc, current.value);
            continue;
        }

        var keys: std.ArrayList(Addr) = .empty;
        defer keys.deinit(alloc);
        var it = current.X.keyIterator();
        while (it.next()) |k| {
            try keys.append(alloc, k.*);
        }

        const idx = r_rand.uintLessThan(usize, keys.items.len);
        const a0 = keys.items[idx];

        var proposed = try runTrace(alloc, program_forms, r_rand.int(u64), init_env, a0, current.X);

        var num: f64 = 0.0;
        var o2_it = proposed.O.valueIterator();
        while (o2_it.next()) |p| {
            num += p.*;
        }

        var s2_it = proposed.S.iterator();
        while (s2_it.next()) |entry| {
            const k = entry.key_ptr.*;
            const p = entry.value_ptr.*;
            const is_resampled = AddrContext.eql(.{}, k, a0);
            const in_fwd = is_resampled or !current.X.contains(k);
            if (!in_fwd) {
                num += p;
            }
        }

        var den: f64 = 0.0;
        var o_it = current.O.valueIterator();
        while (o_it.next()) |p| {
            den += p.*;
        }

        var s_it = current.S.iterator();
        while (s_it.next()) |entry| {
            const k = entry.key_ptr.*;
            const p = entry.value_ptr.*;
            const is_resampled = AddrContext.eql(.{}, k, a0);
            const in_rev = is_resampled or !proposed.X.contains(k);
            if (!in_rev) {
                den += p;
            }
        }

        const n_old = @as(f64, @floatFromInt(current.X.count()));
        const n_new = @as(f64, @floatFromInt(proposed.X.count()));
        const log_alpha = (@log(n_old) - @log(n_new)) + (num - den);

        if (@log(r_rand.float(f64)) < log_alpha) {
            current = proposed;
        }

        if (i >= warmup) {
            try chain.append(alloc, current.value);
        }
    }
    return try chain.toOwnedSlice(alloc);
}
