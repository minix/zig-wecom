const std = @import("std");
const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
const Client = @import("tardy_http_client");
const json = std.json;

pub const std_options: std.Options = .{ .log_level = .warn };

const Context = struct {
    allocator: std.mem.Allocator,
    url: []const u8 = "WX_URL",
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

    handle_network_result(rt, &future) catch |err| {
        if (isNetworkError(err)) {
            std.debug.print("网络异常: {}\n", .{err});
            return;
        }
        return err;
    };
}

fn handle_network_result( rt: *Runtime, future: *Client.FutureFetchResult, ) !void {
    const result = future.result(rt) catch |err| {
        switch (err) {
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.ConnectionResetByPeer,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.ProtocolFailure,
            error.TemporaryNameServerFailure,
            error.NameServerFailure,
            error.NetworkDown => {
                std.debug.print("网络异常: {}\n", .{err});
                return err;
            },
            else => {
                std.debug.print("请求失败: {}\n", .{err});
                return err;
            },
        }
    };

    if (result.status.class() != .success) {
        // 处理HTTP错误状态
        const status_code = @intFromEnum(result.status);
        std.debug.print("HTTP错误 ({}) - {?s}\n", .{ 
            status_code, 
            result.status.phrase() 
        });
        
        if (status_code >= 500) {
            std.debug.print("服务器错误\n", .{});
        } else if (status_code >= 400) {
            std.debug.print("客户端错误\n", .{});
        }
        
    }
}

fn isNetworkError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ProtocolFailure,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.NetworkDown => true,
        else => false,
    };
}
