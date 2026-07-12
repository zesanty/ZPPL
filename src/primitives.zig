const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("parser.zig").Value;

pub fn primAdd(alloc: Allocator, args: []const Value) !Value {
    _ = alloc;
    var sum: f64 = 0;
    for (args) |a| sum += switch (a) {
        .Float => |f| f,
        .Int => |i| @floatFromInt(i),
        else => 0,
    };
    return Value{ .Float = sum };
}

pub fn primSubtract(alloc: Allocator, args: []const Value) !Value {
    _ = alloc;
    var sub: f64 = switch (args[0]) {
        .Float => |f| f,
        .Int => |i| @floatFromInt(i),
        else => 0,
    };
    sub -= switch (args[1]) {
        .Float => |f| f,
        .Int => |i| @floatFromInt(i),
        else => 0,
    };
    return Value{ .Float = sub };
}

pub fn primNormal(alloc: Allocator, args: []const Value) !Value {
    _ = alloc;
    const mu = try args[0].asFloat();
    const sigma = try args[1].asFloat();
    return Value{ .Distribution = .{ .Normal = .{ .mu = mu, .sigma = sigma } } };
}

pub fn primBernoulli(alloc: Allocator, args: []const Value) !Value {
    _ = alloc;
    const p = try args[0].asFloat();
    return Value{ .Distribution = .{ .Bernoulli = .{ .p = p } } };
}

pub fn primMul(alloc: std.mem.Allocator, args: []const Value) !Value {
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
