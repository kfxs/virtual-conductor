"""
GUI — Dear ImGui interface for Virtual Conductor.
"""

import math
import os

import cv2
import glfw
import imgui
import imgui.internal
from imgui.integrations.glfw import GlfwRenderer
import OpenGL.GL as gl

from gesture_collector import GestureCollector
from chuck_controller import ChuckController
from osc_controller import OscController
from midi_input import MidiListener
import routing_config

# Strength of the optional per-param "Exp" feel curve (normalized exponential
# y = (e^(k·x) − 1)/(e^k − 1)). Higher k = stronger bend. Tune by ear.
EXP_K = 2.0

# Every window the app opens, grouped for the Windows menu. The titles must
# match the imgui.begin() calls exactly — that string is how a window is
# identified, and how the menu focuses it. Performance panels first, since
# they're the ones being reached for mid-session.
WINDOW_GROUPS = [
    ("Performance", ["Live Input", "Virtual Ensemble", "Send FX", "ChucK"]),
    ("Setup", ["Camera Feed", "Tracking", "Gestures", "Configuration"]),
]
WINDOW_TITLES = [title for _group, titles in WINDOW_GROUPS for title in titles]


class ConductorGUI:
    def __init__(self, width=1100, height=700, title="Virtual Conductor"):
        # --- GLFW + ImGui Init ---
        if not glfw.init():
            raise RuntimeError("Failed to initialize GLFW")

        self.window = glfw.create_window(width, height, title, None, None)
        if not self.window:
            glfw.terminate()
            raise RuntimeError("Failed to create GLFW window")

        glfw.make_context_current(self.window)
        glfw.swap_interval(1)

        imgui.create_context()
        # Keep ImGui's auto-saved window layout in config/ too, so it doesn't
        # litter the project root like the other persisted state.
        os.makedirs(routing_config.CONFIG_DIR, exist_ok=True)
        # Keep the io wrapper alive for the app's lifetime: pyimgui parks the C
        # string's backing bytes on the wrapper (_keep_ini_alive), and get_io()
        # returns a fresh wrapper each call. Setting it on a throwaway get_io()
        # lets those bytes get GC'd, dangling IniFilename so ImGui never saves.
        self.io = imgui.get_io()
        self._ini_path = os.path.join(routing_config.CONFIG_DIR, "imgui.ini")
        self.io.ini_file_name = self._ini_path
        self.impl = GlfwRenderer(self.window)

        # --- Video Texture ---
        self.video_texture = self._create_texture()

        # --- Tracking State ---
        self.active_face = True
        self.active_hands = True
        self.active_pose = True

        # --- OSC State ---
        self.osc_enabled = True
        self.osc_ip_buf = "127.0.0.1"
        self.osc_port_buf = "8000"

        # --- Gesture Collection State ---
        self.gesture_collector = GestureCollector()
        self.gesture_label_buf = ""
        self.gesture_train_msg = ""
        self._tracker_recognizer = None

        # --- ChucK ---
        self.chuck = ChuckController()

        # --- Routing State ---
        # Python owns all routing: per param it holds the mode (slider/landmark),
        # the slider position, and the chosen landmark, then sends one resolved
        # value to ChucK live over OSC. Everything persists in routing_state.
        self.routing_state = routing_config.load_state()

        # Input source selection ("fake-theorbo" or "mic"), persisted separately
        # from the per-param routing state.
        self.input_source = routing_config.load_input_source()

        # Which windows are shown, toggled from the Windows menu. Persisted so a
        # layout pared down for a performance survives a restart.
        self.window_visible = routing_config.load_window_visibility(WINDOW_TITLES)

        # Last value seen for every landmark, updated each frame from the tracker.
        # Held between frames so a param freezes (rather than snapping to 0) when
        # its hand leaves view. Seeded to a neutral pose like ChucK used to.
        self.latest_landmarks = {
            lm: (0.0 if lm.endswith("_z") else 0.5)
            for lm in routing_config.LANDMARKS
        }

        # OSC client for the resolved per-param values ChucK plays.
        self.osc_ctrl = OscController(
            self.osc_ip_buf,
            int(self.osc_port_buf) if self.osc_port_buf.isdigit() else 8000,
        )

        # --- MIDI Input ---
        # Infrastructure only for now: pick a connected device and watch its
        # incoming messages in the monitor. Mapping MIDI to ChucK/params comes
        # later via self.midi.on_message. The device list is re-scanned on
        # startup and on the panel's Refresh button, not every frame.
        self.midi = MidiListener()
        self.midi_ports = MidiListener.available_ports()
        saved_port = routing_config.load_midi_port()
        # Only reopen the saved device if it's actually plugged in right now;
        # otherwise fall back to None (it was unplugged since last session).
        if saved_port != "None" and saved_port in self.midi_ports:
            self.midi.select(saved_port)
        self.midi_port_index = (
            self.midi_ports.index(self.midi.selected)
            if self.midi.selected in self.midi_ports else 0
        )

        # Burst trigger MIDI-learn: the learned control (which pad fires the
        # burst), restored from disk, plus a one-shot flag set while waiting to
        # capture the next pad press. The mido callback (background thread) reads
        # these and either records the binding or fires the burst.
        self.burst_midi_binding = routing_config.load_burst_binding()
        self._midi_learn_burst = False

        # Aliased-shimmer "collect" gate: held = 1, released = 0. Two sources can
        # hold it open — the GUI button (mouse held) and a learned MIDI pad
        # (note-on..note-off) — so we track each and the gate is open if either
        # is. The combined edge is what we send on OSC, so it only fires on a real
        # open/close, never every frame.
        self.collect_midi_binding = routing_config.load_collect_binding()
        self._midi_learn_collect = False
        self._collect_gate_mouse = False
        self._collect_gate_midi = False
        self._collect_gate_open = False

        # Aliased-shimmer "clear" trigger: one-shot, like the burst Fire — its
        # learned pad fires the clear on its onset.
        self.clear_midi_binding = routing_config.load_clear_binding()
        self._midi_learn_clear = False

        self.midi.on_message = self._on_midi_message

    @staticmethod
    def _begin_disabled(disabled):
        """Grey out and make non-interactive everything until _end_disabled.
        pyimgui 2.0 has no begin_disabled(), so we use the internal item flag."""
        if disabled:
            imgui.internal.push_item_flag(imgui.internal.ITEM_DISABLED, True)
            imgui.push_style_var(imgui.STYLE_ALPHA, imgui.get_style().alpha * 0.5)

    @staticmethod
    def _end_disabled(disabled):
        if disabled:
            imgui.pop_style_var()
            imgui.internal.pop_item_flag()

    def _send_routing_osc(self):
        """Resolve each param to a single value and push it to ChucK on
        /param/<module>/<param>. Sent every frame: idempotent and cheap, so it
        auto-resyncs whenever the VM (re)starts."""
        if not self.osc_enabled:
            return
        # Contract: ChucK maps 0 -> param minimum, 1 -> maximum, no inversion.
        # All axis flips happen here so the value on the wire is always normalized.
        for module, params in routing_config.MODULE_PARAMS.items():
            for param, _default in params:
                st = self.routing_state[module][param]
                if st["mode"] == "landmark":
                    raw = self.latest_landmarks.get(st["landmark"], 0.5)
                    # Invert FIRST (fix the axis direction), then range on the
                    # corrected signal. This keeps Set Min/Max semantic: lo always
                    # maps to 0 (param min), hi to 1 (max). Captures live in this
                    # corrected space, so the range resets when invert toggles.
                    r = (1.0 - raw) if st["invert"] else raw
                    span = st["hi"] - st["lo"]
                    if abs(span) > 1e-6:
                        value = max(0.0, min(1.0, (r - st["lo"]) / span))
                    else:
                        value = 0.0
                else:
                    value = float(st["slider"])   # slider already reads low→high
                if st["exp"]:
                    # Feel knob: bend the final 0..1 through a normalized exp curve
                    # (same for slider and landmark). ChucK still maps linearly.
                    value = (math.exp(EXP_K * value) - 1.0) / (math.exp(EXP_K) - 1.0)
                self.osc_ctrl.send_value(f"/param/{module}/{param}", value)
        # Input source select: 0 = fake-theorbo, 1 = mic. Sent every frame like
        # the params, so it auto-resyncs whenever the VM (re)starts.
        self.osc_ctrl.send_value(
            "/param/input/source", 1.0 if self.input_source == "mic" else 0.0
        )

    def _begin_window(self, title):
        """Open a window unless it's been hidden from the Windows menu.

        Returns True if it was opened — the caller then draws its contents and
        calls imgui.end(). Returns False if hidden, in which case the caller must
        skip both."""
        if not self.window_visible.get(title, True):
            return False
        imgui.begin(title)
        return True

    def _render_main_menu_bar(self):
        """Top menu bar. Each Windows entry is a checkbox that shows/hides the
        window, plus its name, which pulls it to the front (and un-hides it if it
        was off). With this many panels they overlap, and dragging them apart
        every session is worse than a menu.

        Neither action moves or resizes anything, so the layout imgui.ini
        remembers stays exactly as the user arranged it."""
        if not imgui.begin_main_menu_bar():
            return
        visibility_changed = False
        if imgui.begin_menu("Windows", True):
            for i, (group, titles) in enumerate(WINDOW_GROUPS):
                if i:
                    imgui.separator()
                imgui.text_disabled(group)
                for title in titles:
                    shown = self.window_visible.get(title, True)
                    # Checkbox toggles visibility; the name beside it focuses.
                    changed, shown = imgui.checkbox(f"##show_{title}", shown)
                    if changed:
                        self.window_visible[title] = shown
                        visibility_changed = True
                    imgui.same_line()
                    if imgui.menu_item(title)[0]:
                        if not self.window_visible.get(title, True):
                            self.window_visible[title] = True
                            visibility_changed = True
                        imgui.set_window_focus_labeled(title)
            imgui.end_menu()
        imgui.end_main_menu_bar()

        if visibility_changed:
            routing_config.save_window_visibility(self.window_visible)

    def _render_instrument_windows(self):
        """Three windows, split by what each thing actually does:

          Live Input        — the player's own instrument coming in
          Virtual Ensemble  — everything that plays alongside the performer
          Send FX           — the shared delay/reverb buses the rest send into

        Live Input and the fx buses are core shreds, so they show whenever the
        VM is up; ensemble modules appear only once added to the VM.
        """
        vm = self.chuck.vm_running
        params_of = routing_config.MODULE_PARAMS
        core = routing_config.CORE_MODULES
        send_fx = routing_config.SEND_FX_MODULES

        input_entries = (
            [("input", params_of["input"])] if vm and "input" in params_of else []
        )
        fx_entries = (
            [(m, params_of[m]) for m in send_fx if m in params_of] if vm else []
        )
        # MODULE_PARAMS keys are lowercase ("synth"); ChucK effect names are
        # capitalized ("Synth"). burst-trigger is appended last so its Fire
        # button sits at the bottom of the ensemble.
        ensemble_entries = [
            (module, params)
            for module, params in params_of.items()
            if module not in core
            and module != "burst-trigger"
            and self.chuck.is_active(module.capitalize())
        ]
        if self.chuck.is_active("Burst-trigger"):
            ensemble_entries.append(
                ("burst-trigger", params_of.get("burst-trigger", []))
            )

        state_changed = False
        # The Live Input window holds a single section named after the window
        # itself, so it skips the collapsing header it would only duplicate.
        if self._render_module_window(
            "Live Input", input_entries,
            "Start the ChucK VM to control the input.",
            headers=False,
        ):
            state_changed = True
        if self._render_module_window(
            "Virtual Ensemble", ensemble_entries, "No ensemble modules active."
        ):
            state_changed = True
        if self._render_module_window(
            "Send FX", fx_entries, "Start the ChucK VM to control the send FX."
        ):
            state_changed = True

        if state_changed:
            routing_config.save_state(self.routing_state)

        # Push each param's resolved value (slider or landmark) to ChucK.
        self._send_routing_osc()

    def _render_module_window(self, title, entries, empty_text, headers=True):
        """Render one window holding a collapsible section per entry.
        Returns True if any routing value changed (so it gets persisted)."""
        state_changed = False

        if not self._begin_window(title):
            return False
        if not entries:
            imgui.text_disabled(empty_text)
        else:
            for module, params in entries:
                if headers:
                    # The triangle on a collapsing header minimizes/expands the
                    # section.
                    label = module.capitalize()
                    header = imgui.collapsing_header(
                        label, flags=imgui.TREE_NODE_DEFAULT_OPEN
                    )
                    expanded = header[0] if isinstance(header, tuple) else header
                    if not expanded:
                        continue
                if self._render_module_body(module, params):
                    state_changed = True
        imgui.end()

        return state_changed

    def _render_module_body(self, module, params):
        """Render one module's controls: its buttons, if it has any, then its
        param rows. Returns True if any routing value changed."""
        state_changed = False

        if module == "burst-trigger":
            # Trigger module: a Fire button in place of param sliders,
            # plus MIDI-learn. Fire is an action button; learn/clear are
            # link-style text so they read as a different kind of thing.
            if imgui.button("Fire##burst"):
                self.fire_burst()
            imgui.same_line()
            if self._midi_learn_burst:
                # Waiting for a pad press; click again to cancel. The
                # actual capture happens in the mido callback, which
                # clears the flag and the link reverts next frame.
                if self._link_text("learning... (cancel)", (1.0, 0.8, 0.2)):
                    self._midi_learn_burst = False
            else:
                if self.burst_midi_binding is not None:
                    imgui.text_disabled(
                        self._binding_label(self.burst_midi_binding)
                    )
                    imgui.same_line()
                if self._link_text("learn", (0.4, 0.7, 1.0)):
                    self._midi_learn_burst = True
                if self.burst_midi_binding is not None:
                    imgui.same_line()
                    if self._link_text("clear", (0.4, 0.7, 1.0)):
                        self.burst_midi_binding = None
                        routing_config.save_burst_binding(None)
            # fx sends below the Fire row, rendered like any other
            # instrument's routing rows.
            if params and self._render_instrument_section(module, params):
                state_changed = True
        elif module == "aliased-shimmer":
            # Gate module: Collect is held = 1, released = 0. We read the
            # button's held state (is_item_active) each frame rather than
            # its click, so the gate tracks press AND release. learn/clear
            # are link-style text, mirroring the burst Fire row — but the
            # learned pad gates on note-on/note-off, not a one-shot fire.
            imgui.button("Collect##aliased")
            self._collect_gate_mouse = imgui.is_item_active()
            self._update_collect_gate()
            imgui.same_line()
            if self._midi_learn_collect:
                # Waiting for a pad press; click again to cancel. The
                # capture happens in the mido callback, which clears the
                # flag and the link reverts next frame.
                if self._link_text("learning... (cancel)", (1.0, 0.8, 0.2)):
                    self._midi_learn_collect = False
            else:
                if self.collect_midi_binding is not None:
                    imgui.text_disabled(
                        self._binding_label(self.collect_midi_binding)
                    )
                    imgui.same_line()
                if self._link_text("learn", (0.4, 0.7, 1.0)):
                    self._midi_learn_collect = True
                if self.collect_midi_binding is not None:
                    imgui.same_line()
                    if self._link_text("clear", (0.4, 0.7, 1.0)):
                        self.collect_midi_binding = None
                        routing_config.save_collect_binding(None)
            # Clear is a one-shot trigger (not a gate): the button's click
            # fires it once; the ChucK side sees the 0->1 edge and acts.
            # learn/clear mirror the burst Fire row — the learned pad fires
            # the clear on its onset.
            if imgui.button("Clear##aliased"):
                self.fire_clear()
            imgui.same_line()
            if self._midi_learn_clear:
                if self._link_text("learning... (cancel)", (1.0, 0.8, 0.2)):
                    self._midi_learn_clear = False
            else:
                if self.clear_midi_binding is not None:
                    imgui.text_disabled(
                        self._binding_label(self.clear_midi_binding)
                    )
                    imgui.same_line()
                if self._link_text("learn", (0.4, 0.7, 1.0)):
                    self._midi_learn_clear = True
                if self.clear_midi_binding is not None:
                    imgui.same_line()
                    if self._link_text("clear", (0.4, 0.7, 1.0)):
                        self.clear_midi_binding = None
                        routing_config.save_clear_binding(None)
            # Master volume (and any future params) below the buttons,
            # rendered like the other instruments' routing rows.
            if self._render_instrument_section(module, params):
                state_changed = True
        elif self._render_instrument_section(module, params):
            state_changed = True

        return state_changed

    def _render_instrument_section(self, module, params):
        """Render one instrument's param rows.
        Returns True if any routing value changed (so it gets persisted)."""
        state_changed = False

        # Input is slider-only — no landmark routing for it.
        if module == "input":
            # Source selector: switch between the fake-theorbo (looped wav) and
            # the live mic. Persisted on its own (not part of routing_state).
            imgui.text("source")
            imgui.same_line(60)
            for src in routing_config.INPUT_SOURCES:
                clicked = imgui.radio_button(
                    f"{src}##input_source", self.input_source == src
                )
                if clicked and self.input_source != src:
                    self.input_source = src
                    routing_config.save_input_source(src)
                imgui.same_line()
            imgui.new_line()
            imgui.separator()

            imgui.text_disabled("Param")
            imgui.same_line(60)
            imgui.text_disabled("Slider")
            imgui.same_line(240)
            imgui.text_disabled("Exp")
            imgui.separator()
            for param, _default in params:
                st = self.routing_state[module][param]
                imgui.text(param)
                imgui.same_line(60)
                imgui.set_next_item_width(160)
                s_changed, new_val = imgui.slider_float(
                    f"##slider_{module}_{param}", st["slider"], 0.0, 1.0, format=""
                )
                if s_changed:
                    st["slider"] = new_val
                    state_changed = True
                imgui.same_line(240)
                e_changed, exp_on = imgui.checkbox(f"##exp_{module}_{param}", st["exp"])
                if e_changed:
                    st["exp"] = exp_on
                    state_changed = True
            return state_changed

        # Column header labels
        imgui.text_disabled("Param")
        imgui.same_line(60)
        imgui.text_disabled("Slider")
        imgui.same_line(240)
        imgui.text_disabled("Landmark")
        imgui.same_line(420)
        imgui.text_disabled("Use")
        imgui.same_line(460)
        imgui.text_disabled("Inv")
        imgui.same_line(500)
        imgui.text_disabled("Range")
        imgui.same_line(750)
        imgui.text_disabled("Exp")
        imgui.separator()

        for param, _default in params:
            st = self.routing_state[module][param]
            is_landmark = st["mode"] == "landmark"

            # Param label
            imgui.text(param)
            imgui.same_line(60)

            # Slider (active in slider mode, greyed in landmark mode)
            self._begin_disabled(is_landmark)
            imgui.set_next_item_width(160)
            # format="" hides the numeric readout — the 0..1 value is just
            # wire data, meaningless to the user; only the grab position matters.
            s_changed, new_val = imgui.slider_float(
                f"##slider_{module}_{param}", st["slider"], 0.0, 1.0, format=""
            )
            self._end_disabled(is_landmark)
            if s_changed:
                st["slider"] = new_val
                state_changed = True

            imgui.same_line(240)

            # Landmark combo (active in landmark mode, greyed in slider mode).
            # Live: the change takes effect on the next frame, no VM restart.
            try:
                idx = routing_config.LANDMARKS.index(st["landmark"])
            except ValueError:
                idx = 0
            self._begin_disabled(not is_landmark)
            imgui.set_next_item_width(160)
            c_changed, new_idx = imgui.combo(
                f"##lm_{module}_{param}", idx, routing_config.LANDMARKS
            )
            self._end_disabled(not is_landmark)
            if c_changed:
                st["landmark"] = routing_config.LANDMARKS[new_idx]
                # The range was calibrated in the old landmark's space, so it's
                # meaningless on the new one — reset to the full span.
                st["lo"], st["hi"] = (
                    routing_config.DEFAULT_LO, routing_config.DEFAULT_HI
                )
                state_changed = True

            imgui.same_line(420)

            # Mode checkbox: checked = landmark, unchecked = slider (default)
            m_changed, checked = imgui.checkbox(
                f"##mode_{module}_{param}", is_landmark
            )
            if m_changed:
                st["mode"] = "landmark" if checked else "slider"
                state_changed = True

            imgui.same_line(460)

            # Invert checkbox: flips the landmark (1 - value). Only meaningful in
            # landmark mode — the slider already reads low→high — so it's greyed
            # out otherwise.
            self._begin_disabled(not is_landmark)
            i_changed, inverted = imgui.checkbox(
                f"##invert_{module}_{param}", st["invert"]
            )
            self._end_disabled(not is_landmark)
            if i_changed:
                st["invert"] = inverted
                # Captures live in the invert-corrected space, so flipping invert
                # invalidates them — reset to full span to recalibrate.
                st["lo"], st["hi"] = (
                    routing_config.DEFAULT_LO, routing_config.DEFAULT_HI
                )
                state_changed = True

            # Range calibration: always shown, greyed out unless this param is in
            # landmark mode (like Inv). Min/Max capture the live invert-corrected
            # value (lo = param min, hi = param max); the readout shows it live.
            raw = self.latest_landmarks.get(st["landmark"], 0.5)
            r = (1.0 - raw) if st["invert"] else raw
            imgui.same_line(500)
            self._begin_disabled(not is_landmark)
            imgui.text_disabled(f"{r:.2f}")
            imgui.same_line()
            if imgui.small_button(f"Min##{module}_{param}"):
                st["lo"] = r
                state_changed = True
            imgui.same_line()
            imgui.text_disabled(f"{st['lo']:.2f}")
            imgui.same_line()
            if imgui.small_button(f"Max##{module}_{param}"):
                st["hi"] = r
                state_changed = True
            imgui.same_line()
            imgui.text_disabled(f"{st['hi']:.2f}")
            imgui.same_line()
            if imgui.small_button(f"Rst##{module}_{param}"):
                st["lo"], st["hi"] = (
                    routing_config.DEFAULT_LO, routing_config.DEFAULT_HI
                )
                state_changed = True
            self._end_disabled(not is_landmark)

            # Exp checkbox: bends the final 0..1 through a feel curve. Applies to
            # both slider and landmark, so it stays enabled in both modes. Fixed
            # column after the range group.
            imgui.same_line(750)
            e_changed, exp_on = imgui.checkbox(f"##exp_{module}_{param}", st["exp"])
            if e_changed:
                st["exp"] = exp_on
                state_changed = True

        imgui.spacing()
        imgui.separator()
        return state_changed

    @staticmethod
    def _binding_from_msg(msg):
        """Reduce a mido message to a stable binding key, or None if it isn't a
        learnable onset. We bind to pad *presses* (note_on with velocity, or a
        non-zero control_change), keyed by note/control number only — velocity
        and value are dropped so any press of that pad matches, and the release
        edge (velocity/value 0) is ignored so it doesn't double-fire."""
        if msg.type == "note_on" and msg.velocity > 0:
            return {"type": "note_on", "note": msg.note}
        if msg.type == "control_change" and msg.value > 0:
            return {"type": "control_change", "control": msg.control}
        return None

    def _on_midi_message(self, msg):
        """mido callback (background thread). Drives the burst trigger, the
        collect gate, and the clear trigger: in each one's learn mode, capture the
        next pad press as its binding and persist it; otherwise the bound control
        fires burst/clear on its onset, and gates collect open/closed on its
        onset/release. Decoupled from the GUI/camera loop, like the OSC triggers
        themselves."""
        if self._midi_learn_burst:
            binding = self._binding_from_msg(msg)
            if binding is not None:
                self.burst_midi_binding = binding
                self._midi_learn_burst = False
                routing_config.save_burst_binding(binding)
        elif self.burst_midi_binding is not None:
            if self._binding_from_msg(msg) == self.burst_midi_binding:
                self.fire_burst()

        # collect gate: in learn mode capture the next pad press; otherwise the
        # bound pad gates the effect — its onset opens, its release closes.
        if self._midi_learn_collect:
            binding = self._binding_from_msg(msg)
            if binding is not None:
                self.collect_midi_binding = binding
                self._midi_learn_collect = False
                routing_config.save_collect_binding(binding)
        else:
            edge = self._gate_edge(msg, self.collect_midi_binding)
            if edge is not None:
                self._collect_gate_midi = (edge == "open")
                self._update_collect_gate()

        # clear trigger: in learn mode capture the next pad press; otherwise the
        # bound pad fires the clear on its onset (one-shot, like burst).
        if self._midi_learn_clear:
            binding = self._binding_from_msg(msg)
            if binding is not None:
                self.clear_midi_binding = binding
                self._midi_learn_clear = False
                routing_config.save_clear_binding(binding)
        elif self.clear_midi_binding is not None:
            if self._binding_from_msg(msg) == self.clear_midi_binding:
                self.fire_clear()

    @staticmethod
    def _binding_label(binding):
        """Short human label for a learned binding, e.g. "cc 20" / "note 36"."""
        if binding["type"] == "note_on":
            return f"note {binding['note']}"
        return f"cc {binding['control']}"

    @staticmethod
    def _link_text(label, color):
        """Render link-style clickable text (no button chrome) and return True
        when clicked. pyimgui has no hyperlink widget, so this is colored text
        plus the last-item hit-test, with a hand cursor on hover."""
        imgui.text_colored(label, *color)
        clicked = imgui.is_item_clicked()
        if imgui.is_item_hovered():
            imgui.set_mouse_cursor(imgui.MOUSE_CURSOR_HAND)
        return clicked

    def fire_burst(self):
        """Fire one noise burst on the ChucK side. Sent immediately as an OSC
        bang on the triggering event — not folded into the per-frame param
        broadcast — so the trigger stays decoupled from the camera/GUI frame
        rate. A future MIDI pad would call this same method from its callback
        and inherit the same low-latency path."""
        if self.osc_enabled:
            self.osc_ctrl.send_trigger("/trigger/burst")

    def fire_clear(self):
        """Trigger one clear on the ChucK side. Sent immediately as an OSC bang on
        /trigger/clear when the button is clicked — decoupled from the per-frame
        param broadcast like the burst trigger. The aliased-shimmer module reads
        it as a 0->1 edge and fires once."""
        if self.osc_enabled:
            self.osc_ctrl.send_trigger("/trigger/clear")

    def _update_collect_gate(self):
        """Recompute the collect gate from its two sources (GUI button held, MIDI
        pad held) and send /gate/collect only when the combined open/closed state
        flips — so the edge fires once, not every frame. Called from the GUI loop
        (button) and the mido callback (pad), like fire_burst's low-latency path."""
        open_ = self._collect_gate_mouse or self._collect_gate_midi
        if open_ == self._collect_gate_open:
            return
        self._collect_gate_open = open_
        if self.osc_enabled:
            self.osc_ctrl.send_value("/gate/collect", 1.0 if open_ else 0.0)

    @staticmethod
    def _gate_edge(msg, binding):
        """Classify a mido message against a learned gate binding: "open" on its
        onset (note-on with velocity, or cc > 0), "close" on its release (note-off,
        note-on velocity 0, or cc 0), or None if it isn't that control."""
        if binding is None:
            return None
        if binding["type"] == "note_on":
            if msg.type == "note_on" and msg.note == binding["note"]:
                return "open" if msg.velocity > 0 else "close"
            if msg.type == "note_off" and msg.note == binding["note"]:
                return "close"
        elif binding["type"] == "control_change":
            if msg.type == "control_change" and msg.control == binding["control"]:
                return "open" if msg.value > 0 else "close"
        return None

    def _render_chuck_panel(self):
        if self._begin_window("ChucK"):

            # Detect if VM died on its own
            if self.chuck.vm_poll() is not None and self.chuck._vm_proc is not None:
                self.chuck.log.append(f"[VM] Exited with code {self.chuck.vm_returncode}")
                self.chuck._vm_proc = None
                self.chuck._shred_ids.clear()

            # --- VM control ---
            if self.chuck.vm_running:
                imgui.text_colored("● VM", 0.3, 1.0, 0.3)
                imgui.same_line()
                if imgui.button("Stop VM"):
                    self.chuck.stop_vm()
            else:
                imgui.text_colored("○ VM", 0.6, 0.6, 0.6)
                imgui.same_line()
                if imgui.button("Start VM"):
                    self.chuck.start_vm()

            imgui.separator()

            # --- Per-effect toggles ---
            for name in self.chuck.effects:
                is_active = self.chuck.is_active(name)
                has_id    = self.chuck.has_id(name)

                if is_active:
                    color = (0.3, 1.0, 0.3) if has_id else (1.0, 0.8, 0.2)  # green / yellow while pending
                    imgui.text_colored(f"● {name}", *color)
                    imgui.same_line()
                    if has_id:
                        if imgui.button(f"Remove##{name}"):
                            self.chuck.remove_effect(name)
                    else:
                        imgui.text_disabled("pending...")
                else:
                    imgui.text_colored(f"○ {name}", 0.6, 0.6, 0.6)
                    imgui.same_line()
                    if self.chuck.vm_running:
                        if imgui.button(f"Add##{name}"):
                            self.chuck.add_effect(name)
                    else:
                        imgui.text_disabled("--")

            imgui.separator()

            # --- Log ---
            imgui.begin_child("chuck_log", 0, 150, border=True)
            for line in list(self.chuck.log):
                imgui.text(line)
            imgui.set_scroll_here_y(1.0)
            imgui.end_child()

            imgui.end()

    def _create_texture(self):
        texture_id = gl.glGenTextures(1)
        gl.glBindTexture(gl.GL_TEXTURE_2D, texture_id)
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR)
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR)
        return texture_id

    def _update_texture(self, frame_rgb):
        h, w = frame_rgb.shape[:2]
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.video_texture)
        gl.glTexImage2D(
            gl.GL_TEXTURE_2D, 0, gl.GL_RGB,
            w, h, 0,
            gl.GL_RGB, gl.GL_UNSIGNED_BYTE,
            frame_rgb
        )

    def set_recognizer(self, recognizer):
        self._tracker_recognizer = recognizer

    def _get_tracker_recognizer(self):
        return self._tracker_recognizer

    def should_close(self):
        return glfw.window_should_close(self.window)

    def begin_frame(self):
        glfw.poll_events()
        self.impl.process_inputs()

    def get_settings(self):
        active_modules = {
            "face": self.active_face,
            "hands": self.active_hands,
            "pose": self.active_pose
        }
        osc_settings = {
            "enabled": self.osc_enabled,
            "ip": self.osc_ip_buf.strip(),
            "port": int(self.osc_port_buf.strip()) if self.osc_port_buf.strip().isdigit() else 8000
        }
        return active_modules, osc_settings

    def render(self, frame_rgb, results, camera_warning=None):
        # Refresh only the landmarks seen this frame; the rest hold their last
        # value so params don't snap when a hand leaves view.
        if results:
            self.latest_landmarks.update(results.get("landmark_values", {}))

        self._update_texture(frame_rgb)
        vid_h, vid_w = frame_rgb.shape[:2]

        imgui.new_frame()

        self._render_main_menu_bar()

        # --- Camera Feed ---
        if self._begin_window("Camera Feed"):
            if camera_warning:
                imgui.text_colored(camera_warning, 1.0, 0.3, 0.3)
            imgui.image(self.video_texture, vid_w, vid_h)
            imgui.end()

        # --- Configuration (MIDI + OSC) ---
        if self._begin_window("Configuration"):

            midi_hdr = imgui.collapsing_header("MIDI", flags=imgui.TREE_NODE_DEFAULT_OPEN)
            if (midi_hdr[0] if isinstance(midi_hdr, tuple) else midi_hdr):
                # Device dropdown. The list is re-scanned on Refresh (and at startup),
                # not every frame — enumerating hardware each frame is wasteful.
                imgui.text("Device")
                imgui.same_line()
                imgui.set_next_item_width(220)
                changed, self.midi_port_index = imgui.combo(
                    "##midi_device", self.midi_port_index, self.midi_ports
                )
                if changed:
                    port = self.midi_ports[self.midi_port_index]
                    self.midi.select(port)
                    routing_config.save_midi_port(port)
                imgui.same_line()
                if imgui.button("Refresh"):
                    self._refresh_midi_ports()

                # Live monitor of incoming messages, with a Clear button.
                imgui.text("Incoming")
                imgui.same_line()
                if imgui.small_button("Clear"):
                    self.midi.clear_log()
                # Snapshot the deque before iterating — the mido callback appends to
                # it from a background thread.
                imgui.begin_child("midi_log", 0, 150, border=True)
                for line in list(self.midi.log):
                    imgui.text(line)
                imgui.set_scroll_here_y(1.0)
                imgui.end_child()

            osc_hdr = imgui.collapsing_header("OSC", flags=imgui.TREE_NODE_DEFAULT_OPEN)
            if (osc_hdr[0] if isinstance(osc_hdr, tuple) else osc_hdr):
                _, self.osc_enabled = imgui.checkbox("Enabled", self.osc_enabled)
                imgui.set_next_item_width(140)
                _, self.osc_ip_buf = imgui.input_text("IP", self.osc_ip_buf, 64)
                imgui.set_next_item_width(80)
                _, self.osc_port_buf = imgui.input_text("Port", self.osc_port_buf, 8)

            imgui.end()

        # --- Tracking ---
        if self._begin_window("Tracking"):

            _, self.active_hands = imgui.checkbox("Hands", self.active_hands)
            imgui.same_line()
            _, self.active_face = imgui.checkbox("Face", self.active_face)
            imgui.same_line()
            _, self.active_pose = imgui.checkbox("Pose", self.active_pose)

            imgui.separator()

            digits = [("Thumb", 4), ("Index", 8), ("Mid", 12), ("Ring", 16), ("Pinky", 20)]

            # Left Hand
            imgui.text_colored("LEFT HAND", 0.4, 0.8, 1.0)
            if not self.active_hands:
                imgui.text("[OFF]")
            elif results["left_hand"]:
                for name, idx in digits:
                    pt = results["left_hand"][idx]
                    imgui.text(f"  {name}: {pt.x:.2f}, {pt.y:.2f}")
            else:
                imgui.text("  No Detection")

            imgui.spacing()

            # Right Hand
            imgui.text_colored("RIGHT HAND", 0.4, 1.0, 0.4)
            if not self.active_hands:
                imgui.text("[OFF]")
            elif results["right_hand"]:
                for name, idx in digits:
                    pt = results["right_hand"][idx]
                    imgui.text(f"  {name}: {pt.x:.2f}, {pt.y:.2f}")
            else:
                imgui.text("  No Detection")

            imgui.spacing()

            # Face
            imgui.text_colored("FACE", 1.0, 1.0, 0.4)
            if not self.active_face:
                imgui.text("[OFF]")
            elif results["face"]:
                face = results["face"].face_landmarks[0]
                nose = face[1]
                imgui.text(f"  Nose: {nose.x:.2f}, {nose.y:.2f}")
                eye_l = face[33]
                eye_r = face[263]
                imgui.text(f"  L-Eye: {eye_l.x:.2f}, {eye_l.y:.2f}")
                imgui.text(f"  R-Eye: {eye_r.x:.2f}, {eye_r.y:.2f}")
                m_x = (face[13].x + face[14].x) / 2
                m_y = (face[13].y + face[14].y) / 2
                imgui.text(f"  Mouth: {m_x:.2f}, {m_y:.2f}")
            else:
                imgui.text("  No Detection")

            imgui.end()

        # --- Gesture Panel ---
        if self._begin_window("Gestures"):

            # Live recognition display
            rh_gesture = results.get("gesture", {}).get("right_hand")
            rh_conf = results.get("gesture_confidence", {}).get("right_hand", 0.0)
            if rh_gesture:
                imgui.text_colored(f"Right Hand: {rh_gesture} ({int(rh_conf * 100)}%)", 0.4, 1.0, 0.4)
            else:
                imgui.text("Right Hand: ---")

            imgui.separator()

            # Collection controls
            imgui.text("Collect Data")
            changed, self.gesture_label_buf = imgui.input_text("Label", self.gesture_label_buf, 64)

            status = self.gesture_collector.get_status()
            if status["recording"]:
                imgui.text_colored(f"Recording: {status['sample_count']} samples", 1.0, 0.3, 0.3)
                if imgui.button("Stop"):
                    count = self.gesture_collector.stop_recording()
                    self.gesture_train_msg = f"Saved {count} samples"
            else:
                label = self.gesture_label_buf.strip()
                if label and results.get("right_hand"):
                    if imgui.button("Record"):
                        self.gesture_collector.start_recording(label, "right_hand")
                        self.gesture_train_msg = ""
                else:
                    imgui.text_disabled("Enter label + show right hand")

            # Record samples each frame while recording
            if status["recording"] and results.get("right_hand"):
                self.gesture_collector.record_sample(results["right_hand"])

            imgui.spacing()

            # Train button
            if imgui.button("Train Model"):
                recognizer = self._get_tracker_recognizer()
                if recognizer:
                    success, msg = recognizer.train("right_hand")
                    self.gesture_train_msg = msg
                else:
                    self.gesture_train_msg = "Trainer not available"

            if self.gesture_train_msg:
                imgui.text(self.gesture_train_msg)

            imgui.spacing()
            imgui.separator()

            # Dataset summary
            summary = self.gesture_collector.get_summary()
            if summary:
                imgui.text("Collected gestures:")
                to_delete = None
                for (source, label), count in sorted(summary.items()):
                    imgui.text(f"  {source}/{label}: {count}")
                    imgui.same_line()
                    if imgui.small_button(f"X##{source}_{label}"):
                        to_delete = (label, source)
                if to_delete:
                    self.gesture_collector.delete_gesture(*to_delete)

            imgui.end()

        # --- ChucK Panel ---
        self._render_chuck_panel()

        # --- Per-Instrument Routing Windows ---
        self._render_instrument_windows()

        # --- OpenGL Render ---
        imgui.render()
        gl.glClearColor(0.1, 0.1, 0.1, 1.0)
        gl.glClear(gl.GL_COLOR_BUFFER_BIT)
        self.impl.render(imgui.get_draw_data())
        glfw.swap_buffers(self.window)

    def render_no_frame(self, camera_warning=None):
        imgui.new_frame()
        self._render_main_menu_bar()
        if self._begin_window("Camera Feed"):
            imgui.text("No camera frame available.")
            if camera_warning:
                imgui.text_colored(camera_warning, 1.0, 0.3, 0.3)
            imgui.end()
        self._render_chuck_panel()
        self._render_instrument_windows()
        imgui.render()
        gl.glClearColor(0.1, 0.1, 0.1, 1.0)
        gl.glClear(gl.GL_COLOR_BUFFER_BIT)
        self.impl.render(imgui.get_draw_data())
        glfw.swap_buffers(self.window)

    def _refresh_midi_ports(self):
        """Re-scan connected MIDI inputs, keeping the current selection if it's
        still present, otherwise dropping it and falling back to None (the device
        was unplugged)."""
        self.midi_ports = MidiListener.available_ports()
        if self.midi.selected in self.midi_ports:
            self.midi_port_index = self.midi_ports.index(self.midi.selected)
        else:
            self.midi.select("None")
            routing_config.save_midi_port("None")
            self.midi_port_index = 0

    def shutdown(self):
        # Force-write the layout now: ImGui only auto-saves ~5s after a change,
        # so a window moved just before quitting would otherwise be lost.
        imgui.save_ini_settings_to_disk(self._ini_path)
        self.midi.close()
        self.chuck.stop_vm()
        gl.glDeleteTextures(1, [self.video_texture])
        self.impl.shutdown()
        glfw.terminate()
