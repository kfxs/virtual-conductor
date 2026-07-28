// spectral-sines.ck — additive resynthesis of what the performer is playing.
//
// Sounds one sine per spectral peak, so the result tracks the theorbo as a
// clean, organ-like shadow of it.
//
// It does no analysis of its own: core/peak-detector.ck runs the single shared
// FFT and publishes the peaks, and this shred just voices them. That split
// means a future module can read the same detection without a second FFT.
//
// The published set is sorted loudest first, so voicing the first N is voicing
// the N strongest partials — musically the right subset to keep.
//
// Python sends each param normalized 0..1 on /param/spectral-sines/<param>;
// this shred maps every 0..1 value into its [MIN, MAX] range.

// ===== PEAKS, FROM core/peak-detector.ck =====
// Sizes must match the detector's exactly — see the contract in its header.
global float g_peak_freqs[8];
global float g_peak_mags[8];
global int g_peak_count;
g_peak_freqs.size() => int MAX_SINES;

// ===== VOICES =====
// One sine per peak slot, each through its own Envelope, summed into master.
//
// The Envelope is what makes the level changes click-free. Writing osc.gain
// from a control loop can't be: however fast the loop ticks it still holds the
// value flat and then jumps, and every jump is a discontinuity — the staircase
// zipper noise granulator.ck's envelope comment warns about. Envelope ramps at
// a constant slope in the audio graph, sample by sample, so nothing steps.
SinOsc osc[MAX_SINES];
Envelope env[MAX_SINES];
Gain master => dac;
1.0 => master.gain;

// Time for a full 0 -> 1 excursion; the slope is constant, so smaller level
// changes finish proportionally sooner. Also the fade in/out when a partial
// appears or dies.
20::ms => dur VOICE_RAMP;

for (0 => int i; i < MAX_SINES; i++) {
    osc[i] => env[i] => master;
    1.0 => osc[i].gain;          // the envelope carries the level, not the osc
    VOICE_RAMP => env[i].duration;
    0.0 => env[i].value;         // start silent
    env[i].target(0.0);
}
0.25 => float VOICE_GAIN;   // per-oscillator level when a peak is sounding

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

// ===== PARAMETERS =====
// Normalized 0..1 from osc-router.ck; mapped into the ranges below.
// The search band lives on the detector, not here — it describes the analysis,
// which is now shared.
global float g_spectral_sines_sines;
global float g_spectral_sines_magtrack;
global float g_spectral_sines_delaysend;
global float g_spectral_sines_reverbsend;
global float g_spectral_sines_mastervol;

// how many of the published peaks actually sound (1 = just the loudest)
1.0 => float SINES_MIN;      MAX_SINES $ float => float SINES_MAX;
// how far each sine's level follows its peak's magnitude:
//   0 = flat, every sine at the same level (an organ-like chord)
//   1 = fully scaled, each sine in proportion to how strong its partial is
// anything between crossfades the two, so this is a timbre morph rather than
// a switch.
0.0 => float MAGTRACK_MIN;   1.0 => float MAGTRACK_MAX;
0.0 => float SEND_MIN;       1.0 => float SEND_MAX;
0.0 => float MASTER_VOL_MIN; 2.0 => float MASTER_VOL_MAX;   // 0.5 -> unity

4 => int activeSines;
0.0 => float magTrack;

// map a normalized 0..1 into a float range
fun float mapF(float g, float lo, float hi) { return lo + g * (hi - lo); }
// guard against an out-of-range value arriving before Python's first frame
fun float clampN(float g) { return Math.max(0.0, Math.min(1.0, g)); }

fun void readParams() {
    mapF(clampN(g_spectral_sines_sines), SINES_MIN, SINES_MAX) $ int => activeSines;
    if (activeSines < 1) 1 => activeSines;
    if (activeSines > MAX_SINES) MAX_SINES => activeSines;

    mapF(clampN(g_spectral_sines_magtrack), MAGTRACK_MIN, MAGTRACK_MAX) => magTrack;

    mapF(clampN(g_spectral_sines_delaysend),  SEND_MIN, SEND_MAX) => delaySend.gain;
    mapF(clampN(g_spectral_sines_reverbsend), SEND_MIN, SEND_MAX) => reverbSend.gain;
    mapF(clampN(g_spectral_sines_mastervol), MASTER_VOL_MIN, MASTER_VOL_MAX)
        => master.gain;
}

// ===== VOICE ASSIGNMENT (PARTIAL TRACKING) =====
//
// Where each oscillator is heading. The audible values glide toward these; they
// are never written to the oscillators directly, because a step in gain is a
// click and a step in frequency is a jump.
float targetFreq[MAX_SINES];
float targetGain[MAX_SINES];
int taken[MAX_SINES];

