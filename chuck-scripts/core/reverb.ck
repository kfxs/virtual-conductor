// reverb.ck — the shared reverb bus. A core shred: always running, never added
// or removed. Modules no longer own reverbs; they patch a send gain into
// g_reverb_in_l/r and this shred returns the wet signal to the dac.
//
// Topology, per channel:
//   predelay -> 4 damped combs in parallel -> 2 allpasses in series -> return
//
// Built from DelayL + LPF rather than NRev because NRev's decay is fixed
// internally (~1s) and only its mix is exposed — too little control for the one
// reverb every module shares. Here decay, damping, predelay and size are real
// knobs.
//
// Params arrive from osc-router.ck as normalized 0..1 globals, same contract as
// the modules: 0 -> minimum, 1 -> maximum.
//
// Signal direction is one-way: core/delay.ck may send into this bus, this bus
// never sends back. Nothing here feeds a module.

// ===== BUILDING BLOCKS =====

// One damped comb filter. The delayed signal feeds back through a lowpass, so
// every trip round the loop loses more high end — that lowpass corner is the
// "damping" control, and the feedback gain is "decay".
class DampedComb extends Chugraph
{
    Gain node;
    DelayL line;
    LPF damp;
    Gain fb;

    100::ms => line.max;      // longest tuning below, times the largest size scale
    30::ms   => line.delay;
    0.8      => fb.gain;
    5000.0   => damp.freq;

    inlet => node => line => outlet;
    line => damp => fb => node;   // feedback loop, broken by the delay

    fun void set( dur t, float g, float cutoff )
    {
        t => line.delay;
        g => fb.gain;
        cutoff => damp.freq;
    }
}

// Schroeder allpass:  v[n] = x[n] + g*v[n-M],  y[n] = v[n-M] - g*v[n].
// Diffuses the comb bank's output so the tail stops sounding metallic.
class Allpass extends Chugraph
{
    Gain v;
    DelayL line;
    Gain fb;    // +g on the delayed signal, back into v
    Gain ff;    // -g on the undelayed signal, straight to the output

    20::ms => line.max;
    5::ms  => line.delay;
    0.5    => fb.gain;
    -0.5   => ff.gain;

    inlet => v => line => outlet;
    line => fb => v;
    v => ff => outlet;

    fun void set( dur t, float g )
    {
        t => line.delay;
        g => fb.gain;
        -g => ff.gain;
    }
}

// ===== BUS =====

// What modules send into. Declared global so any shred can patch into it.
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

// predelay — the gap before the tail starts, keeps the source readable
DelayL preL, preR;
120::ms => preL.max;
120::ms => preR.max;
1::ms => preL.delay;
1::ms => preR.delay;

g_reverb_in_l => preL;
g_reverb_in_r => preR;

// comb tunings in ms — mutually prime-ish lengths so their peaks don't line up.
// The right channel is offset slightly from the left, which is what makes the
// tail stereo rather than two copies of the same thing.
[29.7, 37.1, 41.1, 43.7] @=> float COMB_MS_L[];
[30.5, 37.9, 41.9, 44.5] @=> float COMB_MS_R[];
COMB_MS_L.size() => int NCOMB;

DampedComb combL[NCOMB];
DampedComb combR[NCOMB];

// the combs run in parallel and are summed; scale so four of them don't clip
Gain sumL, sumR;
0.25 => sumL.gain;
0.25 => sumR.gain;
for( 0 => int i; i < NCOMB; i++ )
{
    preL => combL[i] => sumL;
    preR => combR[i] => sumR;
}

Allpass apL1, apL2, apR1, apR2;
apL1.set( 5.0::ms, 0.5 );
apL2.set( 1.7::ms, 0.5 );
apR1.set( 5.6::ms, 0.5 );
apR2.set( 2.3::ms, 0.5 );

// the return level — how much of the wet signal reaches the dac
Gain returnL, returnR;
1.0 => returnL.gain;
1.0 => returnR.gain;

sumL => apL1 => apL2 => returnL => dac.left;
sumR => apR1 => apR2 => returnR => dac.right;

// ===== PARAMETERS =====
// Normalized 0..1 from osc-router.ck; mapped into the ranges below.
global float g_reverb_decay;
global float g_reverb_damping;
global float g_reverb_predelay;
global float g_reverb_size;
global float g_reverb_return;

// comb feedback gain — must stay below 1.0 or the tail never dies
0.70  => float DECAY_MIN;      0.95  => float DECAY_MAX;
// damping is a lowpass corner, so it runs bright -> dark as the param goes 0 -> 1
18000.0 => float DAMP_BRIGHT;  800.0 => float DAMP_DARK;
1::ms => dur PREDELAY_MIN;     100::ms => dur PREDELAY_MAX;
// size scales every comb length — small room to large hall
0.5 => float SIZE_MIN;         1.5 => float SIZE_MAX;
// return level, 0.5 -> unity, matching the modules' mastervol convention
0.0 => float RETURN_MIN;       2.0 => float RETURN_MAX;

// map a normalized 0..1 into a float range
fun float mapF(float g, float lo, float hi) { return lo + g * (hi - lo); }
// map a normalized 0..1 into a duration range (work in ms, return dur)
fun dur mapD(float g, dur lo, dur hi) { return (lo/ms + g * (hi/ms - lo/ms))::ms; }
// exponential map — for the damping corner, where linear Hz feels wrong
fun float expMapF(float g, float lo, float hi) { return lo * Math.pow(hi / lo, g); }
// guard against an out-of-range value arriving before Python's first frame
fun float clampN(float g) { return Math.max(0.0, Math.min(1.0, g)); }

fun void apply()
{
    mapF(   clampN(g_reverb_decay),    DECAY_MIN,     DECAY_MAX )   => float fb;
    expMapF(clampN(g_reverb_damping),  DAMP_BRIGHT,   DAMP_DARK )   => float cutoff;
    mapF(   clampN(g_reverb_size),     SIZE_MIN,      SIZE_MAX )    => float size;
    mapD(   clampN(g_reverb_predelay), PREDELAY_MIN,  PREDELAY_MAX) => dur   pre;
    mapF(   clampN(g_reverb_return),   RETURN_MIN,    RETURN_MAX )  => float ret;

    pre => preL.delay;
    pre => preR.delay;

    for( 0 => int i; i < NCOMB; i++ )
    {
        combL[i].set( (COMB_MS_L[i] * size)::ms, fb, cutoff );
        combR[i].set( (COMB_MS_R[i] * size)::ms, fb, cutoff );
    }

    ret => returnL.gain;
    ret => returnR.gain;
}

<<< "[reverb] bus ready" >>>;

while( true )
{
    apply();
    10::ms => now;
}
