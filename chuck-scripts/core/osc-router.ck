// osc-router.ck — receives final parameter values from Python and writes them
// straight to the effect globals.
//
// Python owns all routing: it decides per param whether to use the slider or a
// landmark, resolves one value, and sends it on /param/<module>/<param>. ChucK
// does no routing or landmark handling — it just plays the value it's given.

// --- Effect parameter globals (modules read these; declared here too so they
// exist and sit at a neutral value before any module is added) ---
global float g_theremin_pitch;
global float g_theremin_volume;
global float g_synth_pitch;
global float g_synth_cutoff;

// input (input.ck) — shared input: monitor volume + source selection
global float g_input_volume;
global float g_input_source;   // 0 = fake-theorbo, 1 = mic

// --- Shared fx buses (core/delay.ck, core/reverb.ck) ---
// The delay and reverb are core shreds now, not per-module effects: every
// module sends into them and they return to the dac. Each sound source has a
// delaysend/reverbsend pair (how much of itself to send), and the buses
// themselves own the actual delay/reverb settings.
global float g_delay_timeleft;    // left channel delay time
global float g_delay_timeright;   // right channel delay time
global float g_delay_feedback;
global float g_delay_toreverb;   // the delay's own send into the reverb
global float g_delay_returnvol;

global float g_reverb_decay;
global float g_reverb_damping;
global float g_reverb_predelay;
global float g_reverb_size;
global float g_reverb_returnvol;

// per-source send amounts
global float g_input_delaysend;
global float g_input_reverbsend;
global float g_theremin_delaysend;
global float g_theremin_reverbsend;
global float g_synth_delaysend;
global float g_synth_reverbsend;
global float g_burst_trigger_delaysend;
global float g_burst_trigger_reverbsend;
global float g_aliased_shimmer_delaysend;
global float g_aliased_shimmer_reverbsend;
global float g_granulator_delaysend;
global float g_granulator_reverbsend;
global float g_spectral_sines_delaysend;
global float g_spectral_sines_reverbsend;

// peak-detector (core) — the one shared FFT. It owns the band the peak search
// runs over, since that describes the analysis every consumer sees.
global float g_peak_detector_minfreq;
global float g_peak_detector_maxfreq;
global float g_peak_detector_thresh;    // relative floor under the loudest peak

// spectral-sines — sounds a sine on each peak the detector publishes. It does
// no analysis of its own; sines is just how many of them sing.
global float g_spectral_sines_sines;     // 1..8, loudest peaks first
global float g_spectral_sines_magtrack;  // 0 = flat, 1 = scaled by peak magnitude
global float g_spectral_sines_mastervol;

// burst-trigger — a momentary event, not a held value. Python sends a bang on
// /trigger/burst the instant the trigger fires (GUI button now, a MIDI pad
// later); burst-trigger.ck waits on this and fires one burst per signal. Being
// event-driven, it never rides the camera/GUI frame rate.
global Event g_burst_fire;

// aliased-shimmer — the "collect" gate. A held 0/1 state, not an event: Python
// sends 1 the instant the gate opens (GUI button pressed or a MIDI pad note-on)
// and 0 when it closes (button released / note-off), on /gate/collect. A float
// the module polls.
global float g_aliased_shimmer_collect;

// aliased-shimmer — the "clear" trigger. A one-shot event delivered as a 0->1
// edge: Python sends a bang on /trigger/clear, we set this to 1, and the module
// detects the rise, acts once, and resets it to 0 (consumes it).
global int g_aliased_shimmer_clear;

// aliased-shimmer — per-voice volumes (the 1x/2x/4x/8x layers) and the overall
// master volume. Normalized 0..1; the module maps them to gains.
global float g_aliased_shimmer_vol1x;
global float g_aliased_shimmer_vol2x;
global float g_aliased_shimmer_vol4x;
global float g_aliased_shimmer_vol8x;
global float g_aliased_shimmer_spread;     // stereo spread (pan LFO width)
global float g_aliased_shimmer_lforate2x;  // pan LFO rate, per pitched voice
global float g_aliased_shimmer_lforate4x;
global float g_aliased_shimmer_lforate8x;
global float g_aliased_shimmer_mastervol;

// granulator — every param is a normalized 0..1 value; granulator.ck maps each
// into its [MIN, MAX] range.
global float g_granulator_grainsize;
global float g_granulator_density;
global float g_granulator_position;
global float g_granulator_posspray;
global float g_granulator_panspray;
global float g_granulator_octaveup;
global float g_granulator_octavedown;
global float g_granulator_pitchrange;
global float g_granulator_pitchprob;
global float g_granulator_finerange;
global float g_granulator_fineprob;
global float g_granulator_thresh;
global float g_granulator_attack;
global float g_granulator_release;
global float g_granulator_mastervol;

0.5 => g_theremin_pitch;
0.5 => g_theremin_volume;
0.5 => g_synth_pitch;
0.5 => g_synth_cutoff;

0.5 => g_input_volume;
0.0 => g_input_source;   // 0 = fake-theorbo (default), 1 = mic

