const std = @import("std");
const Value = @import("parser.zig").Value;

pub const Distribution = union(enum) {
    Normal: struct { mu: f64, sigma: f64 },
    Bernoulli: struct { p: f64 },

    pub fn sample(self: Distribution, random: std.Random) Value {
        switch (self) {
            .Normal => |n| {
                return Value{ .Float = random.floatNorm(f64) * n.sigma + n.mu };
            },
            .Bernoulli => |b| {
                const v = random.float(f64) < b.p;
                return Value{ .Float = if (v) 1.0 else 0.0 };
            },
        }
    }

    pub fn logProb(self: Distribution, val: Value) f64 {
        const x: f64 = switch (val) {
            .Float => |f| f,
            .Int => |i| @floatFromInt(i),
            .Bool => |b| if (b) 1.0 else 0.0,
            else => std.debug.panic("Invalid type for logProb", .{}),
        };
        switch (self) {
            .Normal => |n| {
                const pi = std.math.pi;
                const part1 = -0.5 * @log(2.0 * pi * n.sigma * n.sigma);
                const diff = x - n.mu;
                const part2 = -(diff * diff) / (2.0 * n.sigma * n.sigma);
                return part1 + part2;
            },
            .Bernoulli => |b| {
                if (x == 1.0) return @log(b.p);
                if (x == 0.0) return @log(1.0 - b.p);
                return -std.math.inf(f64);
            },
        }
    }
};
