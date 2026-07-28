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

// Sources feed g_mic raw (unity) — fx tap g_mic. The volume slider scales only
// the monitor path g_mic => outGain => dac, so output volume never changes the
// level going into the fx.
g_mic => Gain outGain => dac;

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
