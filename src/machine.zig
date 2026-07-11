const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("parser.zig").Value;
pub const Distribution = @import("probability.zig").Distribution;

// Lexical scope
// Maps built-in funcs/user defined closures OR local variables to a Value (Primitive, Closure, Int in that order.)
pub const Env = *std.StringHashMap(Value);

pub const Closure = struct {
    params: []const Value,
    body: []const Value,
    env: Env,
};

pub const AddrTag = enum { let, body, test_tag, then, els, fn_tag, arg, d, v };
pub const AddrItem = union(AddrTag) { let: usize, body: usize, test_tag: void, then: void, els: void, fn_tag: void, arg: usize, d: void, v: void };
pub const Addr = []const AddrItem;

pub const AddrContext = struct {
    pub fn hash(self: AddrContext, key: Addr) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        for (key) |item| {
            const tag = @as(AddrTag, item);
            hasher.update(std.mem.asBytes(&tag));
            switch (item) {
                .let => |v| hasher.update(std.mem.asBytes(&v)),
                .body => |v| hasher.update(std.mem.asBytes(&v)),
                .arg => |v| hasher.update(std.mem.asBytes(&v)),
                else => {},
            }
        }
        return hasher.final();
    }

    pub fn eql(self: AddrContext, a: Addr, b: Addr) bool {
        _ = self;
        if (a.len != b.len) return false;
        for (a, b) |item_a, item_b| {
            const tag_a = @as(AddrTag, item_a);
            const tag_b = @as(AddrTag, item_b);
            if (tag_a != tag_b) return false;
            switch (item_a) {
                .let => |v| if (v != item_b.let) return false,
                .body => |v| if (v != item_b.body) return false,
                .arg => |v| if (v != item_b.arg) return false,
                else => {},
            }
        }
        return true;
    }
};

pub const AddrValueMap = std.HashMap(Addr, Value, AddrContext, std.hash_map.default_max_load_percentage);
pub const AddrFloatMap = std.HashMap(Addr, f64, AddrContext, std.hash_map.default_max_load_percentage);

pub const InstrTag = enum { ev, letk, ifk, discard, callk, samplek, observek };
pub const MachineInstr = union(InstrTag) {
    ev: struct { e: Value, env: Env, addr: Addr },
    letk: struct { binds: []const Value, i: usize, body: []const Value, env: Env, addr: Addr },
    ifk: struct { then_br: Value, els_br: Value, env: Env, addr: Addr },
    discard: void,
    callk: struct { n: usize, addr: Addr },
    samplek: Addr,
    observek: Addr,
};

pub const MessageTag = enum { done, sample, observe };
pub const MachineMessage = union(MessageTag) {
    done: Value,
    sample: struct { addr: Addr, d: Distribution },
    observe: struct { addr: Addr, d: Distribution, y: Value },
};

pub const Machine = struct {
    alloc: Allocator,
    C: std.ArrayList(MachineInstr),
    V: std.ArrayList(Value),
    env: Env,
    rng: std.Random.DefaultPrng,
    log_w: f64,

    pub fn init(alloc: Allocator, seed: u64, init_env: Env) !*Machine {
        const m = try alloc.create(Machine);
        m.* = Machine{
            .alloc = alloc,
            .C = .empty,
            .V = .empty,
            .env = init_env,
            .rng = std.Random.DefaultPrng.init(seed),
            .log_w = 0.0,
        };
        return m;
    }

    pub fn fork(self: *Machine, new_seed: u64) !*Machine {
        const m = try self.alloc.create(Machine);
        m.* = Machine{
            .alloc = self.alloc,
            .C = try self.C.clone(self.alloc),
            .V = try self.V.clone(self.alloc),
            .env = try cloneEnv(self.alloc, self.env),
            .rng = std.Random.DefaultPrng.init(new_seed),
            .log_w = self.log_w,
        };
        return m;
    }

    pub fn send(self: *Machine, val: Value) !void {
        try self.V.append(self.alloc, val);
    }
};

