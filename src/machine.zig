const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Value = @import("parser.zig").Value;
pub const Distribution = @import("probability.zig").Distribution;
const primitives = @import("primitives.zig");

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

// Static Dispatch Handlers
const Interpreter = struct {
    pub fn ev(machine: *Machine, args: anytype) !?MachineMessage {
        const alloc = machine.alloc;
        switch (args.e) {
            .Symbol => |s| {
                if (args.env.get(s)) |val| {
                    try machine.V.append(alloc, val);
                } else {
                    return error.NameError;
                }
            },
            .List => |list| {
                if (list.len == 0) {
                    try machine.V.append(alloc, args.e);
                    return null;
                }
                try stepList(machine, list, args.env, args.addr);
            },
            else => {
                try machine.V.append(alloc, args.e);
            },
        }
        return null;
    }

    pub fn letk(machine: *Machine, args: anytype) !?MachineMessage {
        const alloc = machine.alloc;
        const new_env = try cloneEnv(alloc, args.env);
        try new_env.put(args.binds[2 * args.i].Symbol, machine.V.pop().?);

        if (2 * (args.i + 1) < args.binds.len) {
            try machine.C.append(alloc, .{ .letk = .{ .binds = args.binds, .i = args.i + 1, .body = args.body, .env = new_env, .addr = args.addr } });
            try machine.C.append(alloc, .{ .ev = .{ .e = args.binds[2 * (args.i + 1) + 1], .env = new_env, .addr = try extendAddr(alloc, args.addr, .{ .let = 2 * (args.i + 1) }) } });
        } else {
            try pushBody(alloc, &machine.C, args.body, new_env, args.addr);
        }
        return null;
    }

    pub fn ifk(machine: *Machine, args: anytype) !?MachineMessage {
        const alloc = machine.alloc;
        const cond = machine.V.pop().?;
        const is_true = isTruthy(cond);
        const branch = if (is_true) args.then_br else args.els_br;
        const tag: AddrItem = if (is_true) .{ .then = {} } else .{ .els = {} };
        try machine.C.append(alloc, .{ .ev = .{ .e = branch, .env = args.env, .addr = try extendAddr(alloc, args.addr, tag) } });
        return null;
    }

    pub fn discard(machine: *Machine, _: void) !?MachineMessage {
        _ = machine.V.pop().?;
        return null;
    }

    pub fn callk(machine: *Machine, args: anytype) !?MachineMessage {
        const alloc = machine.alloc;
        var s_args: std.ArrayList(Value) = .empty;
        defer s_args.deinit(alloc);

        var i: usize = args.n;
        while (i > 0) : (i -= 1) {
            try s_args.insert(alloc, 0, machine.V.pop().?);
        }

        const f = machine.V.pop().?;
        if (f == .Closure) {
            const clos = f.Closure;
            const new_env = try cloneEnv(alloc, clos.env);
            for (clos.params, s_args.items) |p, arg| {
                try new_env.put(p.Symbol, arg);
            }
            try pushBody(alloc, &machine.C, clos.body, new_env, args.addr);
        } else if (f == .Primitive) {
            const res = try f.Primitive(alloc, s_args.items);
            try machine.V.append(alloc, res);
        } else {
            return error.InvalidFunction;
        }
        return null;
    }

    pub fn samplek(machine: *Machine, addr: Addr) !?MachineMessage {
        const d = machine.V.pop().?.Distribution;
        return MachineMessage{ .sample = .{ .addr = addr, .d = d } };
    }

    pub fn observek(machine: *Machine, addr: Addr) !?MachineMessage {
        const y = machine.V.pop().?;
        const d = machine.V.pop().?.Distribution;
        return MachineMessage{ .observe = .{ .addr = addr, .d = d, .y = y } };
    }
};

fn stepList(machine: *Machine, list: []const Value, env: Env, addr: Addr) !void {
    const alloc = machine.alloc;
    const name = if (list[0] == .Symbol) list[0].Symbol else "";
    const Form = enum { let, @"if", @"fn", sample, observe };

    // stringToEnum resolves into an optimized, comptime-generated switch statement
    if (std.meta.stringToEnum(Form, name)) |form| {
        switch (form) {
            .let => {
                const binds = list[1].List;
                if (binds.len == 0) return pushBody(alloc, &machine.C, list[2..], env, addr);
                try machine.C.appendSlice(alloc, &.{
                    .{ .letk = .{ .binds = binds, .i = 0, .body = list[2..], .env = env, .addr = addr } },
                    .{ .ev = .{ .e = binds[1], .env = env, .addr = try extendAddr(alloc, addr, .{ .let = 0 }) } },
                });
            },
            .@"if" => try machine.C.appendSlice(alloc, &.{
                .{ .ifk = .{ .then_br = list[2], .els_br = list[3], .env = env, .addr = addr } },
                .{ .ev = .{ .e = list[1], .env = env, .addr = try extendAddr(alloc, addr, .{ .test_tag = {} }) } },
            }),
            .@"fn" => {
                const closure = try alloc.create(Closure);
                closure.* = .{ .params = list[1].List, .body = list[2..], .env = env };
                try machine.V.append(alloc, .{ .Closure = closure });
            },
            .sample => try machine.C.appendSlice(alloc, &.{
                .{ .samplek = addr },
                .{ .ev = .{ .e = list[1], .env = env, .addr = try extendAddr(alloc, addr, .{ .d = {} }) } },
            }),
            .observe => try machine.C.appendSlice(alloc, &.{
                .{ .observek = addr },
                .{ .ev = .{ .e = list[2], .env = env, .addr = try extendAddr(alloc, addr, .{ .v = {} }) } },
                .{ .ev = .{ .e = list[1], .env = env, .addr = try extendAddr(alloc, addr, .{ .d = {} }) } },
            }),
        }
        return;
    }

    // Function or Primitive Application
    try machine.C.append(alloc, .{ .callk = .{ .n = list.len - 1, .addr = addr } });
    var i: usize = list.len - 1;
    while (i > 0) : (i -= 1) {
        try machine.C.append(alloc, .{ .ev = .{ .e = list[i], .env = env, .addr = try extendAddr(alloc, addr, .{ .arg = i - 1 }) } });
    }
    try machine.C.append(alloc, .{ .ev = .{ .e = list[0], .env = env, .addr = try extendAddr(alloc, addr, .{ .fn_tag = {} }) } });
}

pub fn stepMachine(machine: *Machine) !MachineMessage {
    while (machine.C.items.len > 0) {
        const instr = machine.C.pop().?;

        switch (instr) {
            inline else => |payload, tag| {
                const name = comptime @tagName(tag);
                if (try @field(Interpreter, name)(machine, payload)) |msg| {
                    return msg;
                }
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

const inference = @import("inference.zig");
pub const runLW = inference.runLW;
pub const runSMC = inference.runSMC;
pub const runMH = inference.runMH;
pub const runTrace = inference.runTrace;
pub const TraceRunResult = inference.TraceRunResult;
