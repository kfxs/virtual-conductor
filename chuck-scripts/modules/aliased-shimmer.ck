// aliased-shimmer.ck — a hold-to-record looper built on LiSa2 (live sampling).
// Audio input is the shared g_mic bus from core/input.ck.
//
// Double-buffered: two LiSa2 buffers, A and B. One (playBuf) loops the last take
// while the other (recBuf) records the next one, so the old loop keeps playing
// during recording; they swap on gate-release. Each take plays back on four
// voices at rates 1x/2x/4x/8x, with per-voice volume.
//
// Behaviour, driven by the osc-router globals:
//   collect gate HELD  -> record g_mic into recBuf (old loop keeps playing)
//   collect gate RELEASED -> play the new take, swap buffers
//   clear trigger      -> empty both buffers and stop playback

global Gain g_mic;

// "collect" gate from osc-router.ck: 1 while held (GUI button pressed or a
// learned MIDI pad), 0 when released. Held = record, released = loop-play.
global float g_aliased_shimmer_collect;

// "clear" trigger from osc-router.ck: a one-shot, delivered as a 0->1 edge. We
// detect the rise, act once, then reset it to 0 to consume it.
global int g_aliased_shimmer_clear;

// per-voice volumes for the 1x/2x/4x/8x layers, normalized 0..1 (applied as
// LiSa voiceGain), plus the overall master volume mapped into [0, MASTER_VOL_MAX]
// gain (0.5 -> unity), like granulator's mastervol.
global float g_aliased_shimmer_vol1x;
global float g_aliased_shimmer_vol2x;
global float g_aliased_shimmer_vol4x;
global float g_aliased_shimmer_vol8x;
// stereo spread (pan LFO width) and per-pitched-voice pan LFO rates. The
// principal (1x) stays centered and unpanned.
global float g_aliased_shimmer_spread;
global float g_aliased_shimmer_lforate2x;
global float g_aliased_shimmer_lforate4x;
global float g_aliased_shimmer_lforate8x;
global float g_aliased_shimmer_mastervol;
// how much of this module to send into the shared delay/reverb buses
global float g_aliased_shimmer_delaysend;
global float g_aliased_shimmer_reverbsend;

// ===== CONSTANTS =====
60::second => dur MAX_BUF;       // longest single hold-to-record we can capture (1 min)
100::ms => dur RAMP;              // record fade in/out — see recRamp below
0.0 => float MASTER_VOL_MIN;     // 0..1 mastervol maps into [MIN, MAX] gain
2.0 => float MASTER_VOL_MAX;     // (0.5 -> 1.0 unity), like granulator
[1.0, 2.0, 4.0, 8.0] @=> float RATES[];   // the four loop layers
RATES.size() => int NVOICES;
2.0 => float LFO_MAX_HZ;                   // lforate 1.0 -> this many Hz
5::ms => dur TICK;                         // control loop period (drives the LFOs)
(TICK / 1::second) => float DT;            // TICK in seconds, for LFO phase steps
float panPhase[NVOICES];                   // pan LFO phase per voice (voice 0 unused)

// ===== AUDIO SETUP =====
// g_mic feeds both LiSa2 buffers as the record source; each buffer's main out
// goes to a sink (blackhole) and the audible signal comes from its per-channel
// playback taps, exactly like granulator.ck. Both feed the shared master gains,
// so whichever buffer is playing is heard.
g_mic => LiSa2 bufA => blackhole;
g_mic => LiSa2 bufB => blackhole;

Gain masterL, masterR;
1.0 => masterL.gain => masterR.gain;
masterL => dac.left;
masterR => dac.right;
bufA.chan(0) => masterL;  bufA.chan(1) => masterR;
bufB.chan(0) => masterL;  bufB.chan(1) => masterR;

// fx sends into the shared delay/reverb buses (core/delay.ck, core/reverb.ck).
// Tapped post-fader (after masterL/R) so pulling mastervol down fades the tails
// with it.
global Gain g_delay_in_l;
global Gain g_delay_in_r;
global Gain g_reverb_in_l;
global Gain g_reverb_in_r;

Gain delaySendL, delaySendR, reverbSendL, reverbSendR;
0.0 => delaySendL.gain => delaySendR.gain;
0.0 => reverbSendL.gain => reverbSendR.gain;

masterL => delaySendL  => g_delay_in_l;
masterR => delaySendR  => g_delay_in_r;
masterL => reverbSendL => g_reverb_in_l;
masterR => reverbSendR => g_reverb_in_r;

// double-buffer roles: playBuf loops the last take, recBuf captures the next.
bufA @=> LiSa2 playBuf;
bufB @=> LiSa2 recBuf;

// ===== HELPERS =====
fun void initBuf(LiSa2 b) {
    b.duration( MAX_BUF );
    b.maxVoices( NVOICES );
    0 => b.loopRec;              // recording stops at the buffer end, doesn't wrap
    b.recRamp( RAMP );           // fade the recording in/out so the captured buffer
                                 // starts and ends at zero — no click at the loop seam
    0 => b.record;               // start idle
}

