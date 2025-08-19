const std = @import("std");
const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
const Client = @import("tardy_http_client");
const json = std.json;

pub const std_options: std.Options = .{ .log_level = .warn };

const Context = struct {
    allocator: std.mem.Allocator,
    //url: []const u8 = "WECOM_URL",
    content: []const u8,
};

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <message> [url]\n", .{args[0]});
        std.debug.print("Example: {s} \"Hello, World!\"\n", .{args[0]});
        return error.MissingArguments;
    }

    var context = Context{ .allocator = gpa, .content = args[1], };

    if (args.len >= 3) context.url = args[2];

    var tardy = try  Tardy.init(gpa, .{ .threading = .single });
    defer tardy.deinit();

    try tardy.entry(
        &context, 
        struct {
            fn start(rt: *Runtime, c: *Context) !void {
                try rt.spawn(.{rt, c}, main_frame, 1024 * 32);
            }
        }.start,
    );
}

fn main_frame(rt: *Runtime, context: *Context) !void {
    var client: Client = .{ .allocator = context.allocator };
    defer client.deinit();
    var resp: std.ArrayList(u8) = .init(context.allocator);
    defer resp.deinit();

    var future: Client.FutureFetchResult = .{};

    const Content = struct {
        content: []const u8,
    };

    const Payload = struct {
        msgtype: []const u8 = "markdown",
        markdown: Content,
    };

    var payload_body = std.ArrayList(u8).init(context.allocator);
    defer payload_body.deinit();

    const payload = Payload{ .markdown = .{ .content = context.content }};
    try json.stringify(payload, .{}, payload_body.writer());

    client.fetch(rt, &future, .{
        .method = .POST,
        .payload = payload_body.items,
        .location = .{ .url = context.url },
        .response_storage = .{ .dynamic = &resp },
        .retry_attempts = 3, // Default is 0 retries.
        .retry_delay = 250, // Default is 500 milliseconds,
        .retry_exponential_backoff_base = 2.0, // Default is 2.0
        .headers = .{ .content_type = .{ .override = "application/json"} },
    }) catch |err| {
        std.debug.print("Error scheduling fetch: {}\n", .{err});
        try future.setCancelled();
    };

    const result = future.result(rt) catch |err| {
        std.debug.print("Fetch error: {}\n", .{err});
        return;
    };

    if (result.status.class() == .success) {
        //std.debug.print("Fetch status: {} - {?s}\n", .{ @intFromEnum(result.status), result.status.phrase() });
        //std.debug.print("Retry count: {}\n", .{result.retry_count});
        if (result.retry_status) |retry_status| std.debug.print("Retry status: {} {?s}\n", .{ @intFromEnum(retry_status), retry_status.phrase() });
        if (result.retry_error) |retry_err| std.debug.print("Retry error: {}\n", .{retry_err});
        //std.debug.print("Body:\n\n{s}\n\n", .{resp.items});
    } else {
        std.debug.print("Fetch Failed with status: {} - {?s}\n", .{ @intFromEnum(result.status), result.status.phrase() });
    } 
}

