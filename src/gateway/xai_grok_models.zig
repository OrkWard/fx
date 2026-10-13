const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const credentials = @import("../core/auth/credentials.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const versions = @import("../core/gateway/provider_versions.zig");
const version_lookup = @import("provider_versions.zig");

const max_catalog_models: usize = 128;
pub const title_model = "grok-4.5";
const max_model_id_bytes: usize = 256;
pub const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const default_models_endpoint = "https://cli-chat-proxy.grok.com/v1/models";
const default_modalities_endpoint = "https://api.x.ai/v1/language-models";
const e2e_models_endpoint_env = "FX_E2E_XAI_GROK_MODELS_URL";
const e2e_modalities_endpoint_env = "FX_E2E_XAI_GROK_MODALITIES_URL";

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .grok,
    .refresh_interval_ms = versions.refresh_interval_ms,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const request_auth = catalogRequestAuth(input.access) orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    if (request_auth.account_id) |account_id| {
        if (!grok_session.validAccountId(account_id)) {
            return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
        }
    }
    const request_url = modelsUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);
    const modalities_url = modalitiesUrl(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(modalities_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    const version = if (request_auth.include_subscription_headers)
        version_lookup.resolve(alloc, .grok, cancel_flag, deadline) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = catalogFetchFailure(err) };
        }
    else
        null;
    var response = fetchCatalogResponse(
        alloc,
        request_url,
        request_auth.credential,
        request_auth.account_id,
        request_auth.include_subscription_headers,
        version,
        cancel_flag,
        deadline,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogFetchFailure(err) };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    var modalities_response: ?FetchResponse = fetchCatalogResponse(
        alloc,
        modalities_url,
        request_auth.credential,
        null,
        false,
        null,
        cancel_flag,
        deadline,
    ) catch |err| blk: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .{ .failure = catalogFetchFailure(err) };
        debug_trace.logf("catalog", "Grok modality enrichment unavailable err={s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (modalities_response) |*metadata| metadata.deinit(alloc);
    const modalities_json = if (modalities_response) |metadata| blk: {
        if (metadata.status == .ok) break :blk @as(?[]const u8, metadata.body);
        debug_trace.logf("catalog", "Grok modality enrichment unavailable status={d}", .{@backingInt(metadata.status)});
        break :blk null;
    } else null;
    return catalogFromBodies(alloc, response.body, modalities_json);
}

