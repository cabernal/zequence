const std = @import("std");
const builtin = @import("builtin");

const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const saudio = sokol.audio;
const slog = sokol.log;

const c = @import("cimgui.zig").c;

const StepCount: usize = 16;
const TrackCount: usize = 8;
const TAU: f32 = 6.283185307179586;

const AtomicU32 = std.atomic.Value(u32);

const TrackColor = struct {
    r: u8,
    g: u8,
    b: u8,
};

const track_names = [_][*:0]const u8{
    "Kick",
    "Snare",
    "Clap",
    "Hat C",
    "Hat O",
    "Tom Low",
    "Tom High",
    "Per",
};

const track_colors = [_]TrackColor{
    .{ .r = 235, .g = 116, .b = 71 },
    .{ .r = 83, .g = 179, .b = 238 },
    .{ .r = 242, .g = 164, .b = 77 },
    .{ .r = 159, .g = 225, .b = 116 },
    .{ .r = 87, .g = 209, .b = 181 },
    .{ .r = 170, .g = 134, .b = 246 },
    .{ .r = 220, .g = 123, .b = 222 },
    .{ .r = 248, .g = 92, .b = 142 },
};

const SharedState = struct {
    playing: AtomicU32 = AtomicU32.init(1),
    bpm_x100: AtomicU32 = AtomicU32.init(12200),
    swing_x1000: AtomicU32 = AtomicU32.init(110),
    volume_x1000: AtomicU32 = AtomicU32.init(780),
    current_step: AtomicU32 = AtomicU32.init(0),
    transport_reset: AtomicU32 = AtomicU32.init(0),
    pattern_masks: [TrackCount]AtomicU32 = [_]AtomicU32{AtomicU32.init(0)} ** TrackCount,
};

const AudioState = struct {
    sample_rate: f32 = 44100.0,
    step_index: u32 = 0,
    samples_until_step: f32 = 0.0,
    seen_transport_reset: u32 = 0,
    noise: u32 = 0x1234ABCD,

    kick_amp: f32 = 0.0,
    kick_pitch: f32 = 0.0,
    kick_phase: f32 = 0.0,

    snare_amp: f32 = 0.0,
    snare_tone: f32 = 0.0,
    snare_phase: f32 = 0.0,

    clap_amp: f32 = 0.0,
    clap_time: f32 = 0.0,

    ch_amp: f32 = 0.0,
    oh_amp: f32 = 0.0,
    hat_memory: f32 = 0.0,

    tom_low_amp: f32 = 0.0,
    tom_low_phase: f32 = 0.0,
    tom_high_amp: f32 = 0.0,
    tom_high_phase: f32 = 0.0,

    perc_amp: f32 = 0.0,
    perc_phase_a: f32 = 0.0,
    perc_phase_b: f32 = 0.0,

    kick_decay: f32 = 0.999,
    kick_pitch_decay: f32 = 0.995,
    snare_decay: f32 = 0.99,
    snare_tone_decay: f32 = 0.99,
    clap_decay: f32 = 0.985,
    ch_decay: f32 = 0.98,
    oh_decay: f32 = 0.998,
    tom_decay: f32 = 0.995,
    perc_decay: f32 = 0.995,

    fn setSampleRate(self: *AudioState, new_rate: f32) void {
        self.sample_rate = if (new_rate >= 8000.0) new_rate else 44100.0;
        self.kick_decay = decayCoef(self.sample_rate, 340.0);
        self.kick_pitch_decay = decayCoef(self.sample_rate, 150.0);
        self.snare_decay = decayCoef(self.sample_rate, 180.0);
        self.snare_tone_decay = decayCoef(self.sample_rate, 120.0);
        self.clap_decay = decayCoef(self.sample_rate, 140.0);
        self.ch_decay = decayCoef(self.sample_rate, 45.0);
        self.oh_decay = decayCoef(self.sample_rate, 360.0);
        self.tom_decay = decayCoef(self.sample_rate, 290.0);
        self.perc_decay = decayCoef(self.sample_rate, 180.0);
        self.samples_until_step = 0.0;
    }
};

