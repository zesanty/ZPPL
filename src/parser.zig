const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ValueTag = enum {
    Nil,
    Bool,
    Int,
    Float,
    String,
    Symbol,
    List,
    Closure,
    Distribution,
    Primitive,
};

pub const Value = union(ValueTag) {
    Nil: void,
    Bool: bool,
    Int: i64,
    Float: f64,
    String: []const u8,
    Symbol: []const u8,
    List: []const Value,
    Closure: *const @import("machine.zig").Closure,
    Distribution: @import("machine.zig").Distribution,
    Primitive: *const fn (alloc: Allocator, args: []const Value) anyerror!Value,

    pub fn asFloat(self: Value) !f64 {
        return switch (self) {
            .Float => |f| f,
            .Int => |i| @floatFromInt(i),
            else => error.TypeMismatch,
        };
    }

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Nil => try writer.writeAll("nil"),
            .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .Int => |i| try writer.print("{d}", .{i}),
            .Float => |f| try writer.print("{d}", .{f}),
            .String => |s| try writer.print("\"{s}\"", .{s}),
            .Symbol => |s| try writer.writeAll(s),
            .List => |l| {
                try writer.writeAll("(");
                for (l, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(" ");
                    try item.format(writer);
                }
                try writer.writeAll(")");
            },
            .Closure => try writer.writeAll("<closure>"),
            .Distribution => try writer.writeAll("<dist>"),
            .Primitive => try writer.writeAll("<prim>"),
        }
    }
};

fn tokenize(alloc: Allocator, text: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',') {
            i += 1;
        } else if (c == ';') {
            while (i < text.len and text[i] != '\n') : (i += 1) {}
        } else if (c == '(' or c == ')' or c == '[' or c == ']') {
            const token = if (c == '(' or c == '[') "(" else ")";
            try tokens.append(alloc, token);
            i += 1;
        } else if (c == '"') {
            var j = i + 1;
            while (j < text.len and text[j] != '"') : (j += 1) {
                if (text[j] == '\\' and j + 1 < text.len) j += 1;
            }
            if (j >= text.len) return error.SyntaxError;
            try tokens.append(alloc, text[i .. j + 1]);
            i = j + 1;
        } else {
            var j = i;
            while (j < text.len) : (j += 1) {
                const char = text[j];
                if (char == ' ' or char == '\t' or char == '\n' or char == '\r' or char == ',' or char == '(' or char == ')' or char == '[' or char == ']' or char == ';' or char == '"') {
                    break;
                }
            }
            try tokens.append(alloc, text[i..j]);
            i = j;
        }
    }
    return try tokens.toOwnedSlice(alloc);
}

fn parseAtom(alloc: Allocator, token: []const u8) !Value {
    if (token[0] == '"') {
        const inner = token[1 .. token.len - 1];
        const unescaped = try alloc.dupe(u8, inner);
        return Value{ .String = unescaped };
    }
    if (std.mem.eql(u8, token, "true")) return Value{ .Bool = true };
    if (std.mem.eql(u8, token, "false")) return Value{ .Bool = false };
    if (std.mem.eql(u8, token, "nil")) return Value{ .Nil = {} };
    
    if (std.fmt.parseInt(i64, token, 10)) |val| {
        return Value{ .Int = val };
    } else |_| {}
    
    if (std.fmt.parseFloat(f64, token)) |val| {
        return Value{ .Float = val };
    } else |_| {}

    return Value{ .Symbol = try alloc.dupe(u8, token) };
}

fn readAst(alloc: Allocator, tokens: []const []const u8, pos: *usize) anyerror!Value {
    if (pos.* >= tokens.len) return error.SyntaxError;
    const tok = tokens[pos.*];
    if (std.mem.eql(u8, tok, "(")) {
        var form: std.ArrayList(Value) = .empty;
        defer form.deinit(alloc);
        pos.* += 1;
        while (true) {
            if (pos.* >= tokens.len) return error.SyntaxError;
            if (std.mem.eql(u8, tokens[pos.*], ")")) {
                pos.* += 1;
                return Value{ .List = try form.toOwnedSlice(alloc) };
            }
            const sub = try readAst(alloc, tokens, pos);
            try form.append(alloc, sub);
        }
    }
    if (std.mem.eql(u8, tok, ")")) return error.SyntaxError;
    pos.* += 1;
    return parseAtom(alloc, tok);
}

pub fn parse(alloc: Allocator, text: []const u8) ![]const Value {
    const tokens = try tokenize(alloc, text);
    defer alloc.free(tokens);
    var pos: usize = 0;
    var forms: std.ArrayList(Value) = .empty;
    defer forms.deinit(alloc);
    while (pos < tokens.len) {
        const val = try readAst(alloc, tokens, &pos);
        try forms.append(alloc, val);
    }
    return try forms.toOwnedSlice(alloc);
}

pub fn parseOne(alloc: Allocator, text: []const u8) !Value {
    const tokens = try tokenize(alloc, text);
    defer alloc.free(tokens);
    var pos: usize = 0;
    const val = try readAst(alloc, tokens, &pos);
    if (pos != tokens.len) return error.MultipleFormsNotSupported;
    return val;
}

test "parser - atomic datatypes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val_int = try parseOne(alloc, "123");
    try std.testing.expectEqual(ValueTag.Int, @as(ValueTag, val_int));
    try std.testing.expectEqual(@as(i64, 123), val_int.Int);

    const val_float = try parseOne(alloc, "45.67");
    try std.testing.expectEqual(ValueTag.Float, @as(ValueTag, val_float));
    try std.testing.expectEqual(@as(f64, 45.67), val_float.Float);

    const val_bool = try parseOne(alloc, "true");
    try std.testing.expectEqual(ValueTag.Bool, @as(ValueTag, val_bool));
    try std.testing.expectEqual(true, val_bool.Bool);

    const val_nil = try parseOne(alloc, "nil");
    try std.testing.expectEqual(ValueTag.Nil, @as(ValueTag, val_nil));
}

test "parser - round trip unparsing" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_][]const u8{
        "123",
        "45.67",
        "true",
        "false",
        "nil",
        "foo-bar",
        "\"hello world\"",
        "(+ 1.5 2.0)",
        "(let [x 1.0 y 2.0] (+ x y))",
        "(if true 1.0 0.0)",
        "(let [mu (sample (normal 0.0 1.0))] (observe (normal mu 1.0) 2.3) mu)",
    };

    for (cases) |case| {
        const parsed = try parseOne(alloc, case);
        const printed = try std.fmt.allocPrint(alloc, "{f}", .{parsed});

        const parsed_again = try parseOne(alloc, printed);
        const printed_again = try std.fmt.allocPrint(alloc, "{f}", .{parsed_again});
        
        try std.testing.expectEqualSlices(u8, printed, printed_again);
    }
}
