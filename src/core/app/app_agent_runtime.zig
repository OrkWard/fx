const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const shared_theme = @import("../shared/theme.zig");
const code_highlight = @import("../agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../agent/presentation/code_highlight_languages.zig");
const app_callbacks = @import("app_callbacks.zig");
const host = @import("../hosts/host.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const io_mod = @import("../shared/io.zig");
const permissions = @import("../permissions/permissions.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const session_runtime = @import("../session/session.zig");
const result_store = @import("../session/result_store.zig");
const session_child_store = @import("../session/session_child_store.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const context_contract = @import("../workspace/context_contract.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;

pub fn Runtime(comptime App: type) type {
    return struct {
        const ToolAuthorityView = struct {
            mode: PermissionMode,
            grants: []const PermissionGrant,
            rules: types.PermissionRuleSet,
        };

        fn appAccessScope(app: *const App) ?workspace_access.AccessScope {
            if (comptime @hasDecl(App, "workspaceAccessScope")) {
                return app.workspaceAccessScope();
            }
            return null;
        }

        const TurnWorkspace = struct {
            root: []const u8,
            access_scope: ?workspace_access.AccessScope,
        };

        fn turnWorkspace(app: *const App) TurnWorkspace {
            return .{ .root = app.workspace_root, .access_scope = appAccessScope(app) };
        }

        fn modelVisibleProjectContext(app: *App) []const u8 {
            if (comptime @hasField(App, "context_enabled")) {
                if (!app.context_enabled) return "";
            }
            if (app.worker.active_context_snapshot) |snapshot| return snapshot.modelVisibleBytes();
            return app.context_snapshot.modelVisibleBytes();
        }

        fn childToolContext(root_context: tool_runtime.Context) tool_runtime.Context {
            var child_context = root_context;
            child_context.tracker = null;
            return child_context;
        }

        pub fn toolContext(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                null,
            );
        }

        pub fn toolContextForSubagent(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                .{
                    .mode = admission.permission_mode,
                    .grants = admission.grants,
                    .rules = admission.rules,
                },
            );
        }

        fn toolContextWithAuthority(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            authority: ?ToolAuthorityView,
        ) tool_runtime.Context {
            const workspace = turnWorkspace(app);
            const agent_settings = app.worker.effectiveAgentTurnSettings();
            const permission_snapshot = if (authority) |snapshot|
                worker_runtime.PermissionSnapshot{
                    .mode = snapshot.mode,
                }
            else
                app_permission_runtime.Runtime(App).livePermissionSnapshot(app);
            const permission_grants = if (authority) |snapshot|
                snapshot.grants
            else
                app.permission_engine.grants.items;
            const permission_rules = if (authority) |snapshot|
                snapshot.rules
            else
                app.permission_engine.rules;
            const child_capability =
                if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(app)
                else
                    null;
            const selected_provider = provider_runtime.provider(app);
            const provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet().select(selected_provider).capabilities
            else if (selected_provider == .gateway)
                provider_set.Bundle.Capabilities{ .fx_search = true, .vision_fallback = true }
            else
                provider_set.Bundle.Capabilities{};
            var ctx: tool_runtime.Context = .{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .ignored_list_entries = ignored_list_entries,
                .max_list_entries = max_list_entries,
                .max_read_file_bytes = max_read_file_bytes,
                .max_read_file_lines = max_read_file_lines,
                .max_read_file_line_len = max_read_file_line_len,
                .max_command_output_bytes = max_command_output_bytes,
                .max_tool_result_bytes = agent_settings.max_tool_result_bytes,
                .auto_compact_percent = agent_settings.auto_compact_percent,
                .api_key = app.auth.apiKey() orelse "",
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .gateway_team = app.auth.gatewayTeam(),
                .credential_source = app.auth.credentialSource(),
                .account_id = app.auth.accountId(),
                .provider = selected_provider,
                .provider_capabilities = provider_capabilities,
                .oauth_transport = app.auth.oauthTransport(),
                .secret_store = if (comptime @hasDecl(@TypeOf(app.auth), "secretStore"))
                    app.auth.secretStore()
                else
                    host.unavailable_secret_store,
                .model = provider_runtime.model(app),
                .reviewer_model = if (comptime @hasField(App, "review_model")) app.review_model else "",
                .gateway_retry_count = gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .gateway_models_path = if (comptime @hasField(App, "web_search_models_path")) app.web_search_models_path else "/v1/models",
                .agent_step_limit = app.agent_step_limit,
                .fast_mode = agent_settings.fast_mode,
                .ultrafast_mode = agent_settings.ultrafast_mode,
                .effort = agent_settings.effort,
                .provider_order = if (selected_provider == .gateway) agent_settings.provider_order else &.{},
                .provider_strict = selected_provider == .gateway and agent_settings.provider_strict,
                .first_call_tool_choice = agent_settings.first_call_tool_choice,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry() else .{},
                .subagent_host = if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).subagentHost(app)
                else
                    null,
                .subagent_caller_id = if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).activeSessionId(app)
                else
                    null,
                .permission_mode = permission_snapshot.mode,
                .permission_grants = permission_grants,
                .permission_rules = permission_rules,
                .worker = &app.worker,
                .permission_prompter = tool_admission.workerPrompter(&app.worker),
                .cancel_flag = &app.worker.worker_cancel_requested,
                .session_child_capability = child_capability,
                .terminal_client = if (comptime @hasField(App, "terminal_client"))
                    &app.terminal_client
                else
                    null,
                .managed_executions = if (comptime @hasField(App, "managed_executions"))
                    &app.managed_executions
                else
                    null,
                .ephemeral_command_replay = if (comptime @hasField(App, "managed_executions"))
                    app.managed_executions.replayStore()
                else
                    null,
                .session = &app.session,
                .session_allocator = app.alloc,
                .skills_dir = app.skills.dir,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .context_registry = app.contextRegistry(),
                .output_chunk_ctx = @ptrCast(app),
                .on_output_chunk = app_callbacks.Bindings(App).onCommandOutputChunk,
                .permission_reviewer_provider = if (comptime @hasDecl(App, "permissionReviewerProvider")) app.permissionReviewerProvider() else null,
                .tracker = &app.change_tracker,
                .tool_progress_ctx = @ptrCast(app),
                .on_tool_progress = app_callbacks.Bindings(App).onToolProgress,
                .subagent_status_renderer = app_callbacks.Bindings(App).subagentStatusRenderer(app),
                .lifecycle_view = app.lifecycle_view,
                .lifecycle_scope = lifecycleContext(app).scope,
            };
            if (comptime @hasField(App, "web_fetch_runtime")) {
                ctx.web_fetch_runtime = &app.web_fetch_runtime;
                ctx.web_fetch_artifact_store = app.session.webFetchArtifactStore();
                ctx.web_fetch_artifact_error = app.session.webFetchArtifactError();
                ctx.web_fetch_progress_ctx = @ptrCast(app);
                ctx.on_web_fetch_progress = app_callbacks.Bindings(App).onWebFetchProgress;
            }
            if (comptime @hasField(App, "web_search_runtime")) {
                if (provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = app.auth.apiKey() orelse "",
                        .credential_source = app.auth.credentialSource(),
                        .gateway_team = app.auth.gatewayTeam(),
                        .worker_model = provider_runtime.model(app),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                        .usage = &app.session.usage,
                        .usage_allocator = app.alloc,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
                ctx.web_search_runtime_ready = false;
                ctx.web_search_progress_ctx = @ptrCast(app);
                ctx.on_web_search_progress = app_callbacks.Bindings(App).onWebSearchProgress;
            }
            ctx.model_capability_resolver = app_callbacks.Bindings(App).modelCapabilityResolver(app);
            ctx.model_override_resolver = app_callbacks.Bindings(App).modelOverrideResolver(app);
            return ctx;
        }

        pub fn resolveToolActionDisplayTarget(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return tool_presentation.resolveTerminalDisplayTarget(
                arena,
                ctx.tool_registry,
                ctx.workspace_root,
                ctx.terminal_client,
                ctx.managed_executions,
                call,
            );
        }

        pub fn releaseAgentTerminalLease(
            app: *App,
            session_id: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            return tool_runtime.release_agent_terminal_lease(
                toolContext(
                    app,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                session_id,
            );
        }

        pub fn describeToolAction(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return formatToolAction(ctx, arena, call, display_target, .active, null);
        }

        pub fn describeToolActionCompleted(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return formatToolAction(ctx, arena, call, display_target, .completed, null);
        }

        pub fn describeToolActionDenied(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            label: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return formatToolAction(ctx, arena, call, display_target, .denied, label);
        }

        pub fn requestToolPermissionSync(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            revalidation: ?agent_runtime.LivePermissionRevalidation,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            applyCredentialLease(app, &ctx, review_turn.credential, gateway_retry_count, gateway_chat_url);
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            return if (revalidation) |request| switch (request) {
                .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
                    admission,
                    arena,
                    call,
                    permission_mode,
                    local_grants,
                    action.authority,
                    action.human_approval,
                ),
            } else tool_admission.requestPermissionOutcome(
                admission,
                arena,
                call,
                permission_mode,
                local_grants,
            );
        }

        pub fn requestPreparedFileMutationPermissionSync(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            prepared: *tool_admission.PreparedFileMutationCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = toolContext(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
            );
            applyCredentialLease(app, &ctx, review_turn.credential, gateway_retry_count, gateway_chat_url);
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            return tool_admission.requestPreparedFileMutationPermissionOutcome(
                admission,
                arena,
                call,
                prepared,
                permission_mode,
                local_grants,
            );
        }

        pub fn validateToolCall(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolCallValidationResult {
            return tool_runtime.validateToolCall(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn checkToolAvailability(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            return tool_runtime.checkToolAvailability(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn permissionTargetForCall(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return tool_admission.permissionTargetForCall(ctx.admissionInput(), arena, call);
        }

        pub fn executeToolCall(
            app: *App,
            request: agent_runtime.ToolExecutionRequest,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolExecutionResult {
            var ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            applyCredentialLease(app, &ctx, request.credential, gateway_retry_count, gateway_chat_url);
            ctx.root_user_intent_context = request.root_user_intent_context;
            ctx.root_user_messages = request.root_user_messages;
            ctx.root_user_evidence_complete = request.root_user_evidence_complete;
            ctx.session_grants = request.session_grants;
            ctx.max_tool_result_bytes = request.max_tool_result_bytes;
            return tool_runtime.executeToolCallAuthorized(ctx, request);
        }

        fn applyCredentialLease(
            app: *App,
            ctx: *tool_runtime.Context,
            credential: types.CredentialLease,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) void {
            const credential_secret = credential.secret() orelse return;
            const credential_source = credential.credentialSource();
            ctx.api_key = credential_secret;
            ctx.credential_source = credential_source;
            ctx.account_id = credential.accountId();
            ctx.gateway_team = credential.tenant();
            if (comptime @hasField(App, "web_search_runtime") and @hasField(App, "session")) {
                if (ctx.provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = credential_secret,
                        .credential_source = credential_source,
                        .gateway_team = credential.tenant(),
                        .worker_model = provider_runtime.model(app),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                        .usage = &app.session.usage,
                        .usage_allocator = app.alloc,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
            }
        }

        pub fn appendStaticContextMessage(
            app: *App,
            arena: Allocator,
            project_context: ?[]const u8,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            try app.contextRegistry().appendDefaultStatic(.{
                .project_context = project_context orelse modelVisibleProjectContext(app),
            }, arena, messages);
        }

        pub fn appendTransientRuntimeContextMessage(
            app: *App,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            const permission_snapshot = app_permission_runtime.Runtime(App).livePermissionSnapshot(app);
            const workspace = turnWorkspace(app);
            try app.contextRegistry().appendDefaultTransient(.{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .interactive = true,
                .permission_mode = permission_snapshot.mode,
                .stale_shell_handles = app.session.has_stale_shell_handles,
            }, arena, messages);
        }

        pub fn refreshProjectContext(app: *App, targets: []const context_contract.ApplicableTarget) context_contract.ProviderError!void {
            app.context_snapshot.deinit(app.alloc);
            if (!app.context_enabled) return;

            const workspace = turnWorkspace(app);
            app.context_snapshot = app.contextRegistry().gatherDefaultSnapshot(app.alloc, .{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .targets = targets,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            }) catch |err| {
                debug_trace.logf("context", "gather failed err={s}", .{@errorName(err)});
                return err;
            };
            if (comptime @hasDecl(App, "writeDomainNotice")) {
                for (app.context_snapshot.notices) |notice| {
                    const should_emit = if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice"))
                        try app.session.claimContextNotice(app.alloc, notice)
                    else
                        true;
                    if (should_emit) {
                        const body = try types.renderContextNoticeBody(app.alloc, notice);
                        defer app.alloc.free(body);
                        app.writeDomainNotice(.{
                            .topic = "context",
                            .tone = .warning,
                            .body = body,
                            .visibility = .full_only,
                        }, true) catch return error.WriteFailed;
                    }
                }
            }
        }

        pub fn fetchModelIds(
            app: *App,
            provider: model_catalog.Provider,
            catalog_endpoint: []const u8,
        ) !std.ArrayList([]u8) {
            const result = model_catalog.fetchWithPublicFallback(provider, app.alloc, .{
                .access = app.auth.modelCatalogAccess(),
                .endpoint = catalog_endpoint,
            });
            var catalog = switch (result) {
                .loaded => |loaded| loaded.catalog,
                .failed => |failed| return failed.failure.asError(),
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            return model_catalog.projectModelIds(app.alloc, catalog.items);
        }

        pub fn processQueuedPrompt(
            app: *App,
            queued_job: worker_runtime.QueuedPrompt,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) !void {
            if (failure_provenance) |out| out.* = null;
            var job = queued_job;
            var fresh_history: ?worker_runtime.FreshPromptHistory = null;
            defer if (fresh_history) |*snapshot| snapshot.deinit(std.heap.c_allocator);
            var snapshot_ownership = worker_runtime.ActivePromptSnapshotOwnership.init(job.images);
            app.worker.beginActivePromptSnapshots(&snapshot_ownership);
            if (job.recovery_checkpoint != null) {
                app.worker.preservePromptSnapshots(job.turn_id, job.images);
            }
            defer app.worker.endActivePromptSnapshots(&snapshot_ownership);
            {
                app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                if (app.session_persistence.writable) |*loaded| try loaded.requireWritable();
            }
            if (job.recovery_checkpoint == null) {
                if (try app_session_runtime.Runtime(App).snapshotFreshPromptBoundary(app, std.heap.c_allocator)) |value| {
                    var checkpoint = value;
                    defer checkpoint.deinit(std.heap.c_allocator);
                    fresh_history = try app_callbacks.Bindings(App).prepareFreshPrompt(app, .{
                        .user = .{ .text = job.prompt, .images = job.images },
                        .prior_turn = checkpoint.interruptedTurn(),
                    });
                    job.history = fresh_history.?.history;
                    job.authorized_image_catalog = fresh_history.?.authorized_image_catalog;
                    job.root_user_intent_context = fresh_history.?.root_user_intent_context;
                    job.unversioned_history_count = fresh_history.?.unversioned_history_count;
                }
            }
            app.worker.active_context_snapshot = &job.context_snapshot;
            defer app.worker.active_context_snapshot = null;
            defer if (comptime !@import("builtin").single_threaded) {
                if (app.session_persistence.subagent_host) |child_host| child_host.cancelYielded();
            };
            app.worker.active_prompt_is_root_authority = if (app.session_persistence.writable) |writable|
                writable.external_prompt_origin == .persistent_child and
                    job.recovery_checkpoint == null
            else
                false;
            defer app.worker.active_prompt_is_root_authority = false;
            app.worker.setActiveAgentTurnSettings(job.agent_settings);
            defer app.worker.clearActiveAgentTurnSettings();
            var preflight_context_notices: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer preflight_context_notices.deinit();
            for (job.context_snapshot.notices) |notice| {
                try appendClaimedContextNotice(app, &preflight_context_notices.writer, notice);
            }

            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const explicit_bindings = try std.heap.c_allocator.alloc(skill_invocation.ExplicitBinding, job.skill_bindings.len);
            defer std.heap.c_allocator.free(explicit_bindings);
            for (job.skill_bindings, 0..) |binding, index| {
                explicit_bindings[index] = .{ .name = binding.name, .path = binding.path };
            }
            if (preflight_context_notices.written().len > 0) {
                try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                    .topic = "context",
                    .tone = .warning,
                    .body = preflight_context_notices.written(),
                    .visibility = .full_only,
                });
            }
            var tool_projection = try app.snapshotModelToolProjection(
                std.heap.c_allocator,
                job.permission_mode,
            );
            defer tool_projection.deinit(std.heap.c_allocator);
            const session_child_capability =
                if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(app)
                else
                    null;

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app);
            if (comptime @hasDecl(App, "providerSet")) deps.agent_stream_provider = app.providerSet().select(job.provider).agent_stream_or_unavailable();
            deps.compaction_failure = failure_provenance;
            const semantic_presentation = app_callbacks.Bindings(App).semanticPresentationSink(app);
            const config = buildQueuedPromptConfig(
                app,
                job,
                .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
                explicit_bindings,
                gateway_retry_count,
                gateway_chat_url,
                &tool_projection,
                session_child_capability,
            );
            const process_result = agent_runtime.processAgentPrompt(&app.session.agent, &deps, semantic_presentation, lifecycleContext(app), config, job);
            try process_result;
        }

        pub fn processContextCompaction(
            app: *App,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) anyerror!void {
            if (failure_provenance) |out| out.* = null;
            const operation_id = job.operation_id orelse app.worker.beginCompactionActivity(.manual, job.turn_id);
            app.worker.runCompactionActivity(operation_id, .preparation);
            // Covers early cancellation before compaction starts; acknowledged settlement wins.
            defer if (app.worker.isCancelRequested()) {
                app.worker.settleCompactionActivity(operation_id, .{ .outcome = .cancelled });
            };
            compactWithActivity(app, job, gateway_retry_count, operation_id) catch |err| {
                app.worker.settleCompactionActivity(operation_id, compaction_activity.failure(err, .preparation, app.worker.isCancelRequested()));
                if (failure_provenance) |out| out.* = .{ .operation_id = operation_id, .turn_id = job.turn_id, .err = err };
                return err;
            };
        }

        fn compactWithActivity(
            app: *App,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            operation_id: compaction_activity.OperationId,
        ) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app);
            const provider_capabilities: provider_set.Bundle.Capabilities = if (comptime @hasDecl(App, "providerSet")) blk: {
                const bundle = app.providerSet().select(job.provider);
                deps.agent_stream_provider = bundle.agent_stream_or_unavailable();
                break :blk bundle.capabilities;
            } else .{};
            const capabilities = deps.available_model_capabilities(deps.ctx, job.model);
            const settings = app.worker.effectiveAgentTurnSettings();
            var provider_options = model_capabilities.resolveProviderOptionsForCapabilities(capabilities, settings.effort, settings.fast_mode);
            provider_options.prompt_caching = provider_capabilities.gateway_prompt_caching;
            if (job.provider == .gateway) {
                provider_options.provider_order = settings.provider_order;
                provider_options.provider_strict = settings.provider_strict;
            }
            var summary_model: agent_runtime.CompactorCaller = .{
                .stream_provider = deps.agent_stream_provider,
                .provider = job.provider,
                .model = job.model,
                .api_key = job.api_key,
                .credential_source = job.credential_source,
                .account_id = job.account_id,
                .gateway_team = job.gateway_team,
                .session_id = app_session_runtime.Runtime(App).activeSessionId(app),
                .retry_count = gateway_retry_count,
                .provider_options = provider_options,
                .max_output_tokens = model_capabilities.requestOutputTokens(capabilities),
                .capabilities_context = deps.ctx,
                .capabilities_fn = deps.available_model_capabilities,
                .usage = deps.usage,
                .usage_allocator = deps.usage_allocator,
            };
            const result = agent_runtime.compactContext(arena, &deps, .{
                .operation_id = operation_id,
                .activity_origin = .manual,
                .compactor = .{
                    .history = job.history,
                    .append_messages = session_runtime.appendHistoryChatMessages,
                    .size = agent_runtime.compactionSize(&app.session.agent, capabilities, settings.auto_compact_percent, job.model),
                    .caller = summary_model.caller(),
                    .records = if (app_session_runtime.Runtime(App).childCapability(app)) |capability| result_store.compactorStore(capability) else null,
                    .cancel_flag = &app.worker.worker_cancel_requested,
                    .trace_ctx = .{ .turn_id = job.turn_id },
                },
            }) catch |err| {
                if (err == error.Cancelled and app.worker.worker_cancel_requested.load(.seq_cst)) return;
                return @as(anyerror!void, err);
            };
            if (result == null) app.worker.settleCompactionActivity(operation_id, .{ .outcome = .no_op });
        }

        fn lifecycleContext(app: *App) agent_runtime.LifecycleContext {
            return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .interactive,
                    .workspace_root = app.workspace_root,
                    .session_id = if (comptime @hasField(App, "session_persistence"))
                        app_session_runtime.Runtime(App).activeSessionId(app)
                    else
                        null,
                },
                .outcome_allocator = app.alloc,
            };
        }

        pub fn runSubagentChild(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
            const app: *App = @ptrCast(@alignCast(raw.?));
            const alloc = std.heap.c_allocator;
            var child_projection = app.snapshotSubagentModelToolProjection(
                alloc,
                admission.permission_mode,
                admission.rules,
            ) catch
                return error.OutOfMemory;
            defer child_projection.deinit(alloc);
            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const prompt_policy = app.promptPolicy();
            var tool_context = childToolContext(app.subagentToolContextForAdmission(admission));
            tool_context.managed_executions = turn.managedExecutionRuntime();
            tool_context.ephemeral_command_replay = turn.managedExecutionRuntime().replayStore();
            const providers = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet()
            else
                provider_set.Set{
                    .gateway = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                        .permission_reviewer = tool_context.permission_reviewer_provider,
                    },
                    .codex = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                        .permission_reviewer = tool_context.permission_reviewer_provider,
                    },
                    .grok = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                        .permission_reviewer = tool_context.permission_reviewer_provider,
                    },
                };
            return subagent_agent_adapter.run(.{
                .host = app_session_runtime.Runtime(App).subagentHost(app) orelse
                    return error.ProviderFailed,
                .tool_context = tool_context,
                .provider_set = providers,
                .system_prompt = prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(admission.model),
                .skill_catalog = .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
                .advertised_tool_names = child_projection.advertised_names,
                .advertised_functions = child_projection.advertised_functions,
                .custom_tool_guidance = child_projection.custom_guidance,
                .context_registry = app.contextRegistry(),
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .project_context = modelVisibleProjectContext(app),
                .lifecycle_view = app.lifecycle_view,
            }, turn, message, admission, cancel);
        }

        fn appendClaimedContextNotice(app: *App, writer: *std.Io.Writer, notice: []const u8) !void {
            const should_emit = if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice"))
                try app.session.claimContextNotice(std.heap.c_allocator, notice)
            else
                true;
            if (!should_emit) return;
            if (writer.buffered().len > 0 and !std.mem.endsWith(u8, writer.buffered(), "\n")) {
                try writer.writeByte('\n');
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try writer.writeAll(body);
        }

        fn buildQueuedPromptConfig(
            app: *App,
            job: worker_runtime.QueuedPrompt,
            catalog: skill_invocation.Catalog,
            bindings: []const skill_invocation.ExplicitBinding,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            tool_projection: *const tool_projection_mod.EffectiveToolProjection,
            session_child_capability: ?*session_child_store.SessionChildCapability,
        ) agent_runtime.Config {
            const prompt_policy = app.promptPolicy();
            const workspace = turnWorkspace(app);
            return .{
                .system_prompt = prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(job.model),
                .skill_catalog = catalog,
                .skill_bindings = bindings,
                .gateway_retry_count = gateway_retry_count,
                .recovery_pause_flag = if (comptime @hasField(@TypeOf(app.worker), "worker_recovery_pause_requested"))
                    &app.worker.worker_recovery_pause_requested
                else
                    null,
                .gateway_chat_url = gateway_chat_url,
                .advertised_tool_names = tool_projection.advertised_names,
                .advertised_functions = tool_projection.advertised_functions,
                .provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                    app.providerSet().select(job.provider).capabilities
                else if (job.provider == .gateway)
                    .{ .fx_search = true, .vision_fallback = true }
                else
                    .{},
                .custom_tool_guidance = tool_projection.custom_guidance,
                .agent_step_limit = app.agent_step_limit,
                .max_tool_result_bytes = job.agent_settings.max_tool_result_bytes,
                .auto_compact_percent = job.agent_settings.auto_compact_percent,
                .cancel_flag = &app.worker.worker_cancel_requested,
                .review_enabled = false,
                .fast_mode = job.agent_settings.fast_mode,
                .ultrafast_mode = job.agent_settings.ultrafast_mode,
                .effort = job.agent_settings.effort,
                .provider_order = if (job.provider == .gateway) job.agent_settings.provider_order else &.{},
                .provider_strict = job.provider == .gateway and job.agent_settings.provider_strict,
                .first_call_tool_choice = job.agent_settings.first_call_tool_choice,
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .origin = if (app.session_persistence.writable) |writable|
                    if (writable.external_prompt_origin == .persistent_child) .subagent else .root
                else
                    .root,
                .root_user_messages = if (app.session_persistence.writable) |writable|
                    writable.external_root_user_messages
                else
                    &.{},
                .root_user_evidence_complete = if (app.session_persistence.writable) |writable|
                    writable.external_root_user_evidence_complete
                else
                    false,
                .current_prompt_is_root_authority = app.worker.active_prompt_is_root_authority,
                .session_child_capability = session_child_capability,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            };
        }
    };
}

