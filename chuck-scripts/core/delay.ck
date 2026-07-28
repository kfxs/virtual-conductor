// delay.ck — the shared dual (ping-pong) delay bus. A core shred: always
// running, never added or removed. Modules patch a send gain into
// g_delay_in_l/r and this shred returns the delayed signal to the dac.
//
// Left and right have independent delay times and cross-feed each other, so a
// signal bounces L -> R -> L across the stereo field. Lifted out of
// granulator.ck, which used to own its own copy of this.
//
// The delay also has its own send into the reverb bus (toreverb), so the tails
// can be reverbed. That path is one-directional — the reverb never feeds back
// into the delay, which with the cross-feedback here would run away.
//
// Params arrive from osc-router.ck as normalized 0..1 globals: 0 -> minimum,
// 1 -> maximum.

// what modules send into
global Gain g_delay_in_l;
global Gain g_delay_in_r;

// the reverb bus (core/reverb.ck), so the delay can feed its tails into it
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

// ===== AUDIO SETUP =====
DelayL delL, delR;
1.05::second => delL.max;
1.05::second => delR.max;
300::ms => delL.delay;
400::ms => delR.delay;

g_delay_in_l => delL;
g_delay_in_r => delR;

// cross feedback: left output -> right input, right output -> left input
Gain xfbL, xfbR;
0.5 => xfbL.gain;
0.5 => xfbR.gain;
delL => xfbR => delR;
delR => xfbL => delL;

// return level — how much of the delayed signal reaches the dac
Gain returnL, returnR;
1.0 => returnL.gain;
1.0 => returnR.gain;
delL => returnL => dac.left;
delR => returnR => dac.right;

// send into the reverb bus
Gain toRevL, toRevR;
0.0 => toRevL.gain;
0.0 => toRevR.gain;
delL => toRevL => g_reverb_in_l;
delR => toRevR => g_reverb_in_r;

// ===== PARAMETERS =====
global float g_delay_timeleft;    // left channel delay time
global float g_delay_timeright;   // right channel delay time
global float g_delay_feedback;
global float g_delay_toreverb;
global float g_delay_returnvol;

50::ms => dur DELAY_TIME_MIN;   1000::ms => dur DELAY_TIME_MAX;
0.0 => float FEEDBACK_MIN;      0.95 => float FEEDBACK_MAX;   // < 1 or it runs away
0.0 => float TO_REVERB_MIN;     1.0  => float TO_REVERB_MAX;
// return level, 0.5 -> unity, matching the modules' mastervol convention
0.0 => float RETURN_MIN;        2.0  => float RETURN_MAX;

// map a normalized 0..1 into a float range
fun float mapF(float g, float lo, float hi) { return lo + g * (hi - lo); }
// map a normalized 0..1 into a duration range (work in ms, return dur)
fun dur mapD(float g, dur lo, dur hi) { return (lo/ms + g * (hi/ms - lo/ms))::ms; }
// guard against an out-of-range value arriving before Python's first frame
fun float clampN(float g) { return Math.max(0.0, Math.min(1.0, g)); }

fun void apply()
{
    mapD( clampN(g_delay_timeleft),  DELAY_TIME_MIN, DELAY_TIME_MAX ) => delL.delay;
    mapD( clampN(g_delay_timeright), DELAY_TIME_MIN, DELAY_TIME_MAX ) => delR.delay;

    mapF( clampN(g_delay_feedback), FEEDBACK_MIN, FEEDBACK_MAX ) => float fb;
    fb => xfbL.gain;
    fb => xfbR.gain;

    mapF( clampN(g_delay_toreverb), TO_REVERB_MIN, TO_REVERB_MAX ) => float send;
    send => toRevL.gain;
    send => toRevR.gain;

    mapF( clampN(g_delay_returnvol), RETURN_MIN, RETURN_MAX ) => float ret;
    ret => returnL.gain;
    ret => returnR.gain;
}

<<< "[delay] bus ready" >>>;

while( true )
{
    apply();
    10::ms => now;
}
