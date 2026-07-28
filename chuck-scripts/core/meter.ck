// meter.ck — master output level metering. A core shred: always running.
//
// Reads the summed output straight off the dac and reports the peak level of
// each channel to Python over OSC, so the GUI can show a meter and tell you
// when the mix is clipping.
//
// No audio-graph change and no master bus needed: dac.last() returns the SUM of
// everything patched into it, which is exactly what we want to measure. That
// matters here because there are a dozen independent paths into the dac (the
// input monitor, every module, both fx returns) and nothing else watches the
// total.
//
// Direction note: this is the one shred that sends OSC *out* to Python. Python
// listens on 8001; 8000 is ChucK's own inbound port (osc-router.ck).

"127.0.0.1" => string METER_HOST;
8001 => int METER_PORT;

OscOut xmit;
xmit.dest( METER_HOST, METER_PORT );

// How many samples to accumulate before reporting. Peak is tracked every single
// sample — anything coarser samples the waveform and would walk straight past
// the transients that actually clip — but reporting every sample would be
// absurd, so we send the running maximum once per block. 512 samples is ~86
// reports a second at 44.1k, far finer than the GUI can draw.
512 => int BLOCK;

// Digital full scale. A sample at or past this can't be represented by the
// converter, so it is clipping by definition.
0.999 => float CLIP_LEVEL;

<<< "[meter] ready — reporting output level to", METER_HOST + ":" + METER_PORT >>>;

while( true )
{
    0.0 => float peakL;
    0.0 => float peakR;
    0 => int clipped;

    for( 0 => int i; i < BLOCK; i++ )
    {
        1::samp => now;

        Math.fabs( dac.left.last() )  => float l;
        Math.fabs( dac.right.last() ) => float r;

        if( l > peakL ) l => peakL;
        if( r > peakR ) r => peakR;
    }

    if( peakL >= CLIP_LEVEL || peakR >= CLIP_LEVEL ) 1 => clipped;

    // /meter <peakL> <peakR> <clipped>
    xmit.start( "/meter" );
    peakL   => xmit.add;
    peakR   => xmit.add;
    clipped => xmit.add;
    xmit.send();
}