const ToolActionState = enum { active, completed, denied };

fn formatToolAction(
    ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    display_target: ?[]const u8,
    state: ToolActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, call.name, "web_search") or tool_presentation.isProviderSearchAlias(call.name)) {
        return formatWebSearchAction(arena, call, state, denied_label);
    }
    const spec = ctx.tool_registry.lookup(call.name) orelse
        return formatMissingSpecToolAction(arena, state, denied_label, call.name);
    if (try tool_presentation.formatRunCommandActivity(arena, ctx.tool_registry, ctx.workspace_root, call)) |activity| {
        defer arena.free(activity.detail);
        const label = if (activity.compatibility_tool) |compatibility_tool|
            specLabel(compatibility_tool, state, denied_label)
        else switch (state) {
            .active => "Running",
            .completed => "Ran",
            .denied => denied_label.?,
        };
        return formatCommandActionValue(
            arena,
            label,
            activity.detail,
        );
    }
    if (std.mem.eql(u8, call.name, "write_file") or
        std.mem.eql(u8, call.name, "edit_file"))
    {
        return formatToolActionValue(
            arena,
            specLabel(spec, state, denied_label),
            display_target orelse spec.label_arg_default,
        );
    }
    if (try tool_presentation.subagentAction(arena, call, switch (state) {
        .active => .active,
        .completed => .completed,
        .denied => .{ .stopped = denied_label.? },
    })) |action| {
        defer action.deinit(arena);
        return formatToolActionValue(arena, action.label, action.detail);
    }
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    const value = display_target orelse
        tool_presentation.resolvedSkillName(call, presentation) orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return formatToolActionValue(arena, presentationLabel(presentation, state, denied_label), value);
}

