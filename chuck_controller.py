"""
ChucK Controller — manages a persistent ChucK VM and individual DSP effect shreds.
"""

import os
import re
import subprocess
import threading
from collections import deque


EFFECTS = {
    "Theremin":   "chuck-scripts/modules/theremin.ck",
    "Synth":      "chuck-scripts/modules/synth.ck",
    "Granulator": "chuck-scripts/modules/granulator.ck",
    "Burst-trigger": "chuck-scripts/modules/burst-trigger.ck",
    "Aliased-shimmer": "chuck-scripts/modules/aliased-shimmer.ck",
    "Spectral-sines": "chuck-scripts/modules/spectral-sines.ck",
}


class ChuckController:
    def __init__(self):
        self._project_dir = os.path.dirname(os.path.abspath(__file__))
        self.effects = EFFECTS
        self._vm_proc = None
        self._shred_ids = {}   # name -> shred_id (int or None while pending)
        self.log = deque(maxlen=500)

    # ------------------------------------------------------------------ VM

    def start_vm(self):
        if self._vm_proc and self._vm_proc.poll() is None:
            return
        self.log.clear()
        self.log.append("[VM] Starting ChucK VM...")
        # Core shreds, always running and never added/removed by the user.
        # Order matters: the router seeds every param global before anything
        # reads it, the peak detector taps the input bus, and the delay patches
        # into the reverb's input bus, so the reverb comes up before the delay.
        self._vm_proc = subprocess.Popen(
            ["chuck", "--loop",
             "chuck-scripts/core/osc-router.ck",
             "chuck-scripts/core/input.ck",
             "chuck-scripts/core/peak-detector.ck",
             "chuck-scripts/core/reverb.ck",
             "chuck-scripts/core/delay.ck"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=self._project_dir,
        )
        threading.Thread(target=self._read_output, daemon=True).start()

    def stop_vm(self):
        self._shred_ids.clear()
        if self._vm_proc and self._vm_proc.poll() is None:
            self._vm_proc.terminate()
            try:
                self._vm_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._vm_proc.kill()
        self._vm_proc = None
        self.log.append("[VM] Stopped.")

    def restart_vm(self):
        """Restart the VM and re-add the effects that were playing.

        Used by the routing panel so saved routing changes take effect without
        the user having to manually re-add their active effects.
        """
        active = [name for name in self.effects if self.is_active(name)]
        self.stop_vm()
        self.start_vm()
        if active:
            self.log.append(f"[VM] Re-adding after restart: {', '.join(active)}")
            # The VM needs a moment to finish booting before it accepts `chuck +`.
            threading.Timer(1.0, lambda: self._reapply_effects(active)).start()

    def _reapply_effects(self, names):
        for name in names:
            self.add_effect(name)

    @property
    def vm_running(self):
        return self._vm_proc is not None and self._vm_proc.poll() is None

    def vm_poll(self):
        if self._vm_proc:
            return self._vm_proc.poll()
        return None

    @property
    def vm_returncode(self):
        return self._vm_proc.returncode if self._vm_proc else None

    # ------------------------------------------------------------------ Effects

    def add_effect(self, name):
        if not self.vm_running or name in self._shred_ids:
            return
        # Optimistic: mark active immediately, ID filled in from stdout
        self._shred_ids[name] = None
        script = self.effects[name]
        subprocess.run(
            ["chuck", "+", script],
            cwd=self._project_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Query status after a short delay as reliable fallback for shred ID
        threading.Timer(0.3, self._query_status).start()

    def remove_effect(self, name):
        if name not in self._shred_ids:
            return
        shred_id = self._shred_ids.pop(name)
        if shred_id is not None:
            subprocess.run(
                ["chuck", "-", str(shred_id)],
                cwd=self._project_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            # ID not received yet — query status then retry remove
            self.log.append(f"[VM] Waiting for {name} shred ID, retrying remove...")
            threading.Timer(0.3, lambda: self._deferred_remove(name)).start()

    def is_active(self, name):
        return name in self._shred_ids

    def has_id(self, name):
        """True only when shred ID is confirmed (remove is safe)."""
        return self._shred_ids.get(name) is not None

    # ------------------------------------------------------------------ Internal

    def _query_status(self):
        subprocess.run(
            ["chuck", "^"],
            cwd=self._project_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _deferred_remove(self, name):
        self._query_status()
        threading.Timer(0.3, lambda: self._retry_remove(name)).start()

    def _retry_remove(self, name):
        if name not in self._shred_ids:
            return  # already removed or never confirmed
        shred_id = self._shred_ids.pop(name)
        if shred_id is not None:
            subprocess.run(
                ["chuck", "-", str(shred_id)],
                cwd=self._project_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            self.log.append(f"[VM] Could not get shred ID for {name}, remove failed.")

    def _read_output(self):
        for line in self._vm_proc.stdout:
            line = line.rstrip()
            self.log.append(line)
            self._parse_shred_event(line)
        self._shred_ids.clear()

    def _parse_shred_event(self, line):
        # Sporking: "[chuck](VM): sporking incoming shred: 2 (theremin.ck)..."
        m = re.search(r'sporking incoming shred: (\d+) \(([^)]+)\)', line)
        if m:
            self._register_shred(int(m.group(1)), m.group(2))
            return

        # Status line from chuck ^: "  [shred id]: 2  [source]: theremin.ck ..."
        m = re.search(r'\[shred id\]:\s*(\d+).*\[source\]:\s*(\S+)', line)
        if m:
            self._register_shred(int(m.group(1)), m.group(2))
            return

        # Removing: "[chuck](VM): removing shred: 2 (theremin.ck)..."
        m = re.search(r'removing shred: (\d+) \(([^)]+)\)', line)
        if m:
            shred_id = int(m.group(1))
            for name, sid in list(self._shred_ids.items()):
                if sid == shred_id:
                    del self._shred_ids[name]
                    self.log.append(f"[VM] {name} removed (shred {shred_id})")
                    return

    def _register_shred(self, shred_id, raw_filename):
        filename = os.path.basename(raw_filename)
        for name, script in self.effects.items():
            if os.path.basename(script) == filename:
                if self._shred_ids.get(name) is None:
                    self._shred_ids[name] = shred_id
                    self.log.append(f"[VM] {name} active (shred {shred_id})")
                return
