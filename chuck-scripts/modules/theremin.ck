// theremin.ck — Pure DSP. Reads hand position from globals set by osc-router.ck.
// Right hand Y = pitch, Left hand Y = volume.
// Run via launch-theremin.ck, not directly.

global float g_theremin_pitch;
global float g_theremin_volume;
// how much of this module to send into the shared delay/reverb buses
global float g_theremin_delaysend;
global float g_theremin_reverbsend;

// ===== AUDIO SETUP =====
SinOsc s => Gain g => dac;
440 => s.freq;
0.5 => g.gain;

// fx sends into the shared buses (core/delay.ck, core/reverb.ck). Mono source,
// so one send gain per bus feeds both channels. Tapped post-fader (after g) so
// the volume control fades the tails with it.
global Gain g_delay_in_l;
global Gain g_delay_in_r;
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

Gain delaySend, reverbSend;
0.0 => delaySend.gain;
0.0 => reverbSend.gain;

g => delaySend  => g_delay_in_l;
     delaySend  => g_delay_in_r;
g => reverbSend => g_reverb_in_l;
     reverbSend => g_reverb_in_r;

// ===== VIBRATO =====
// Rate proportional to current frequency (ratio 1/60 → ~7 Hz at 440 Hz)
// Depth: ±0.5% of current frequency
SinOsc vibrato => blackhole;
0.015 => float vibratoDepthRatio;  // depth as fraction of freq
1.0 / 60.0 => float vibratoRateRatio;  // rate as fraction of freq

// ===== INTERPOLATION SETTINGS =====
0.1 => float smoothing;
5::ms => dur updateRate;

<<< "[theremin] Ready. Right hand = PITCH (200-800 Hz), Left hand = VOLUME" >>>;

fun void interpolate() {
    while(true) {
        // Compute targets from globals each tick (0 -> min, 1 -> max; Python
        // already normalized and applied any axis inversion).
        200 + (g_theremin_pitch * 600) => float targetFreq;
        g_theremin_volume => float targetGain;

        // Smooth toward targets
        s.freq() + (targetFreq - s.freq()) * smoothing => float currentFreq;

        // Vibrato: rate and depth both scale with frequency
        currentFreq * vibratoRateRatio => vibrato.freq;
        currentFreq + (vibrato.last() * currentFreq * vibratoDepthRatio) => s.freq;

        g.gain() + (targetGain - g.gain()) * smoothing => g.gain;

        // fx sends track their globals directly (no smoothing needed — they're
        // a mix amount, not a per-sample audio target)
        Math.max(0.0, Math.min(1.0, g_theremin_delaysend))  => delaySend.gain;
        Math.max(0.0, Math.min(1.0, g_theremin_reverbsend)) => reverbSend.gain;

        updateRate => now;
    }
}

spork ~ interpolate();

while(true) { 1::second => now; }
