//! Virtual Machine that runs Python Bytecode blazingly fast

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const BigIntManaged = std.math.big.int.Managed;

const tracer = @import("tracer");
const CodeObject = @import("../compiler/CodeObject.zig");
const Instruction = @import("../compiler/Compiler.zig").Instruction;

const Object = @import("Object.zig");
const Vm = @This();

const builtins = @import("../builtins.zig");

const log = std.log.scoped(.vm);

/// A raw program counter for jumping around.
program_counter: usize,

/// The VM's arena. All allocations during runtime should be made using this.
allocator: Allocator,

/// VM State
is_running: bool,

stack: std.ArrayListUnmanaged(Object) = .{},
scope: std.StringArrayHashMapUnmanaged(Object) = .{},

pub fn init() !Vm {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    return .{
        .allocator = undefined,
        .program_counter = 0,
        .is_running = false,
        .stack = .{},
        .scope = .{},
    };
}

/// Creates an Arena around `alloc` and runs the main object.
pub fn run(
    vm: *Vm,
    alloc: Allocator,
    instructions: []Instruction,
) !void {
    const t = tracer.trace(@src(), "", .{});
    defer t.end();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    vm.allocator = allocator;

    // Setup
    vm.scope = .{};
    vm.stack = .{};

    // Add the builtin functions to the scope.
    inline for (builtins.builtin_fns) |builtin_fn| {
        const name, const fn_ptr = builtin_fn;
        const func_val = try Object.create(
            .zig_function,
            vm.allocator,
            fn_ptr,
        );
        try vm.scope.put(vm.allocator, name, func_val);
    }

    vm.is_running = true;

    while (vm.is_running) {
        const instruction = instructions[vm.program_counter];
        log.debug(
            "Executing Instruction: {} (stacksize={}, pc={}/{}, mem={s})",
            .{
                instruction,
                vm.stack.items.len,
                vm.program_counter,
                instructions.len,
                std.fmt.fmtIntSizeDec(arena.state.end_index),
            },
        );

        vm.program_counter += 1;
        try vm.exec(instruction);
    }
}

fn exec(vm: *Vm, i: Instruction) !void {
    const t = tracer.trace(@src(), "{s}", .{@tagName(i)});
    defer t.end();

    switch (i) {
        .LoadConst => |constant| try vm.execLoadConst(constant),
        .LoadName => |name| try vm.execLoadName(name),
        // .LoadMethod => |name| try vm.execLoadMethod(name),
        .StoreName => |name| try vm.execStoreName(name),
        .ReturnValue => try vm.execReturnValue(),
        .CallFunction => |argc| try vm.execCallFunction(argc),
        // .CallFunctionKW => |argc| try vm.exeCallFunctionKW(argc),
        // .CallMethod => |argc| try vm.execCallMethod(argc),
        .PopTop => try vm.execPopTop(),
        .BuildList => |argc| try vm.execBuildList(argc),
        // .CompareOperation => |compare| try vm.execCompareOperation(compare),
        .BinaryOperation => |operation| try vm.execBinaryOperation(operation),
        // .PopJump => |case| try vm.execPopJump(case),
        // .RotTwo => try vm.execRotTwo(),

        else => std.debug.panic("TODO: exec{s}", .{@tagName(i)}),
    }
}

/// Stores an immediate Constant on the stack.
fn execLoadConst(vm: *Vm, load_const: Instruction.Constant) !void {
    return switch (load_const) {
        .Integer => |int| {
            const big_int = try BigIntManaged.initSet(vm.allocator, int);
            const val = try Object.create(.int, vm.allocator, .{ .int = big_int });
            try vm.stack.append(vm.allocator, val);
        },
        .String => |string| {
            const val = try Object.create(.string, vm.allocator, .{ .string = string });
            try vm.stack.append(vm.allocator, val);
        },
        .Boolean => |boolean| {
            const val = try Object.create(.boolean, vm.allocator, .{ .boolean = boolean });
            try vm.stack.append(vm.allocator, val);
        },
        .None => {
            const val = Object.init(.none);
            try vm.stack.append(vm.allocator, val);
        },
        else => std.debug.panic("TODO: execLoadConst {s}", .{@tagName(load_const)}),
    };
}

fn execLoadName(vm: *Vm, name: []const u8) !void {
    const val = vm.scope.get(name) orelse
        std.debug.panic("couldn't find '{s}' on the scope", .{name});
    try vm.stack.append(vm.allocator, val);
}

fn execStoreName(vm: *Vm, name: []const u8) !void {
    const tos = vm.stack.pop();
    // TODO: don't want to clobber here, make it more controlled.
    // i know i will forget why variables are being overwritten correctly.
    try vm.scope.put(vm.allocator, name, tos);
}

fn execReturnValue(vm: *Vm) !void {
    // TODO: More logic here
    vm.is_running = false;
}

fn execBuildList(vm: *Vm, count: u32) !void {
    const objects = try vm.popNObjects(count);
    const list = std.ArrayListUnmanaged(Object).fromOwnedSlice(objects);

    const val = try Object.create(.list, vm.allocator, list);
    try vm.stack.append(vm.allocator, val);
}

fn execCallFunction(vm: *Vm, argc: usize) !void {
    const args = try vm.popNObjects(argc);

    const func = vm.stack.pop();
    const func_ptr = func.get(.zig_function);

    try @call(.auto, func_ptr.*, .{ vm, args, null });
}

fn execPopTop(vm: *Vm) !void {
    _ = vm.stack.pop();
}

fn execBinaryOperation(vm: *Vm, op: Instruction.BinaryOp) !void {
    const x = vm.stack.pop();
    const y = vm.stack.pop();

    assert(x.tag == .int);
    assert(y.tag == .int);

    const x_int = x.get(.int).int;
    const y_int = y.get(.int).int;

    var result = try BigIntManaged.init(vm.allocator);

    switch (op) {
        .Add => try result.add(&x_int, &y_int),
        .Subtract => try result.sub(&x_int, &y_int),
        .Multiply => try result.mul(&x_int, &y_int),
        // .Divide => try result.div(&rem, &x_int, &y_int),
        else => std.debug.panic("TOOD: execBinaryOperation '{s}'", .{@tagName(op)}),
    }

    const result_val = try Object.create(.int, vm.allocator, .{ .int = result });
    try vm.stack.append(vm.allocator, result_val);
}

/// Pops `n` items off the stack in reverse order and returns them.
fn popNObjects(vm: *Vm, n: usize) ![]Object {
    const objects = try vm.allocator.alloc(Object, n);

    for (0..n) |i| {
        const tos = vm.stack.pop();
        const index = n - i - 1;
        objects[index] = tos;
    }

    return objects;
}
