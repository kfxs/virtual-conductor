// input.ck — shared audio input bus.
//
// The input source is selectable between "fake-theorbo" (loops tiorba.wav, for
// developing without a real instrument) and "mic" (live adc, e.g. Pedro's
// theorbo). The source feeds the global Gain g_mic at its natural level, so fx
// modules tap the raw source. Only this shred sends the input to the output.
//
// Python controls it: g_input_volume (0..1, the dry monitor's output volume —
// does NOT affect what the fx receive) and g_input_source (0 = fake-theorbo,
// 1 = mic).

global Gain g_mic;
global float g_input_volume;      // 0..1 from Python; 0.5 = unity. Monitor only.
global float g_input_source;      // 0 = fake-theorbo, 1 = mic
// how much of the monitored input to send into the shared delay/reverb buses
global float g_input_delaysend;
global float g_input_reverbsend;

// Sources feed g_mic raw (unity) — fx modules tap g_mic. The volume slider
// scales only the monitor path g_mic => outGain => dac, so output volume never
// changes the level going into the fx modules.
g_mic => Gain outGain => dac;

// fx sends into the shared buses (core/delay.ck, core/reverb.ck) — this is how
// the raw instrument itself gets delayed/reverbed, without going through a
// module. Tapped post-fader (after outGain), like every module's sends, so the
// monitor volume fades the tails with it.
global Gain g_delay_in_l;
global Gain g_delay_in_r;
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

Gain delaySend, reverbSend;
0.0 => delaySend.gain;
0.0 => reverbSend.gain;

outGain => delaySend  => g_delay_in_l;
           delaySend  => g_delay_in_r;
outGain => reverbSend => g_reverb_in_l;
           reverbSend => g_reverb_in_r;

// fake-theorbo source (looped wav); the mic source is the live adc
SndBuf fakeTheorbo;
me.dir() + "/../../samples/tiorba.wav" => fakeTheorbo.read;
1 => fakeTheorbo.loop;
1.0 => fakeTheorbo.rate;

// start on fake-theorbo (matches g_input_source default of 0)
fakeTheorbo => g_mic;
0.0 => float curSource;

<<< "[input] ready — source: fake-theorbo" >>>;

while( true ) {
    g_input_volume * 2.0 => outGain.gain;

    Math.max(0.0, Math.min(1.0, g_input_delaysend))  => delaySend.gain;
    Math.max(0.0, Math.min(1.0, g_input_reverbsend)) => reverbSend.gain;

    // repatch when the source selection changes
    if( g_input_source != curSource ) {
        if( g_input_source > 0.5 ) {
            fakeTheorbo =< g_mic;
            adc => g_mic;            // mic
            <<< "[input] source: mic" >>>;
        } else {
            adc =< g_mic;            // mic off
            fakeTheorbo => g_mic;
            <<< "[input] source: fake-theorbo" >>>;
        }
        g_input_source => curSource;
    }

    10::ms => now;
}