0.0 => g_aliased_shimmer_collect;   // gate closed at start
0 => g_aliased_shimmer_clear;    // no pending trigger at start
0.5 => g_aliased_shimmer_vol1x;
0.5 => g_aliased_shimmer_vol2x;
0.5 => g_aliased_shimmer_vol4x;
0.5 => g_aliased_shimmer_vol8x;
0.5 => g_aliased_shimmer_spread;
0.5 => g_aliased_shimmer_lforate2x;
0.5 => g_aliased_shimmer_lforate4x;
0.5 => g_aliased_shimmer_lforate8x;
0.5 => g_aliased_shimmer_mastervol;   // unity once mapped (0.5 -> 1.0)

0.5 => g_granulator_grainsize;
0.5 => g_granulator_density;
0.5 => g_granulator_position;
0.5 => g_granulator_posspray;
0.5 => g_granulator_panspray;
0.5 => g_granulator_octaveup;
0.5 => g_granulator_octavedown;
0.5 => g_granulator_pitchrange;
0.5 => g_granulator_pitchprob;
0.5 => g_granulator_finerange;
0.5 => g_granulator_fineprob;
0.5 => g_granulator_thresh;
0.5 => g_granulator_attack;
0.5 => g_granulator_release;
0.5 => g_granulator_mastervol;

// Shared fx buses. Delay times start at 300 ms / 400 ms (the ping-pong offset
// granulator used to have), the returns at unity. Every send starts at 0 so
// nothing is drenched in fx the moment the VM boots — the GUI overwrites these
// with the saved slider values on its first frame anyway, but until then the
// buses stay silent rather than blasting.
0.26 => g_delay_timeleft;     // ~300 ms in the 50..1000 ms range
0.37 => g_delay_timeright;    // ~400 ms
0.5  => g_delay_feedback;
0.0  => g_delay_toreverb;
0.5  => g_delay_returnvol;       // 0.5 -> unity

0.5 => g_reverb_decay;
0.5 => g_reverb_damping;
0.0 => g_reverb_predelay;
0.5 => g_reverb_size;
0.5 => g_reverb_returnvol;       // 0.5 -> unity

0.0 => g_input_delaysend;
0.0 => g_input_reverbsend;
0.0 => g_theremin_delaysend;
0.0 => g_theremin_reverbsend;
0.0 => g_synth_delaysend;
0.0 => g_synth_reverbsend;
0.0 => g_burst_trigger_delaysend;
0.0 => g_burst_trigger_reverbsend;
0.0 => g_aliased_shimmer_delaysend;
0.0 => g_aliased_shimmer_reverbsend;
0.0 => g_granulator_delaysend;
0.0 => g_granulator_reverbsend;
0.0 => g_spectral_sines_delaysend;
0.0 => g_spectral_sines_reverbsend;

// peak-detector / spectral-sines — start where the test script was tuned:
// searching 60..2000 Hz, with four peaks sounding.
0.043 => g_peak_detector_minfreq;     // ~60 Hz in the 40..500 Hz range
0.333 => g_peak_detector_maxfreq;     // ~2000 Hz in the 500..5000 Hz range
0.2   => g_peak_detector_thresh;      // peaks must reach 10% of the loudest
0.43  => g_spectral_sines_sines;      // 4 of 8
0.75  => g_spectral_sines_magtrack;   // mostly follows each partial's strength
0.5   => g_spectral_sines_mastervol;  // unity once mapped (0.5 -> 1.0)

OscIn oin;
OscMsg msg;
8000 => oin.port;
oin.listenAll();   // catch every address; we dispatch on the path ourselves

<<< "[osc-router] listening on port", oin.port() >>>;

// Split an OSC address into its non-empty path segments.
// "/param/synth/pitch" -> ["param","synth","pitch"]
fun string[] segments( string addr )
{
    string out[0];
    addr => string rest;
    while( rest.length() > 0 )
    {
        rest.find( "/" ) => int i;
        if( i < 0 ) { out << rest; break; }   // last segment
        if( i > 0 ) out << rest.substring( 0, i );
        rest.substring( i + 1 ) => rest;
    }
    return out;
}