/// The catalog from the subscription proxy's model list and, when available,
/// xAI's modality metadata. The result owns its catalog.
pub fn catalogFromBodies(
    alloc: std.mem.Allocator,
    subscription_json: []const u8,
    modalities_json: ?[]const u8,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const catalog = parseCatalog(alloc, subscription_json, modalities_json) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const CatalogRequestAuth = struct {
    credential: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    include_subscription_headers: bool = false,
};

fn catalogRequestAuth(access: credentials.CatalogAccess) ?CatalogRequestAuth {
    return switch (access) {
        .host_managed => .{},
        .public_only => null,
        .authenticated => |authenticated| if (authenticated.source == .grok_subscription and
            authenticated.account_id != null)
            .{
                .credential = authenticated.credential,
                .account_id = authenticated.account_id,
                .include_subscription_headers = true,
            }
        else
            null,
    };
}

fn catalogFetchFailure(err: anyerror) model_catalog.Failure {
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (err == error.GrokModelCatalogTooLarge) return .{ .category = .malformed_response };
    return .{ .category = .transport, .retryable = true };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: ?[]const u8,
    account_id: ?[]const u8,
    include_subscription_headers: bool,
    client_version: ?versions.Version = null,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var auth_header: ?[]u8 = null;
        defer if (auth_header) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = gateway_client.user_agent },
            .accept_encoding = .omit,
        };
        if (self.credential) |credential| {
            auth_header = try self.alloc.print("Bearer {s}", .{credential});
            headers.authorization = .{ .override = auth_header.? };
        }
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        var extra_headers_buffer: [5]std.http.Header = undefined;
        var extra_headers_len: usize = 0;
        extra_headers_buffer[extra_headers_len] = .{ .name = "accept", .value = "application/json" };
        extra_headers_len += 1;
        if (self.include_subscription_headers) {
            extra_headers_buffer[extra_headers_len] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
            extra_headers_len += 1;
        }
        if (self.account_id) |account_id| {
            extra_headers_buffer[extra_headers_len] = .{ .name = "x-userid", .value = account_id };
            extra_headers_len += 1;
        }
        if (self.client_version) |*version| {
            extra_headers_buffer[extra_headers_len] = .{ .name = "x-grok-client-version", .value = version.slice() };
            extra_headers_len += 1;
            extra_headers_buffer[extra_headers_len] = .{ .name = "x-grok-client-identifier", .value = "fx" };
            extra_headers_len += 1;
        }
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = headers,
            .extra_headers = extra_headers_buffer[0..extra_headers_len],
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.GrokModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        try validateCatalogBodySize(body.len);
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetchCatalogResponse(
    alloc: std.mem.Allocator,
    url: []const u8,
    credential: ?[]const u8,
    account_id: ?[]const u8,
    include_subscription_headers: bool,
    client_version: ?versions.Version,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !FetchResponse {
    var operation = FetchOperation{
        .alloc = alloc,
        .url = url,
        .credential = credential,
        .account_id = account_id,
        .include_subscription_headers = include_subscription_headers,
        .client_version = client_version,
    };
    return gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

/// The subscription model list, or a loopback test endpoint. Caller owns it.
pub fn modelsUrl(alloc: std.mem.Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_models_endpoint_env) orelse default_models_endpoint;
    if (io_mod.getenv(e2e_models_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(base)) {
        return error.InvalidE2EGrokModelsEndpoint;
    }
    return alloc.dupe(u8, base);
}

/// xAI's modality metadata, or a loopback test endpoint. Caller owns it.
pub fn modalitiesUrl(alloc: std.mem.Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_modalities_endpoint_env) orelse default_modalities_endpoint;
    if (io_mod.getenv(e2e_modalities_endpoint_env) != null and !gateway_client.isLoopbackHttpUrl(base)) {
        return error.InvalidE2EGrokModalitiesEndpoint;
    }
    return alloc.dupe(u8, base);
}

fn parseCatalog(
    alloc: std.mem.Allocator,
    subscription_json: []const u8,
    modalities_json: ?[]const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var subscription = try std.json.parseFromSlice(std.json.Value, alloc, subscription_json, .{});
    defer subscription.deinit();
    if (subscription.value != .object) return error.InvalidGrokModelCatalog;
    const subscription_models = subscription.value.object.get("data") orelse
        return error.InvalidGrokModelCatalog;
    if (subscription_models != .array) return error.InvalidGrokModelCatalog;
    try validateCatalogModelCount(subscription_models.array.items.len);

    var modalities: ?std.json.Parsed(std.json.Value) = if (modalities_json) |json|
        parseModalities(alloc, json) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("catalog", "Grok modality enrichment invalid err={s}", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    defer if (modalities) |*metadata| metadata.deinit();
    const modality_models: []const std.json.Value = if (modalities) |metadata|
        metadata.value.object.get("models").?.array.items
    else
        &.{};

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (subscription_models.array.items) |value| {
        if (value != .object) return error.InvalidGrokModelCatalog;
        const object = value.object;
        const api_backend = try requiredString(object, "api_backend");
        if (!std.mem.eql(u8, api_backend, "responses")) continue;
        const raw_id = try requiredString(object, "model");
        try validateModelId(raw_id);
        const modality_object = findModalityModel(modality_models, raw_id);

        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        const supports_reasoning = try requiredBool(object, "supports_reasoning_effort");
        try appendProviderReasoningEfforts(alloc, &reasoning_efforts, object);
        if (supports_reasoning != (reasoning_efforts.items.len > 0)) {
            return error.InvalidGrokModelCatalog;
        }
        const context_window = try requiredPositiveU32(object, "context_window");
        const max_output_tokens = try optionalPositiveU32(object, "max_completion_tokens");
        const has_vision = if (modality_object) |metadata|
            try stringArrayContains(metadata, "input_modalities", "image")
        else
            false;

        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = supports_reasoning,
            .reasoning_efforts = reasoning_efforts,
            // xAI accepts service_tier "priority" endpoint-wide on the
            // subscription proxy, so every catalog model offers Fast mode.
            .supports_fast_mode = true,
            .has_vision = has_vision,
            .has_file_input = has_vision,
            .has_implicit_caching = true,
            .context_window = context_window,
            .max_tokens = max_output_tokens,
        });
    }
    return catalog;
}