fn formatWebSearchAction(arena: Allocator, call: ToolCall, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };
    const label = switch (state) {
        .active => "Searching",
        .completed => "Searched",
        .denied => denied_label.?,
    };
    return formatToolActionValue(arena, label, try tool_presentation.formatWebSearchActionDetail(arena, args));
}

fn formatMissingSpecToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8, name: []const u8) ![]const u8 {
    return switch (state) {
        .active => formatToolActionValue(arena, "Working", name),
        .completed => formatToolActionValue(arena, "Completed", name),
        .denied => formatToolActionValue(arena, denied_label.?, name),
    };
}

fn formatInvalidArgsToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    return switch (state) {
        .active => arena.print("● Working…\x1b[0m", .{}),
        .completed => formatToolActionValue(arena, "Completed", "tool call"),
        .denied => formatToolActionValue(arena, denied_label.?, "tool call"),
    };
}

fn formatToolActionValue(arena: Allocator, label: []const u8, value: []const u8) ![]const u8 {
    return arena.print("● {s}\x1b[0m {s}{s}\x1b[0m", .{ label, shared_theme.current().tool_stdout_style, value });
}

/// Command rows keep the muted tool-text base and add shell syntax colors for
/// quoted strings, numbers, comments, and keywords.
fn formatCommandActionValue(arena: Allocator, label: []const u8, command: []const u8) ![]const u8 {
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse
        return formatToolActionValue(arena, label, command);
    const highlighted = try code_highlight.highlight(
        arena,
        command,
        profile,
        if (theme.light) .light else .dark,
        theme.tool_stdout_style,
    );
    return arena.print("● {s}\x1b[0m {s}\x1b[0m", .{ label, highlighted });
}

fn specLabel(spec: *const tool_dispatch.Tool, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => spec.action_label,
        .completed => spec.completed_action_label,
        .denied => denied_label.?,
    };
}

fn presentationLabel(presentation: tool_dispatch.CallPresentation, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => presentation.action_label,
        .completed => presentation.completed_action_label,
        .denied => denied_label.?,
    };
}
