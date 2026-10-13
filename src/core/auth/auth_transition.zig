const std = @import("std");
const credentials = @import("credentials.zig");
const model_provider = @import("../config/model_provider.zig");

pub const ProviderSwitchDecision = enum {
    no_change,
    busy,
    prepare,
};

pub const ProviderSwitchIntent = enum {
    manual,
    post_oauth,
};

pub const ProviderSwitchFacts = struct {
    current: model_provider.ProviderId,
    target: model_provider.ProviderId,
    target_credential_ready: bool,
    intent: ProviderSwitchIntent,
    stream_active: bool,
    queued_prompts: usize,
};

pub fn provider_work_busy(stream_active: bool, queued_prompts: usize) bool {
    return stream_active or queued_prompts > 0;
}

pub fn decideProviderSwitch(facts: ProviderSwitchFacts) ProviderSwitchDecision {
    if (facts.intent == .manual and facts.current.eql(facts.target) and facts.target_credential_ready) {
        return .no_change;
    }
    if (provider_work_busy(facts.stream_active, facts.queued_prompts)) return .busy;
    return .prepare;
}

pub const LogoutFacts = struct {
    requested: ?model_provider.ProviderId,
    selected: model_provider.ProviderId,
    active_source: ?credentials.Source,
    available_sources: std.EnumSet(credentials.Source),
};

pub fn decideLogoutProvider(facts: LogoutFacts) model_provider.ProviderId {
    if (facts.requested) |provider| return provider;
    if (facts.selected == .grok or facts.active_source == .grok_subscription) return .grok;
    if (facts.selected == .codex or facts.active_source == .chatgpt_subscription) return .codex;
    const only_grok_login = facts.available_sources.contains(.grok_subscription) and
        !facts.available_sources.contains(.chatgpt_subscription);
    return if (only_grok_login) .grok else .codex;
}

pub fn logoutFallbackProviders(facts: LogoutFacts) [2]?model_provider.ProviderId {
    var candidates: [2]?model_provider.ProviderId = .{ null, null };
    const removed = decideLogoutProvider(facts);
    if (!removed.eql(facts.selected)) return candidates;

    var count: usize = 0;
    for ([_]model_provider.ProviderId{ .codex, .grok }) |provider| {
        if (provider.eql(removed)) continue;
        const available = switch (provider) {
            .codex => facts.available_sources.contains(.chatgpt_subscription),
            .grok => facts.available_sources.contains(.grok_subscription),
            .configured => false,
        };
        if (!available) continue;
        candidates[count] = provider;
        count += 1;
    }
    return candidates;
}

pub const SignInCompletionAction = union(enum) {
    switch_provider: model_provider.ProviderId,
    activate_source: credentials.Source,
};

pub fn signInCompletion(
    provider: model_provider.ProviderId,
    provider_routing_supported: bool,
) SignInCompletionAction {
    return switch (provider) {
        .configured => .{ .switch_provider = provider },
        .codex => if (provider_routing_supported)
            .{ .switch_provider = .codex }
        else
            .{ .activate_source = .chatgpt_subscription },
        .grok => if (provider_routing_supported)
            .{ .switch_provider = .grok }
        else
            .{ .activate_source = .grok_subscription },
    };
}

pub const CredentialAuthorityFacts = struct {
    provider: model_provider.ProviderId,
    source: credentials.Source,
    account_id: ?[]const u8,
};

pub const CredentialChange = enum {
    none,
    secret_only,
    authority,
};

pub fn decideCredentialChange(
    current: CredentialAuthorityFacts,
    candidate: CredentialAuthorityFacts,
    secret_changed: bool,
) CredentialChange {
    if (!current.provider.same_authority(candidate.provider) or
        current.source != candidate.source or
        !optionalBytesEqual(current.account_id, candidate.account_id))
    {
        return .authority;
    }
    return if (secret_changed) .secret_only else .none;
}

pub const AuthReplayFacts = struct {
    authentication_rejected: bool,
    refreshable: bool,
    delivery_safe: bool,
    already_replayed: bool,
};

pub const AuthReplayDecision = enum {
    fail,
    refresh_and_replay,
};

pub fn decideAuthReplay(facts: AuthReplayFacts) AuthReplayDecision {
    if (!facts.authentication_rejected or
        !facts.refreshable or
        !facts.delivery_safe or
        facts.already_replayed)
    {
        return .fail;
    }
    return .refresh_and_replay;
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}