while( true )
{
    oin => now;
    while( oin.recv( msg ) )
    {
        segments( msg.address ) @=> string seg[];

        // /trigger/<name> — a bang (no args). A momentary event, handled before
        // the /param guard. Signal the matching module's wait-event.
        if( seg.size() >= 2 && seg[0] == "trigger" )
        {
            if( seg[1] == "burst" ) g_burst_fire.broadcast();
            else if( seg[1] == "clear" ) 1 => g_aliased_shimmer_clear;
            continue;
        }

        // /gate/<name> — a held 0/1 state (button down/up or MIDI note on/off),
        // carrying one float. Handled before the /param guard.
        if( seg.size() >= 2 && seg[0] == "gate" && msg.numArgs() >= 1 )
        {
            if( seg[1] == "collect" ) msg.getFloat(0) => g_aliased_shimmer_collect;
            continue;
        }

        // /param/<module>/<param> carrying one float
        if( seg.size() < 3 || seg[0] != "param" || msg.numArgs() < 1 ) continue;

        seg[1] => string module;
        seg[2] => string param;
        msg.getFloat(0) => float v;

        if( module == "theremin" )
        {
            if(      param == "pitch" )      v => g_theremin_pitch;
            else if( param == "volume" )     v => g_theremin_volume;
            else if( param == "delaysend" )  v => g_theremin_delaysend;
            else if( param == "reverbsend" ) v => g_theremin_reverbsend;
        }
        else if( module == "synth" )
        {
            if(      param == "pitch" )      v => g_synth_pitch;
            else if( param == "cutoff" )     v => g_synth_cutoff;
            else if( param == "delaysend" )  v => g_synth_delaysend;
            else if( param == "reverbsend" ) v => g_synth_reverbsend;
        }
        else if( module == "input" )
        {
            if(      param == "volume" )     v => g_input_volume;
            else if( param == "source" )     v => g_input_source;
            else if( param == "delaysend" )  v => g_input_delaysend;
            else if( param == "reverbsend" ) v => g_input_reverbsend;
        }
        else if( module == "burst-trigger" )
        {
            if(      param == "delaysend" )  v => g_burst_trigger_delaysend;
            else if( param == "reverbsend" ) v => g_burst_trigger_reverbsend;
        }
        else if( module == "delay" )
        {
            if(      param == "timeleft" )  v => g_delay_timeleft;
            else if( param == "timeright" ) v => g_delay_timeright;
            else if( param == "feedback" )  v => g_delay_feedback;
            else if( param == "toreverb" )  v => g_delay_toreverb;
            else if( param == "returnvol" ) v => g_delay_returnvol;
        }
        else if( module == "reverb" )
        {
            if(      param == "decay" )    v => g_reverb_decay;
            else if( param == "damping" )  v => g_reverb_damping;
            else if( param == "predelay" ) v => g_reverb_predelay;
            else if( param == "size" )     v => g_reverb_size;
            else if( param == "returnvol" ) v => g_reverb_returnvol;
        }
        else if( module == "aliased-shimmer" )
        {
            if(      param == "vol1x" )     v => g_aliased_shimmer_vol1x;
            else if( param == "vol2x" )     v => g_aliased_shimmer_vol2x;
            else if( param == "vol4x" )     v => g_aliased_shimmer_vol4x;
            else if( param == "vol8x" )     v => g_aliased_shimmer_vol8x;
            else if( param == "spread" )    v => g_aliased_shimmer_spread;
            else if( param == "lforate2x" ) v => g_aliased_shimmer_lforate2x;
            else if( param == "lforate4x" ) v => g_aliased_shimmer_lforate4x;
            else if( param == "lforate8x" ) v => g_aliased_shimmer_lforate8x;
            else if( param == "mastervol" ) v => g_aliased_shimmer_mastervol;
            else if( param == "delaysend" ) v => g_aliased_shimmer_delaysend;
            else if( param == "reverbsend" ) v => g_aliased_shimmer_reverbsend;
        }
        else if( module == "granulator" )
        {
            if(      param == "grainsize" )  v => g_granulator_grainsize;
            else if( param == "density" )    v => g_granulator_density;
            else if( param == "position" )   v => g_granulator_position;
            else if( param == "posspray" )   v => g_granulator_posspray;
            else if( param == "panspray" )   v => g_granulator_panspray;
            else if( param == "octaveup" )   v => g_granulator_octaveup;
            else if( param == "octavedown" ) v => g_granulator_octavedown;
            else if( param == "pitchrange" ) v => g_granulator_pitchrange;
            else if( param == "pitchprob" )  v => g_granulator_pitchprob;
            else if( param == "finerange" )  v => g_granulator_finerange;
            else if( param == "fineprob" )   v => g_granulator_fineprob;
            else if( param == "thresh" )     v => g_granulator_thresh;
            else if( param == "attack" )     v => g_granulator_attack;
            else if( param == "release" )    v => g_granulator_release;
            else if( param == "delaysend" )  v => g_granulator_delaysend;
            else if( param == "reverbsend" ) v => g_granulator_reverbsend;
            else if( param == "mastervol" )  v => g_granulator_mastervol;
        }
        else if( module == "peak-detector" )
        {
            if(      param == "minfreq" ) v => g_peak_detector_minfreq;
            else if( param == "maxfreq" ) v => g_peak_detector_maxfreq;
            else if( param == "thresh" )  v => g_peak_detector_thresh;
        }
        else if( module == "spectral-sines" )
        {
            if(      param == "sines" )      v => g_spectral_sines_sines;
            else if( param == "magtrack" )   v => g_spectral_sines_magtrack;
            else if( param == "delaysend" )  v => g_spectral_sines_delaysend;
            else if( param == "reverbsend" ) v => g_spectral_sines_reverbsend;
            else if( param == "mastervol" )  v => g_spectral_sines_mastervol;
        }
        // else: unknown module/param — ignored
    }
}