const AppState = struct {
    shared: SharedState = .{},
    audio: AudioState = .{},
    pass_action: sg.PassAction = .{},
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x8A5D_9B3F_17C2_4E01),
    initialized: bool = false,

    fn init(self: *AppState) void {
        self.pass_action = .{};
        self.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{
                .r = 0.045,
                .g = 0.055,
                .b = 0.07,
                .a = 1.0,
            },
        };

        self.shared.playing.store(1, .release);
        self.shared.bpm_x100.store(12200, .release);
        self.shared.swing_x1000.store(110, .release);
        self.shared.volume_x1000.store(780, .release);
        self.shared.current_step.store(0, .release);
        self.shared.transport_reset.store(0, .release);

        self.resetPatternToDefault();

        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });

        simgui.setup(.{
            .logger = .{ .func = slog.func },
        });
        c.igStyleColorsDark(null);

        saudio.setup(.{
            .num_channels = 2,
            .buffer_frames = 2048,
            .stream_userdata_cb = audioStreamCallback,
            .user_data = self,
            .logger = .{ .func = slog.func },
        });

        const sample_rate = saudio.sampleRate();
        if (sample_rate > 0) {
            self.audio.setSampleRate(@floatFromInt(sample_rate));
        } else {
            self.audio.setSampleRate(44100.0);
        }

        self.initialized = true;
    }

    fn frame(self: *AppState) void {
        if (!self.initialized) return;

        var dt: f32 = @floatCast(sapp.frameDuration());
        if (!(dt > 0.0 and dt < 0.25)) {
            dt = 1.0 / 60.0;
        }

        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = dt,
            .dpi_scale = sapp.dpiScale(),
        });

        self.drawUi();

        sg.beginPass(.{
            .action = self.pass_action,
            .swapchain = sglue.swapchain(),
        });
        simgui.render();
        sg.endPass();
        sg.commit();
    }

    fn cleanup(self: *AppState) void {
        _ = self;
        saudio.shutdown();
        simgui.shutdown();
        sg.shutdown();
    }

    fn handleEvent(self: *AppState, ev: sapp.Event) void {
        _ = simgui.handleEvent(ev);

        switch (ev.type) {
            .KEY_DOWN => {
                if (ev.key_code == .SPACE and !ev.key_repeat) {
                    self.togglePlaying();
                } else if (ev.key_code == .R and !ev.key_repeat) {
                    self.randomizePattern();
                }
            },
            else => {},
        }
    }

    fn togglePlaying(self: *AppState) void {
        const was_playing = self.shared.playing.load(.acquire) != 0;
        self.shared.playing.store(if (was_playing) 0 else 1, .release);
    }

    fn requestTransportReset(self: *AppState) void {
        _ = self.shared.transport_reset.fetchAdd(1, .acq_rel);
    }

    fn clearPattern(self: *AppState) void {
        for (&self.shared.pattern_masks) |*mask| {
            mask.store(0, .release);
        }
    }

    fn resetPatternToDefault(self: *AppState) void {
        const defaults = [_]u32{
            maskFromSteps(&.{ 0, 4, 8, 10, 12 }),
            maskFromSteps(&.{ 4, 12 }),
            maskFromSteps(&.{12}),
            maskFromSteps(&.{ 0, 2, 4, 6, 8, 10, 12, 14 }),
            maskFromSteps(&.{6}),
            maskFromSteps(&.{14}),
            maskFromSteps(&.{15}),
            maskFromSteps(&.{ 3, 11 }),
        };
        for (defaults, 0..) |mask, i| {
            self.shared.pattern_masks[i].store(mask, .release);
        }
    }

    fn randomizePattern(self: *AppState) void {
        const chance = [_]u32{ 78, 36, 22, 72, 18, 15, 11, 20 };
        var rand = self.rng.random();

        for (0..TrackCount) |track| {
            var mask: u32 = 0;
            for (0..StepCount) |step| {
                if (rand.uintLessThan(u32, 100) < chance[track]) {
                    mask |= stepBit(step);
                }
            }
            if (track == 0) {
                mask |= stepBit(0) | stepBit(4) | stepBit(8) | stepBit(12);
            }
            if (track == 1) {
                mask |= stepBit(4) | stepBit(12);
            }
            self.shared.pattern_masks[track].store(mask, .release);
        }
    }

    fn isStepActive(self: *const AppState, track: usize, step: usize) bool {
        return (self.shared.pattern_masks[track].load(.acquire) & stepBit(step)) != 0;
    }

    fn toggleStep(self: *AppState, track: usize, step: usize) void {
        _ = self.shared.pattern_masks[track].fetchXor(stepBit(step), .acq_rel);
    }

    fn handleTransportReset(self: *AppState) void {
        const req = self.shared.transport_reset.load(.acquire);
        if (req == self.audio.seen_transport_reset) return;

        self.audio.seen_transport_reset = req;
        self.audio.step_index = 0;
        self.audio.samples_until_step = 0.0;
        self.shared.current_step.store(0, .release);
    }

    fn triggerTrack(self: *AppState, track_index: usize) void {
        const audio = &self.audio;
        switch (track_index) {
            0 => {
                audio.kick_amp = 1.0;
                audio.kick_pitch = 1.0;
            },
            1 => {
                audio.snare_amp = 1.0;
                audio.snare_tone = 0.7;
            },
            2 => {
                audio.clap_amp = 1.0;
                audio.clap_time = 0.0;
            },
            3 => {
                audio.ch_amp = 1.0;
                audio.oh_amp *= 0.5;
            },
            4 => {
                audio.oh_amp = 1.0;
            },
            5 => {
                audio.tom_low_amp = 1.0;
            },
            6 => {
                audio.tom_high_amp = 1.0;
            },
            7 => {
                audio.perc_amp = 1.0;
            },
            else => {},
        }
    }

    fn triggerCurrentStep(self: *AppState) void {
        const step = self.audio.step_index;
        const bit = @as(u32, 1) << @as(u5, @intCast(step));
        for (0..TrackCount) |track| {
            if ((self.shared.pattern_masks[track].load(.acquire) & bit) != 0) {
                self.triggerTrack(track);
            }
        }

        self.shared.current_step.store(step, .release);
        self.audio.step_index = (step + 1) % @as(u32, StepCount);
        self.audio.samples_until_step = stepDurationSamples(
            self.shared.bpm_x100.load(.acquire),
            self.shared.swing_x1000.load(.acquire),
            self.audio.step_index,
            self.audio.sample_rate,
        );
    }

    fn nextNoise(self: *AppState) f32 {
        var x = self.audio.noise;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.audio.noise = x;
        const n: f32 = @floatFromInt(x & 0xFFFF);
        return (n / 32767.5) - 1.0;
    }

    fn renderSample(self: *AppState) f32 {
        const a = &self.audio;
        var mix: f32 = 0.0;

        if (a.kick_amp > 0.00004) {
            const freq = 45.0 + 170.0 * a.kick_pitch;
            a.kick_phase = wrapPhase(a.kick_phase + (TAU * freq / a.sample_rate));
            mix += @sin(a.kick_phase) * a.kick_amp * 0.95;
            a.kick_amp *= a.kick_decay;
            a.kick_pitch *= a.kick_pitch_decay;
        }

        if (a.snare_amp > 0.00003) {
            const n = self.nextNoise();
            a.snare_phase = wrapPhase(a.snare_phase + (TAU * 185.0 / a.sample_rate));
            mix += n * a.snare_amp * 0.62;
            mix += @sin(a.snare_phase) * a.snare_tone * 0.32;
            a.snare_amp *= a.snare_decay;
            a.snare_tone *= a.snare_tone_decay;
        }

        if (a.clap_amp > 0.00003) {
            const n = self.nextNoise();
            const t = a.clap_time;
            var burst: f32 = 0.1;
            if ((t < 0.011) or (t > 0.021 and t < 0.032) or (t > 0.041 and t < 0.054)) {
                burst = 1.0;
            }
            mix += n * a.clap_amp * burst * 0.58;
            a.clap_amp *= a.clap_decay;
            a.clap_time += 1.0 / a.sample_rate;
        }

        if (a.ch_amp > 0.00003 or a.oh_amp > 0.00003) {
            const n = self.nextNoise();
            const hp = n - a.hat_memory;
            a.hat_memory = n * 0.96;
            mix += hp * (a.ch_amp * 0.28 + a.oh_amp * 0.2);
            a.ch_amp *= a.ch_decay;
            a.oh_amp *= a.oh_decay;
        }

        if (a.tom_low_amp > 0.00003) {
            a.tom_low_phase = wrapPhase(a.tom_low_phase + (TAU * 110.0 / a.sample_rate));
            mix += @sin(a.tom_low_phase) * a.tom_low_amp * 0.52;
            a.tom_low_amp *= a.tom_decay;
        }

        if (a.tom_high_amp > 0.00003) {
            a.tom_high_phase = wrapPhase(a.tom_high_phase + (TAU * 172.0 / a.sample_rate));
            mix += @sin(a.tom_high_phase) * a.tom_high_amp * 0.44;
            a.tom_high_amp *= a.tom_decay;
        }

        if (a.perc_amp > 0.00003) {
            a.perc_phase_a = wrapPhase(a.perc_phase_a + (TAU * 520.0 / a.sample_rate));
            a.perc_phase_b = wrapPhase(a.perc_phase_b + (TAU * 760.0 / a.sample_rate));
            mix += (@sin(a.perc_phase_a) + 0.7 * @sin(a.perc_phase_b)) * a.perc_amp * 0.18;
            a.perc_amp *= a.perc_decay;
        }

        const volume = @as(f32, @floatFromInt(self.shared.volume_x1000.load(.acquire))) / 1000.0;
        mix *= volume;
        mix = mix / (1.0 + @abs(mix));
        return mix;
    }

    fn fillAudio(self: *AppState, buffer: [*c]f32, num_frames: i32, num_channels: i32) void {
        if (num_frames <= 0 or num_channels <= 0) return;

        const channels = num_channels;
        var frame_idx: i32 = 0;
        while (frame_idx < num_frames) : (frame_idx += 1) {
            self.handleTransportReset();

            if (self.shared.playing.load(.acquire) != 0) {
                if (self.audio.samples_until_step <= 0.0) {
                    self.triggerCurrentStep();
                }
                self.audio.samples_until_step -= 1.0;
            }

            const mono = self.renderSample();
            var ch: i32 = 0;
            while (ch < channels) : (ch += 1) {
                const idx: usize = @intCast(frame_idx * channels + ch);
                buffer[idx] = mono;
            }
        }
    }

    fn drawStepCell(self: *AppState, track: usize, step: usize, playhead_step: usize, playing: bool) void {
        const active = self.isStepActive(track, step);
        const is_playhead = playing and step == playhead_step;
        const tc = track_colors[track];

        const base = if (is_playhead)
            (if (active) col32(246, 219, 93, 255) else col32(108, 122, 146, 255))
        else
            (if (active) col32(tc.r, tc.g, tc.b, 238) else col32(52, 56, 66, 255));
        const hover = if (is_playhead)
            (if (active) col32(255, 230, 126, 255) else col32(124, 138, 162, 255))
        else
            (if (active) col32(tc.r, tc.g, tc.b, 255) else col32(64, 69, 80, 255));
        const pressed = if (is_playhead)
            (if (active) col32(227, 196, 68, 255) else col32(91, 103, 124, 255))
        else
            (if (active) col32(tc.r, tc.g, tc.b, 210) else col32(42, 46, 55, 255));

        c.igPushStyleColor_U32(c.ImGuiCol_Button, base);
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, hover);
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonActive, pressed);
        defer c.igPopStyleColor(3);

        c.igPushID_Int(@intCast(track * StepCount + step));
        defer c.igPopID();

        if (c.igButton("##step", v2(24.0, 24.0))) {
            self.toggleStep(track, step);
        }

        if (c.igIsItemHovered(0)) {
            var tip: [64]u8 = undefined;
            const z = std.fmt.bufPrintZ(
                &tip,
                "{s}  step {d}",
                .{ std.mem.span(track_names[track]), step + 1 },
            ) catch return;
            if (c.igBeginTooltip()) {
                c.igTextUnformatted(z.ptr, null);
                c.igEndTooltip();
            }
        }
    }

    fn drawUi(self: *AppState) void {
        c.igSetNextWindowPos(v2(12.0, 12.0), c.ImGuiCond_FirstUseEver, v2(0.0, 0.0));
        c.igSetNextWindowSize(v2(1240.0, 760.0), c.ImGuiCond_FirstUseEver);
        _ = c.igBegin("Zequence", null, c.ImGuiWindowFlags_NoCollapse);
        defer c.igEnd();

        const playing = self.shared.playing.load(.acquire) != 0;
        if (c.igButton(if (playing) "Stop" else "Play", v2(84.0, 0.0))) {
            self.togglePlaying();
        }
        c.igSameLine(0.0, 6.0);
        if (c.igButton("Reset", v2(80.0, 0.0))) {
            self.requestTransportReset();
        }
        c.igSameLine(0.0, 6.0);
        if (c.igButton("Default", v2(86.0, 0.0))) {
            self.resetPatternToDefault();
        }
        c.igSameLine(0.0, 6.0);
        if (c.igButton("Randomize", v2(104.0, 0.0))) {
            self.randomizePattern();
        }
        c.igSameLine(0.0, 6.0);
        if (c.igButton("Clear", v2(76.0, 0.0))) {
            self.clearPattern();
        }

        var bpm: i32 = @intCast(self.shared.bpm_x100.load(.acquire) / 100);
        c.igSetNextItemWidth(190.0);
        if (c.igSliderInt("Tempo (BPM)", &bpm, 60, 200, "%d", 0)) {
            const clamped = std.math.clamp(bpm, 60, 200);
            self.shared.bpm_x100.store(@intCast(clamped * 100), .release);
        }

        var swing: i32 = @intCast(self.shared.swing_x1000.load(.acquire));
        c.igSetNextItemWidth(190.0);
        if (c.igSliderInt("Swing (%)", &swing, 0, 450, "%d%%", 0)) {
            self.shared.swing_x1000.store(@intCast(std.math.clamp(swing, 0, 450)), .release);
        }

        var volume_percent: i32 = @intCast(self.shared.volume_x1000.load(.acquire) / 10);
        c.igSetNextItemWidth(190.0);
        if (c.igSliderInt("Master Volume", &volume_percent, 0, 100, "%d%%", 0)) {
            const clamped = std.math.clamp(volume_percent, 0, 100);
            self.shared.volume_x1000.store(@intCast(clamped * 10), .release);
        }

        const sample_rate = saudio.sampleRate();
        const current_step = @as(usize, @intCast(self.shared.current_step.load(.acquire) % @as(u32, StepCount)));
        uiText("Audio {s} | {d} Hz | Space = Play/Stop | R = Randomize", .{
            if (saudio.isvalid()) "ready" else "unavailable",
            sample_rate,
        });
        uiText("Playhead step: {d}/{d}", .{ current_step + 1, StepCount });
        if (builtin.target.cpu.arch.isWasm() and saudio.suspended()) {
            uiText("Browser audio is suspended until interaction with the page.", .{});
        }

        c.igSeparator();

        const table_flags: c.ImGuiTableFlags =
            c.ImGuiTableFlags_Borders |
            c.ImGuiTableFlags_RowBg |
            c.ImGuiTableFlags_SizingFixedFit;

        if (c.igBeginTable("sequencer-grid", @intCast(StepCount + 1), table_flags, v2(0.0, 0.0), 0.0)) {
            defer c.igEndTable();

            c.igTableSetupColumn("Track", c.ImGuiTableColumnFlags_WidthFixed, 96.0, 0);

            var header_labels: [StepCount][8]u8 = undefined;
            for (0..StepCount) |step| {
                const z = std.fmt.bufPrintZ(&header_labels[step], "{d}", .{step + 1}) catch continue;
                c.igTableSetupColumn(z.ptr, c.ImGuiTableColumnFlags_WidthFixed, 28.0, 0);
            }
            c.igTableHeadersRow();

            for (0..TrackCount) |track| {
                c.igTableNextRow(0, 0.0);
                _ = c.igTableSetColumnIndex(0);
                c.igTextUnformatted(track_names[track], null);

                for (0..StepCount) |step| {
                    _ = c.igTableSetColumnIndex(@intCast(step + 1));
                    self.drawStepCell(track, step, current_step, playing);
                }
            }
        }
    }
};

