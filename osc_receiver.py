"""
osc_receiver.py — Listens for OSC coming back from ChucK.

The counterpart to osc_controller.py, which only sends. ChucK's core/meter.ck
reports the master output level here so the GUI can draw a meter; Python listens
on its own port because 8000 is ChucK's inbound one.

Levels arrive faster (~86/s) than the GUI draws (~30-60/s), so the peak is
accumulated between reads rather than overwritten — take() returns the loudest
sample seen since the last call and then resets. Reading the latest value
instead would silently drop the transients a meter exists to catch.
"""

import threading

from pythonosc import dispatcher, osc_server


class OscReceiver:
    """Background OSC server holding the most recent meter reading."""

    def __init__(self, ip="127.0.0.1", port=8001):
        self.ip = ip
        self.port = port
        self.running = False
        self.error = None

        # Accumulated since the last take(): peak per channel, and whether the
        # output clipped at any point in that span.
        self._peak_left = 0.0
        self._peak_right = 0.0
        self._clipped = False
        self._lock = threading.Lock()

        disp = dispatcher.Dispatcher()
        disp.map("/meter", self._on_meter)

        try:
            self._server = osc_server.ThreadingOSCUDPServer((ip, port), disp)
        except OSError as exc:
            # Port busy (a stale VM, or a second copy of the app). The meter just
            # stays dark — nothing else in the app depends on receiving.
            self._server = None
            self.error = f"OSC receive on {ip}:{port} unavailable ({exc})"
            print(f"OSC Receiver: {self.error}")
            return

        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        self.running = True
        print(f"OSC Receiver started. Listening on {self.ip}:{self.port}")

    def _on_meter(self, _address, *args):
        """/meter <peakL> <peakR> <clipped> from chuck-scripts/core/meter.ck."""
        if len(args) < 3:
            return
        try:
            left = float(args[0])
            right = float(args[1])
            clipped = bool(int(args[2]))
        except (TypeError, ValueError):
            return
        with self._lock:
            self._peak_left = max(self._peak_left, left)
            self._peak_right = max(self._peak_right, right)
            self._clipped = self._clipped or clipped

    def take(self):
        """Return (peak_left, peak_right, clipped) since the last call, and
        reset. Returns zeros when nothing has arrived — which is also what a
        stopped VM looks like, so the meter falls to silence on its own."""
        with self._lock:
            result = (self._peak_left, self._peak_right, self._clipped)
            self._peak_left = 0.0
            self._peak_right = 0.0
            self._clipped = False
        return result

    def shutdown(self):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        self.running = False
