const std = @import("std");
const image_attachments = @import("../images/image_attachments.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const compactor = @import("../compactor/compactor.zig");

fn compactionErrorHandled(work: worker_runtime.WorkItem, provenance: ?compaction_activity.ErrorProvenance, err: anyerror) bool {
    const failure = provenance orelse return false;
    if (failure.err != err) return false;
    return switch (work) {
        .prompt => |job| failure.turn_id == job.turn_id,
        .compact_context => |task| failure.turn_id == task.turn_id and task.operation_id == failure.operation_id,
    };
}

fn settleCompactionWorkFailure(worker: *worker_runtime.WorkerRuntime, work: worker_runtime.WorkItem, err: anyerror) void {
    switch (work) {
        .compact_context => |task| if (task.operation_id) |id| {
            worker.settleCompactionActivity(id, compaction_activity.failure(err, .preparation, worker.isCancelRequested()));
        },
        .prompt => {},
    }
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn startWorkerThread(app: *App) !void {
            app.worker_thread = try std.Thread.spawn(.{}, workerThreadMain, .{app});
        }

        pub fn formatToolExecutionError(alloc: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
            const error_detail = detailedErrorSummary(err);
            const details: []const tool_result_errors.Detail = if (error_detail) |detail|
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                    .{ .name = "detail", .value = .{ .string = detail } },
                }
            else
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                };

            return tool_result_errors.toolExecutionFailureJson(alloc, .{
                .tool_name = tool_name,
                .message = if (error_detail != null) "Tool execution failed while parsing or preparing data" else "Tool execution failed",
                .details = details,
                .suggestion = suggestionForError(err),
            });
        }

        fn detailedErrorSummary(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.StreamInterrupted => "provider response ended before completion",
                error.UnexpectedEndOfInput => "incomplete JSON or internal response while parsing data",
                error.SyntaxError => "invalid JSON syntax while parsing data",
                error.MissingField => "required field missing while parsing data",
                error.InvalidEnumTag => "invalid enum value while parsing data",
                error.UnknownField => "unexpected field while parsing data",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                else => null,
            };
        }

        fn suggestionForError(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.UnexpectedEndOfInput, error.SyntaxError => "Check that the tool arguments are valid JSON and retry with corrected input.",
                error.MissingField => "Add the required input field named by the tool schema, then retry.",
                error.InvalidEnumTag, error.UnknownField => "Compare the input fields with the tool schema and retry with supported values.",
                error.ImageTooLarge => "Use a smaller image or reduce the image before retrying.",
                else => null,
            };
        }

        fn formatErrorBody(alloc: std.mem.Allocator, context: []const u8, err: anyerror) ![]u8 {
            switch (err) {
                error.ConnectionSetupTimedOut => return alloc.dupe(u8, "Connection setup timed out after 30 seconds."),
                error.TlsInitializationFailed => return alloc.dupe(u8, "Connection setup failed: TLS could not be initialized."),
                error.ModelImageCapabilityUnavailable => return alloc.dupe(u8, image_attachments.model_image_capability_unavailable_notice),
                else => {},
            }
            if (detailedErrorSummary(err)) |detail| {
                return alloc.print("{s}: {s} ({s})", .{ context, detail, @errorName(err) });
            }

            return alloc.print("{s}: {s}", .{ context, @errorName(err) });
        }

        fn workerThreadMain(app: *App) void {
            workerLoop(app) catch |err| {
                const body = formatErrorBody(std.heap.c_allocator, "worker loop crashed", err) catch return;
                defer std.heap.c_allocator.free(body);
                app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                    .topic = "system",
                    .tone = .@"error",
                    .body = body,
                } }) catch return;
            };
        }

        fn workerLoop(app: *App) !void {
            while (true) {
                const work = (try app.worker.waitAndTakeNextWork(std.heap.c_allocator)) orelse return;

                defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);
                defer app.worker.finishProcessing();
                var failure_provenance: ?compaction_activity.ErrorProvenance = null;
                app.processQueuedWork(work, &failure_provenance) catch |err| {
                    settleCompactionWorkFailure(&app.worker, work, err);
                    if (compactionErrorHandled(work, failure_provenance, err)) {
                        compactor.traceLog(true, "interactive error retained err={s}", .{@errorName(err)});
                    } else if (err != error.RouteRecoveryStopped) {
                        const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                        defer std.heap.c_allocator.free(body);
                        try app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                            .topic = "system",
                            .tone = .@"error",
                            .body = body,
                        } });
                    }
                };
            }
        }
    };
}