// How far a voice may be dragged to claim a peak, in octaves. Beyond this it
// isn't the same partial any more, so a different voice takes it.
//
// This has to stay well inside the gap between neighbouring harmonics, and that
// gap shrinks as you climb: harmonic n to n+1 is log2((n+1)/n) octaves apart,
// which is a whole octave at the bottom but only 0.19 by the 7th harmonic and
// 0.09 by the 15th. A window of 0.2 (the first thing tried here) was therefore
// wider than the spacing from the 7th harmonic up — around 455 Hz on a 65 Hz
// string — so up there voices stole each other's partials and warbled, while
// the widely-spaced bass tracked perfectly.
//
// 0.05 octaves is 60 cents: far more than the few cents of analysis jitter,
// enough for moderate vibrato, and still inside harmonic spacing past the 16th.
0.05 => float MAX_TRACK_OCTAVES;

// A voice this quiet is inaudible, so it can be retuned instantly instead of
// sweeping to its new partial.
0.001 => float SILENT_LEVEL;

// Assign peaks to oscillators by frequency proximity rather than by rank.
//
// The published peaks are sorted by magnitude, and on a decaying note two
// partials of similar strength swap places constantly. Assigning by rank would
// hand osc[0] a different partial every hop — the oscillators would leap
// between frequencies, which is what makes rank-assigned additive resynthesis
// warble. Matching each peak to the voice already nearest it keeps a voice on
// its own partial for as long as that partial exists.
fun void assignVoices() {
    for (0 => int i; i < MAX_SINES; i++) {
        0 => taken[i];
        0.0 => targetGain[i];   // anything unclaimed fades out
    }

    // Levels are measured against the loudest peak rather than an absolute
    // magnitude, so the balance between the sines stays put however hard the
    // instrument is played. Slot 0 is that reference and sits at VOICE_GAIN.
    g_peak_mags[0] => float ref;

    // only voice as many peaks as the user asked for, and only ones that exist
    activeSines => int n;
    if (g_peak_count < n) g_peak_count => n;

    for (0 => int j; j < n; j++) {
        g_peak_freqs[j] => float f;
        if (f <= 0.0) continue;

        // 1) the free voice already closest to this frequency, if any is close
        //    enough. A voice that has faded out keeps its frequency, so a
        //    partial that briefly dips below the threshold reclaims the same
        //    oscillator instead of restarting on another one.
        -1 => int best;
        MAX_TRACK_OCTAVES => float bestDist;
        for (0 => int i; i < MAX_SINES; i++) {
            if (taken[i]) continue;
            if (targetFreq[i] <= 0.0) continue;
            Math.fabs(Math.log2(f / targetFreq[i])) => float d;
            if (d < bestDist) { d => bestDist; i => best; }
        }

        // 2) otherwise take the quietest free voice, so a new partial
        //    interrupts the least audible oscillator rather than a loud one.
        //    The envelope's current value is the audible level — osc.gain is a
        //    constant 1.0 now that the envelope carries the level.
        if (best < 0) {
            for (0 => int i; i < MAX_SINES; i++) {
                if (taken[i]) continue;
                if (best < 0 || env[i].value() < env[best].value()) i => best;
            }
        }
        if (best < 0) continue;   // every voice already claimed

        1 => taken[best];
        f => targetFreq[best];

        // this partial's strength relative to the loudest (1.0 if no reference)
        1.0 => float scaled;
        if (ref > 0.0) g_peak_mags[j] / ref => scaled;
        // morph: 0 -> flat (1.0 for every sine), 1 -> fully scaled
        1.0 + magTrack * (scaled - 1.0) => float shape;
        VOICE_GAIN * shape => targetGain[best];
    }
}

// ===== GLIDE =====
// Level is handed to the Envelope, which ramps it in the audio graph — this
// loop only ever sets a target, never a level, so its tick rate can't put steps
// into the signal. Frequency is glided here instead, which is safe: changing a
// SinOsc's frequency keeps its phase continuous, so it slides rather than
// clicks. A silent voice snaps instead, so re-acquiring a distant partial
// doesn't sweep audibly on the way in.
0.30 => float FREQ_SMOOTH;

fun void glide() {
    for (0 => int i; i < MAX_SINES; i++) {
        env[i].target(targetGain[i]);

        if (targetFreq[i] > 0.0) {
            if (env[i].value() < SILENT_LEVEL) {
                targetFreq[i] => osc[i].freq;
            } else {
                osc[i].freq() => float f;
                f + (targetFreq[i] - f) * FREQ_SMOOTH => osc[i].freq;
            }
        }
    }
}

<<< "[spectral-sines] ready — voicing the shared peak detector" >>>;

// 5 ms, like theremin.ck. The detector only publishes every ~46 ms, but the
// glide has to run much finer than that — stepping once per hop is exactly the
// ~21 Hz zipper noise this is here to avoid.
5::ms => dur TICK;

while (true) {
    readParams();
    assignVoices();
    glide();
    TICK => now;
}