var app: AppState = .{};

fn decayCoef(sample_rate: f32, millis: f32) f32 {
    const denom = @as(f64, sample_rate) * @as(f64, millis) * 0.001;
    return @floatCast(std.math.exp(-1.0 / denom));
}

fn stepBit(step: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(step));
}

fn maskFromSteps(comptime steps: []const u8) u32 {
    var mask: u32 = 0;
    inline for (steps) |step| {
        mask |= @as(u32, 1) << @as(u5, step);
    }
    return mask;
}

fn stepDurationSamples(bpm_x100: u32, swing_x1000: u32, next_step: u32, sample_rate: f32) f32 {
    const bpm = @as(f32, @floatFromInt(bpm_x100)) / 100.0;
    const swing = @as(f32, @floatFromInt(swing_x1000)) / 1000.0;
    const base = sample_rate * (60.0 / bpm) * 0.25;
    const factor: f32 = if ((next_step & 1) == 0) (1.0 - swing) else (1.0 + swing);
    return @max(1.0, base * factor);
}

fn wrapPhase(phase: f32) f32 {
    if (phase > TAU) return phase - TAU;
    if (phase < 0.0) return phase + TAU;
    return phase;
}

fn v2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

fn col32(r: u8, g: u8, b: u8, a: u8) c.ImU32 {
    return @as(c.ImU32, r) |
        (@as(c.ImU32, g) << 8) |
        (@as(c.ImU32, b) << 16) |
        (@as(c.ImU32, a) << 24);
}