fn cloneEnv(alloc: Allocator, env: Env) !Env {
    const new_env = try alloc.create(std.StringHashMap(Value));
    new_env.* = std.StringHashMap(Value).init(alloc);
    var it = env.iterator();
    while (it.next()) |entry| {
        try new_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return new_env;
}

fn extendAddr(alloc: Allocator, base: Addr, tag: AddrItem) !Addr {
    var new_addr = try alloc.alloc(AddrItem, base.len + 1);
    @memcpy(new_addr[0..base.len], base);
    new_addr[base.len] = tag;
    return new_addr;
}

fn pushBody(alloc: Allocator, C: *std.ArrayList(MachineInstr), body: []const Value, env: Env, addr: Addr) !void {
    if (body.len == 0) return;

    const last_idx = body.len - 1;
    const last_addr = try extendAddr(alloc, addr, .{ .body = last_idx });
    try C.append(alloc, .{ .ev = .{ .e = body[last_idx], .env = env, .addr = last_addr } });

    var idx = last_idx;
    while (idx > 0) {
        idx -= 1;
        try C.append(alloc, .discard);
        const expr_addr = try extendAddr(alloc, addr, .{ .body = idx });
        try C.append(alloc, .{ .ev = .{ .e = body[idx], .env = env, .addr = expr_addr } });
    }
}

pub fn stepMachine(machine: *Machine) !MachineMessage {
    const alloc = machine.alloc;
    while (machine.C.items.len > 0) {
        const instr = machine.C.pop().?;

        switch (instr) {
            .ev => |ev| {
                switch (ev.e) {
                    .Symbol => |s| {
                        if (ev.env.get(s)) |val| {
                            try machine.V.append(alloc, val);
                        } else {
                            return error.NameError;
                        }
                    },
                    .List => |list| {
                        if (list.len == 0) {
                            try machine.V.append(alloc, ev.e);
                            continue;
                        }
                        const head = list[0];
                        if (head == .Symbol and std.mem.eql(u8, head.Symbol, "let")) {
                            const binds = list[1].List;
                            const body = list[2..];
                            if (binds.len > 0) {
                                try machine.C.append(alloc, .{ .letk = .{ .binds = binds, .i = 0, .body = body, .env = ev.env, .addr = ev.addr } });
                                try machine.C.append(alloc, .{ .ev = .{ .e = binds[1], .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .let = 0 }) } });
                            } else {
                                try pushBody(alloc, &machine.C, body, ev.env, ev.addr);
                            }
                        } else if (head == .Symbol and std.mem.eql(u8, head.Symbol, "if")) {
                            const test_expr = list[1];
                            const then_expr = list[2];
                            const els_expr = list[3];
                            try machine.C.append(alloc, .{ .ifk = .{ .then_br = then_expr, .els_br = els_expr, .env = ev.env, .addr = ev.addr } });
                            try machine.C.append(alloc, .{ .ev = .{ .e = test_expr, .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .test_tag = {} }) } });
                        } else if (head == .Symbol and std.mem.eql(u8, head.Symbol, "fn")) {
                            const params = list[1].List;
                            const body = list[2..];
                            const closure = try alloc.create(Closure);
                            closure.* = Closure{ .params = params, .body = body, .env = ev.env };
                            try machine.V.append(alloc, .{ .Closure = closure });
                        } else if (head == .Symbol and std.mem.eql(u8, head.Symbol, "sample")) {
                            try machine.C.append(alloc, .{ .samplek = ev.addr });
                            try machine.C.append(alloc, .{ .ev = .{ .e = list[1], .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .d = {} }) } });
                        } else if (head == .Symbol and std.mem.eql(u8, head.Symbol, "observe")) {
                            try machine.C.append(alloc, .{ .observek = ev.addr });
                            try machine.C.append(alloc, .{ .ev = .{ .e = list[2], .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .v = {} }) } });
                            try machine.C.append(alloc, .{ .ev = .{ .e = list[1], .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .d = {} }) } });
                        } else {
                            try machine.C.append(alloc, .{ .callk = .{ .n = list.len - 1, .addr = ev.addr } });
                            var i: usize = list.len - 1;
                            while (i > 0) : (i -= 1) {
                                try machine.C.append(alloc, .{ .ev = .{ .e = list[i], .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .arg = i - 1 }) } });
                            }
                            try machine.C.append(alloc, .{ .ev = .{ .e = list[0], .env = ev.env, .addr = try extendAddr(alloc, ev.addr, .{ .fn_tag = {} }) } });
                        }
                    },
                    else => {
                        try machine.V.append(alloc, ev.e);
                    },
                }
            },
            .letk => |lk| {
                const new_env = try cloneEnv(alloc, lk.env);
                try new_env.put(lk.binds[2 * lk.i].Symbol, machine.V.pop().?);
                if (2 * (lk.i + 1) < lk.binds.len) {
                    try machine.C.append(alloc, .{ .letk = .{ .binds = lk.binds, .i = lk.i + 1, .body = lk.body, .env = new_env, .addr = lk.addr } });
                    try machine.C.append(alloc, .{ .ev = .{ .e = lk.binds[2 * (lk.i + 1) + 1], .env = new_env, .addr = try extendAddr(alloc, lk.addr, .{ .let = 2 * (lk.i + 1) }) } });
                } else {
                    try pushBody(alloc, &machine.C, lk.body, new_env, lk.addr);
                }
            },
            .ifk => |ik| {
                const cond = machine.V.pop().?;
                const is_true = isTruthy(cond);
                const branch = if (is_true) ik.then_br else ik.els_br;
                const tag: AddrItem = if (is_true) .{ .then = {} } else .{ .els = {} };
                try machine.C.append(alloc, .{ .ev = .{ .e = branch, .env = ik.env, .addr = try extendAddr(alloc, ik.addr, tag) } });
            },
            .discard => {
                _ = machine.V.pop().?;
            },
            .callk => |ck| {
                var args: std.ArrayList(Value) = .empty;
                defer args.deinit(alloc);
                var i: usize = ck.n;
                while (i > 0) : (i -= 1) {
                    try args.insert(alloc, 0, machine.V.pop().?);
                }
                const f = machine.V.pop().?;
                if (f == .Closure) {
                    const clos = f.Closure;
                    const new_env = try cloneEnv(alloc, clos.env);
                    for (clos.params, args.items) |p, arg| {
                        try new_env.put(p.Symbol, arg);
                    }
                    try pushBody(alloc, &machine.C, clos.body, new_env, ck.addr);
                } else if (f == .Primitive) {
                    const res = try f.Primitive(alloc, args.items);
                    try machine.V.append(alloc, res);
                } else {
                    return error.InvalidFunction;
                }
            },
            .samplek => |addr| {
                const d = machine.V.pop().?.Distribution;
                return MachineMessage{ .sample = .{ .addr = addr, .d = d } };
            },
            .observek => |addr| {
                const y = machine.V.pop().?;
                const d = machine.V.pop().?.Distribution;
                return MachineMessage{ .observe = .{ .addr = addr, .d = d, .y = y } };
            },
        }
    }
    return MachineMessage{ .done = machine.V.pop().? };
}

