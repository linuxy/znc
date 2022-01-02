const std = @import("std");
const flags = @import("flags.zig");
const builtin = @import("builtin");
const net = std.net;
const os = std.os;
const io = std.io;
const log = std.log.scoped(.znc);

const c = @cImport({
    @cInclude("signal.h");
});

var arg_port: u16 = 0;
var arg_address: [:0]const u8 = undefined;
var arg_udp: bool = false;
var parsed_address: std.net.Address = undefined;
var barrier = Barrier{};

var stdout: std.fs.File.Writer = undefined;
var stdin: std.fs.File.Reader = undefined;

pub const log_level: std.log.Level = .info;

const usage =
    \\znc (zig netcat) a rewrite of the famous networking tool.
    \\
    \\Basic usages
    \\Connect to somewhere: nc [ <options> ] [ -a <address> ] [ -p <port> ] ...
    \\TODO: Listen for inbound: nc -l [ -p <port> ] [ <options> ] [ -a <address> ] ...
    \\(does not work on Windows)
    \\
;

const build_version =
    \\znc (zig netcat) 0.1.0
    \\Copyright (C) 2022 Ian Applegate
    \\
    \\This program comes with NO WARRANTY, to the extent permitted by law.
    \\You may redistribute copies of this program under the terms of
    \\the GNU General Public License.
    \\For more information about these matters, see the file named COPYING.
    \\
;

pub fn main() !void {

    try parseArgs();

    _ = c.signal(c.SIGINT, handle_interrupt);

    defer {
        barrier.stop();
    }

    var buf1: [4096]u8 = undefined;
    var buf2: [4096]u8 = undefined;

    var stream = std.net.tcpConnectToAddress(parsed_address) catch |err| {
        log.warn("unable to connect: {};\n", .{err});
        std.os.exit(1);
    };

    barrier.start();

    var forwardStdin = &(try std.Thread.spawn(.{}, readAndForwardStdin, .{&buf1, &stream}));
    var forwardStream = &(try std.Thread.spawn(.{}, readAndForwardStream, .{&buf2, &stream}));

    forwardStdin.detach();
    forwardStream.detach();

    while(barrier.isRunning()) {
        std.time.sleep(500 * std.time.ns_per_ms);
    }

    return;
}

pub fn readAndForwardStdin(buf: []u8, stream: *std.net.Stream) void {
    stdin = std.io.getStdIn().reader();
    while(barrier.isRunning()) {
        var bytes = stdin.read(buf) catch unreachable;
        if(bytes == -1) {
            break;
        } else {
            _ = stream.write(buf[0..bytes]) catch unreachable;
        }
    }
    return;
}

pub fn readAndForwardStream(buf: []u8, stream: *std.net.Stream) void {
    stdout = std.io.getStdOut().writer();
    while(barrier.isRunning()) {
        var bytes = stream.read(buf) catch unreachable;
        if(bytes == -1) {
            break;
        } else {
            _ = stdout.write(buf[0..bytes]) catch unreachable;
        }
    }
    return;
}

fn handle_interrupt(signal: c_int) callconv(.C) void {
    barrier.stop();
    _ = signal;
}

pub fn parseArgs() anyerror!void {
    var found_port: bool = false;
    var found_address: bool = false;

    const argv: [][*:0]const u8 = os.argv;
    const result = flags.parse(argv[1..], &[_]flags.Flag{
        .{ .name = "--help", .kind = .boolean },
        .{ .name = "-h", .kind = .boolean },
        .{ .name = "--version", .kind = .boolean },
        .{ .name = "-v", .kind = .boolean },
        .{ .name = "-u", .kind = .boolean },
        .{ .name = "--tcp", .kind = .boolean },
        .{ .name = "-t", .kind = .boolean },
        .{ .name = "--udp", .kind = .boolean },
        .{ .name = "-l", .kind = .boolean },
        .{ .name = "-p", .kind = .arg },
        .{ .name = "-s", .kind = .arg },
        .{ .name = "--source", .kind = .arg },
        .{ .name = "-a", .kind = .arg },      
    }) catch {
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    };
    if (result.boolFlag("--help") or result.boolFlag("-h")) {
        try io.getStdOut().writeAll(usage);
        os.exit(0);
    }
    if (result.args.len != 0) {
        std.log.err("unknown option '{s}'", .{result.args[0]});
        try io.getStdErr().writeAll(usage);
        os.exit(1);
    }
    if (result.boolFlag("--version") or result.boolFlag("-v")) {
        try io.getStdOut().writeAll(build_version);
        os.exit(0);
    }
    if (result.argFlag("-a")) |address| {
        if(result.args.len == 0) {
            log.info("Found ip address: {s}", .{address});
            arg_address = std.mem.span(address);
            found_address = true;
        } else {
            try io.getStdErr().writeAll("Invalid argument for -a expected type [u8]\n");
            os.exit(1);
        }
    }
    if (result.argFlag("-p")) |port| {
        const maybe_port = std.fmt.parseInt(u16,  std.mem.span(port), 10) catch null;
        if(maybe_port) |int_port| {
            log.info("Found port address: {}", .{int_port});
            arg_port = int_port;
            found_port = true;
        } else {
            try io.getStdErr().writeAll("Invalid argument for -p expected type [u16]\n");
            os.exit(1);            
        }
    }
    if(found_address or found_port) {
        const arg_con = net.Address.parseIp(arg_address, arg_port) catch {
                try io.getStdErr().writeAll("Invalid address and/or port.\n");
                os.exit(1);        
        };
        log.info("Found valid port & address.", .{});
        parsed_address = arg_con;
    } else {
        if (os.argv.len - 1 == 0) {
            try io.getStdOut().writeAll(usage);
            os.exit(0);
        } else {
            try io.getStdErr().writeAll("Address and/or port not found.\n");
            os.exit(1);            
        }
    }
}

const Barrier = struct {
    state: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),

    fn wait(self: *const Barrier) void {
        while (self.state.load(.Acquire) == 0) {
            std.Thread.Futex.wait(&self.state, 0, null) catch unreachable;
        }
    }

    fn isRunning(self: *const Barrier) bool {
        return self.state.load(.Acquire) == 1;
    }

    fn wake(self: *Barrier, value: u32) void {
        self.state.store(value, .Release);
        std.Thread.Futex.wake(&self.state, std.math.maxInt(u32));
    }

    fn start(self: *Barrier) void {
        self.wake(1);
    }

    fn stop(self: *Barrier) void {
        self.wake(2);
    }
};