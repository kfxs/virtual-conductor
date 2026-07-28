// synth.ck — Pure DSP. Reads hand position from globals set by osc-router.ck.
// Right hand Y = pitch, Left hand Y = filter cutoff.
// Run via launch-synth.ck, not directly.

global float g_synth_pitch;
global float g_synth_cutoff;
// how much of this module to send into the shared delay/reverb buses
global float g_synth_delaysend;
global float g_synth_reverbsend;

// ===== HELPERS =====
fun float mapRange(float value, float inMin, float inMax, float outMin, float outMax) {
    return outMin + (value - inMin) * (outMax - outMin) / (inMax - inMin);
}

fun float clamp(float value, float minVal, float maxVal) {
    if (value < minVal) return minVal;
    if (value > maxVal) return maxVal;
    return value;
}

fun float expMap(float value, float minVal, float maxVal) {
    return minVal * Math.pow(maxVal / minVal, value);
}

// ===== AUDIO SETUP =====
SawOsc saw => LPF filter => Gain master => dac;
440 => saw.freq;
0.5 => master.gain;
2000 => filter.freq;
2.0 => filter.Q;

// fx sends into the shared buses (core/delay.ck, core/reverb.ck). Mono source,
// so one send gain per bus feeds both channels. Tapped post-fader (after
// master) so the module's level fades the tails with it.
global Gain g_delay_in_l;
global Gain g_delay_in_r;
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

Gain delaySend, reverbSend;
0.0 => delaySend.gain;
0.0 => reverbSend.gain;

master => delaySend  => g_delay_in_l;
          delaySend  => g_delay_in_r;
master => reverbSend => g_reverb_in_l;
          reverbSend => g_reverb_in_r;

// ===== SETTINGS =====
0.1 => float smoothing;
5::ms => dur updateRate;
200.0 => float minCutoff;
4000.0 => float maxCutoff;

<<< "[synth] Ready. Right hand = PITCH (200-800 Hz), Left hand = FILTER CUTOFF" >>>;

fun void interpolate() {
    440.0 => float currentFreq;
    2000.0 => float currentCutoff;

    while(true) {
        // Compute targets from globals each tick (0 -> min, 1 -> max; Python
        // already normalized and applied any axis inversion).
        200 + (g_synth_pitch * 600) => float targetFreq;
        expMap(g_synth_cutoff, minCutoff, maxCutoff) => float targetCutoff;

        // Smooth toward targets
        currentFreq + (targetFreq - currentFreq) * smoothing => currentFreq;
        currentFreq => saw.freq;

        currentCutoff + (targetCutoff - currentCutoff) * smoothing => currentCutoff;
        currentCutoff => filter.freq;

        // fx sends track their globals directly (no smoothing needed — they're
        // a mix amount, not a per-sample audio target)
        Math.max(0.0, Math.min(1.0, g_synth_delaysend))  => delaySend.gain;
        Math.max(0.0, Math.min(1.0, g_synth_reverbsend)) => reverbSend.gain;

        updateRate => now;
    }
}

spork ~ interpolate();

while(true) { 1::second => now; }