fn uiText(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c.igTextUnformatted(z.ptr, null);
}

fn init() callconv(.c) void {
    app.init();
}

fn frame() callconv(.c) void {
    app.frame();
}

fn cleanup() callconv(.c) void {
    app.cleanup();
}

fn event(ev: [*c]const sapp.Event) callconv(.c) void {
    if (ev == null) return;
    app.handleEvent(ev[0]);
}

fn audioStreamCallback(
    buffer: [*c]f32,
    num_frames: i32,
    num_channels: i32,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ptr = user_data orelse return;
    const state: *AppState = @ptrCast(@alignCast(ptr));
    state.fillAudio(buffer, num_frames, num_channels);
}

fn appDesc() sapp.Desc {
    const is_web = builtin.target.cpu.arch.isWasm();
    return .{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 1280,
        .height = 800,
        .sample_count = 1,
        .window_title = "Zequence",
        .icon = .{ .sokol_default = true },
        .high_dpi = !is_web,
        .html5 = .{
            .canvas_selector = "#canvas",
            .canvas_resize = true,
            .preserve_drawing_buffer = false,
            .premultiplied_alpha = true,
            .ask_leave_site = false,
        },
        .logger = .{ .func = slog.func },
    };
}

pub fn main() void {
    sapp.run(appDesc());
}