pub fn initialMachine(alloc: Allocator, program_forms: []const Value, seed: u64, init_env: Env) !*Machine {
    const m = try Machine.init(alloc, seed, init_env);

    var main_expr: ?Value = null;

    for (program_forms) |form| {
        switch (form) {
            .List => |list| {
                if (list.len > 0 and @as(@import("parser.zig").ValueTag, list[0]) == .Symbol and std.mem.eql(u8, list[0].Symbol, "defn")) {
                    if (list.len < 4) return error.InvalidDefnSyntax;
                    const name = list[1].Symbol;
                    const params = list[2].List;
                    const body = list[3..];

                    const closure = try alloc.create(Closure);
                    closure.* = Closure{ .params = params, .body = body, .env = init_env };

                    try init_env.put(name, .{ .Closure = closure });
                } else {
                    main_expr = form;
                }
            },
            else => {
                main_expr = form;
            },
        }
    }

    if (main_expr == null) {
        main_expr = Value{ .Nil = {} };
    }

    const empty_addr = try alloc.alloc(AddrItem, 0);
    try m.C.append(alloc, .{ .ev = .{ .e = main_expr.?, .env = init_env, .addr = empty_addr } });
    return m;
}

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
pub fn advance(m: *Machine) !MachineMessage {
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

// Helper to correctly resolve Lisp/Python-style truthiness
fn isTruthy(val: Value) bool {
    return switch (val) {
        .Nil => false,
        .Bool => |b| b,
        .Int => |i| i != 0,
        .Float => |f| f != 0.0,
        else => true,
    };
}

const primitives = @import("primitives.zig");
pub fn createGlobalEnv(alloc: Allocator) !Env {
    const env = try alloc.create(std.StringHashMap(Value));
    env.* = std.StringHashMap(Value).init(alloc);
    try env.put("+", Value{ .Primitive = primitives.primAdd });
    try env.put("-", Value{ .Primitive = primitives.primSubtract });
    try env.put("*", Value{ .Primitive = primitives.primMul });
    try env.put("normal", Value{ .Primitive = primitives.primNormal });
    try env.put("bernoulli", Value{ .Primitive = primitives.primBernoulli });

    return env;
}