fn appendProviderReasoningEfforts(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    object: std.json.ObjectMap,
) !void {
    const value = object.get("reasoning_efforts") orelse return error.InvalidGrokModelCatalog;
    if (value != .array or value.array.items.len > types.ReasoningEffort.max_options) {
        return error.InvalidGrokModelCatalog;
    }
    for (value.array.items) |entry| {
        if (entry != .object) return error.InvalidGrokModelCatalog;
        const raw_effort = try requiredString(entry.object, "value");
        const effort = types.ReasoningEffort.parse(raw_effort) orelse
            return error.InvalidGrokModelCatalog;
        if (effort.isDefault()) return error.InvalidGrokModelCatalog;
        for (out.items) |existing| {
            if (existing.eql(effort)) return error.InvalidGrokModelCatalog;
        }
        try out.append(alloc, effort);
    }
}

/// Returns owned parsed metadata; the caller releases it with deinit.
fn parseModalities(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokModelCatalog;
    const models = parsed.value.object.get("models") orelse return error.InvalidGrokModelCatalog;
    if (models != .array) return error.InvalidGrokModelCatalog;
    try validateCatalogModelCount(models.array.items.len);
    for (models.array.items) |value| {
        if (value != .object) return error.InvalidGrokModelCatalog;
        try validateModelId(try requiredString(value.object, "id"));
        _ = try stringArrayContains(value.object, "input_modalities", "image");
    }
    return parsed;
}

fn findModalityModel(models: []const std.json.Value, model_id: []const u8) ?std.json.ObjectMap {
    for (models) |value| {
        const candidate = value.object.get("id").?.string;
        if (std.mem.eql(u8, candidate, model_id)) return value.object;
    }
    return null;
}

fn stringArrayContains(
    object: std.json.ObjectMap,
    key: []const u8,
    expected: []const u8,
) !bool {
    const value = object.get(key) orelse return false;
    if (value != .array or value.array.items.len > 32) return error.InvalidGrokModelCatalog;
    var found = false;
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidGrokModelCatalog;
        found = found or std.mem.eql(u8, entry.string, expected);
    }
    return found;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidGrokModelCatalog;
    if (value != .string or value.string.len == 0) return error.InvalidGrokModelCatalog;
    return value.string;
}

fn requiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidGrokModelCatalog;
    if (value != .bool) return error.InvalidGrokModelCatalog;
    return value.bool;
}

fn requiredPositiveU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return error.InvalidGrokModelCatalog;
    if (value != .integer or value.integer <= 0) return error.InvalidGrokModelCatalog;
    return std.math.cast(u32, value.integer) orelse error.InvalidGrokModelCatalog;
}

fn optionalPositiveU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return 0;
    if (value == .null) return 0;
    if (value != .integer or value.integer <= 0) return error.InvalidGrokModelCatalog;
    return std.math.cast(u32, value.integer) orelse error.InvalidGrokModelCatalog;
}

fn validateModelId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.InvalidGrokModelCatalog;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidGrokModelCatalog;
    }
}

fn validateCatalogBodySize(size: usize) !void {
    if (size > max_catalog_bytes) return error.GrokModelCatalogTooLarge;
}

fn validateCatalogModelCount(count: usize) !void {
    if (count > max_catalog_models) return error.InvalidGrokModelCatalog;
}
