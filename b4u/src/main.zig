const std = @import("std");
const vaxis = @import("vaxis");
const serial = @import("serial");
const File = std.fs.File;
const Thread = std.Thread;
const Tty = vaxis.Tty;
const Vaxis = vaxis.Vaxis;
const EventLoop = vaxis.Loop(Event);
const Allocator = std.mem.Allocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;

const SensorValue = u10;

// For terminal cleanup
pub const panic = vaxis.panic_handler;
pub const std_options = std.Options{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    const path: [*:0]const u8 = if (std.os.argv.len >= 2) std.os.argv[1] else "/dev/ttyACM0";
    var port = try std.fs.cwd().openFileZ(path, .{ .mode = .read_write });
    defer port.close();

    try serial.configureSerialPort(port, .{ .baud_rate = 115200 });

    // Initialize and run the application
    var app = try B4U.init(allocator, port);
    defer app.deinit();
    try app.run();
}

pub const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    winsize: vaxis.Winsize,
    redraw: void,
    // threshold_update: []SensorValue,
    // values_update: []SensorValue,
};

pub const Sensor = struct {
    pin: ?u5 = null,
    threshold: SensorValue,
    value: SensorValue,
};

pub const B4U = struct {
    allocator: Allocator,
    port: File,
    tty: Tty,
    vx: Vaxis,
    should_quit: bool = false,
    selected_index: usize = 0,
    serial_handler_running: bool = false,

    pub fn init(allocator: Allocator, port: File) !B4U {
        const tty = try Tty.init();
        const vx = try vaxis.init(allocator, .{});
        return .{
            .allocator = allocator,
            .port = port,
            .tty = tty,
            .vx = vx,
        };
    }

    pub fn deinit(self: *B4U) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
    }

    pub fn run(self: *B4U) !void {
        var loop: EventLoop = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();

        // Start the event loop
        try loop.start();
        defer loop.stop();

        try self.vx.enterAltScreen(self.tty.anyWriter());
        defer self.vx.exitAltScreen(self.tty.anyWriter()) catch {};

        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

        const serial_thread = try Thread.spawn(.{ .allocator = self.allocator }, B4U.serialHandler, .{ self, &loop });

        toplevel: while (true) {
            // Block until an event occurs, then handle all pending events
            loop.pollEvent();
            while (loop.tryEvent()) |event| {
                try self.update(event);
                if (self.should_quit) break :toplevel;
            }

            // Redraw our screen and render (buffered)
            self.draw();
            var buffered = self.tty.bufferedWriter();
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }

        serial_thread.join();
    }

    pub fn serialHandler(self: *B4U, loop: *EventLoop) void {
        std.time.sleep(3 * std.time.ns_per_s);
        self.serial_handler_running = true;
        _ = loop.tryPostEvent(.redraw);
        std.time.sleep(2 * std.time.ns_per_s);
        self.serial_handler_running = false;
        _ = loop.tryPostEvent(.redraw);
    }

    pub fn update(self: *B4U, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    self.should_quit = true;
                }
            },
            .key_release => |key| {
                _ = key;
            },
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
            .redraw => {},
        }
    }

    pub fn draw(self: *B4U) void {
        const msg = if (self.serial_handler_running) "Hello, serial!" else "Hello, world!";

        const win = self.vx.window();
        win.clear();

        const child = win.child(.{
            .x_off = win.width / 2 - 7,
            .y_off = win.height / 2 + 1,
            .width = .{ .limit = msg.len },
            .height = .{ .limit = 1 },
        });

        _ = try child.printSegment(.{ .text = msg, .style = .{} }, .{});
    }
};