// map a normalized 0..1 into a float range, like granulator's mapF
fun float mapF(float g, float lo, float hi) { return lo + g * (hi - lo); }

// clamp into the gain range and apply to both master channels, like
// granulator's setMasterVol
fun void setMasterVol(float val) {
    Math.max(Math.min(val, MASTER_VOL_MAX), MASTER_VOL_MIN) => masterL.gain => masterR.gain;
}

// fx send amounts, normalized 0..1 straight through to the send gains
fun void setSends() {
    Math.max(0.0, Math.min(1.0, g_aliased_shimmer_delaysend))
        => delaySendL.gain => delaySendR.gain;
    Math.max(0.0, Math.min(1.0, g_aliased_shimmer_reverbsend))
        => reverbSendL.gain => reverbSendR.gain;
}

// apply the per-voice volumes (normalized 0..1) to the playing buffer's voices
fun void setVoiceVols() {
    playBuf.voiceGain( 0, g_aliased_shimmer_vol1x );
    playBuf.voiceGain( 1, g_aliased_shimmer_vol2x );
    playBuf.voiceGain( 2, g_aliased_shimmer_vol4x );
    playBuf.voiceGain( 3, g_aliased_shimmer_vol8x );
}

// advance one voice's pan LFO and apply it: pan swings around center by
// +/-(spread/2), at rateNorm * LFO_MAX_HZ.
fun void panVoice(int v, float rateNorm, float spread) {
    2.0 * Math.PI * rateNorm * LFO_MAX_HZ * DT +=> panPhase[v];
    0.5 + spread * 0.5 * Math.sin( panPhase[v] ) => float p;
    playBuf.pan( v, p );
}

// apply the pan LFOs. Principal (voice 0) stays centered; 2x/4x/8x each pan
// with their own LFO rate, width set by the shared spread.
fun void setVoicePans() {
    g_aliased_shimmer_spread => float spread;
    playBuf.pan( 0, 0.5 );
    panVoice( 1, g_aliased_shimmer_lforate2x, spread );
    panVoice( 2, g_aliased_shimmer_lforate4x, spread );
    panVoice( 3, g_aliased_shimmer_lforate8x, spread );
}

// stop all loop voices on a buffer
fun void stopVoices(LiSa2 b) {
    for( 0 => int v; v < NVOICES; v++ ) {
        b.play( v, 0 );
        b.loop( v, 0 );
    }
}

// start one voice per layer on a buffer: same region, rates 1x/2x/4x/8x
fun void startVoices(LiSa2 b, dur recLen) {
    for( 0 => int v; v < NVOICES; v++ ) {
        b.loopStart( v, 0::ms );
        b.loopEnd( v, recLen );
        b.loop( v, 1 );
        b.rate( v, RATES[v] );
        b.pan( v, 0.5 );             // center to start; setVoicePans drives it after
        b.playPos( v, 0::ms );
        b.play( v, 1 );
    }
}

// gate rising edge: record into recBuf from its start (playBuf keeps playing)
fun void startRecording() {
    recBuf.recPos( 0::ms );
    1 => recBuf.record;
}

// gate falling edge: stop recording, play the new take, swap buffers
fun void startLoop() {
    0 => recBuf.record;
    RAMP => now;                     // let the record fade-out finish writing the
                                     // tail so recPos covers it (loopEnd at zero)
    recBuf.recPos() => dur recLen;   // how much we actually captured
    if( recLen <= 1::ms ) return;    // nothing meaningful recorded; keep old loop
    stopVoices( playBuf );           // stop the previous take
    startVoices( recBuf, recLen );   // play the new one
    // swap roles: the take we just recorded becomes the player; the old player
    // becomes the next record target
    playBuf @=> LiSa2 tmp;
    recBuf @=> playBuf;
    tmp @=> recBuf;
    setVoiceVols();                  // apply gains to the new player right away
}

// clear trigger: stop everything and empty both buffers
fun void clearBuffer() {
    0 => bufA.record;  0 => bufB.record;
    stopVoices( bufA );  stopVoices( bufB );
    bufA.clear();  bufB.clear();
}

// ===== INIT =====
initBuf( bufA );
initBuf( bufB );

// ===== CONTROL LOOP =====
// Poll the gate for its edges and dispatch the looper actions. 5 ms is fine for
// hand/MIDI-driven control; recPos() gives the sample-accurate recorded length.
0 => int gateOpen;
while( true )
{
    // track the volumes + pan LFOs each tick
    setVoiceVols();
    setVoicePans();
    setMasterVol( mapF(g_aliased_shimmer_mastervol, MASTER_VOL_MIN, MASTER_VOL_MAX) );
    setSends();

    (g_aliased_shimmer_collect > 0.5) => int nowOpen;
    if( nowOpen && !gateOpen ) startRecording();   // rising edge
    if( !nowOpen && gateOpen ) startLoop();         // falling edge
    nowOpen => gateOpen;

    // clear trigger: any pending 0->1 fires once, then we reset to consume it.
    if( g_aliased_shimmer_clear != 0 )
    {
        0 => g_aliased_shimmer_clear;
        clearBuffer();
    }

    TICK => now;
}
