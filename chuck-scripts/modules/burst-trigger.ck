// burst-trigger.ck
// Fires a short noise burst on each /trigger/burst event from Python.
// Python sends the bang the instant the trigger fires (GUI button now, a MIDI
// pad later), so this stays decoupled from the camera/GUI frame rate.

// Shared trigger event — signalled by osc-router.ck when /trigger/burst arrives.
global Event g_burst_fire;

// how much of this module to send into the shared delay/reverb buses
global float g_burst_trigger_delaysend;
global float g_burst_trigger_reverbsend;

// --- mix bus (bursts patch into here) ---
Gain mix => dac;
0.5 => mix.gain;

// fx sends into the shared buses (core/delay.ck, core/reverb.ck). Mono source,
// so one send gain per bus feeds both channels. Tapped off the mix bus, so
// every burst is sent, not just the one that's currently sounding.
global Gain g_delay_in_l;
global Gain g_delay_in_r;
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

Gain delaySend, reverbSend;
0.0 => delaySend.gain;
0.0 => reverbSend.gain;

mix => delaySend  => g_delay_in_l;
       delaySend  => g_delay_in_r;
mix => reverbSend => g_reverb_in_l;
       reverbSend => g_reverb_in_r;

// The main loop below blocks on the trigger event, so the send amounts are
// tracked in their own shred.
fun void sendControl()
{
    while( true )
    {
        Math.max(0.0, Math.min(1.0, g_burst_trigger_delaysend))  => delaySend.gain;
        Math.max(0.0, Math.min(1.0, g_burst_trigger_reverbsend)) => reverbSend.gain;
        10::ms => now;
    }
}
spork ~ sendControl();

while( true )
{
    g_burst_fire => now;        // wait for the next trigger
    spork ~ burst();
}

// one burst: white noise through a quick AR envelope, then the shred ends
// and the local ugens are disconnected + reclaimed automatically
fun void burst()
{
    Noise n => Envelope env => mix;
    0.3 => n.gain;
    0::ms => env.duration;
    1.0 => env.target;          // snap open (attack)
    2::ms => now;

    80::ms => env.duration;     // gentle decay
    0.0 => env.target;
    80::ms => now;
}
