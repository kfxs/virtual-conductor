// peak-detector.ck — the shared spectral analysis bus. A core shred: always
// running, never added or removed.
//
// Runs one FFT over the shared input bus (g_mic), finds the loudest spectral
// peaks inside a band, and publishes them for any module to read. One FFT
// serves every consumer — the 4096-point transform is the most expensive thing
// in the project, so running a copy per module would be pure waste.
//
// NOT a pitch detector: it reports the loudest local maxima in the spectrum. On
// a plucked string the loudest partial is often not the fundamental, and the
// peaks are usually the harmonic series of one note rather than several notes.
// Estimating a true fundamental needs a different algorithm (autocorrelation,
// YIN, harmonic product spectrum) and would be its own core shred.
//
// ===== THE PUBLISHED CONTRACT =====
// A consumer declares the three globals below — with g_peak_freqs and
// g_peak_mags at EXACTLY this size — and reads them whenever it likes:
//
//     global float g_peak_freqs[8];   // Hz, loudest first
//     global float g_peak_mags[8];    // raw FFT magnitude, same order
//     global int   g_peak_count;      // how many slots are valid this hop
//
// Slots at or past g_peak_count are zero. Results are rewritten in full every
// hop without yielding, so a reader never sees a half-updated set.
//
// One quirk to know: in ChucK a later shred re-declaring a global array wipes
// it to zeros. So adding a module mid-session blanks these for one hop (~46 ms)
// until the next publish refills them. Harmless, but that's why a consumer
// should tolerate a momentarily empty set rather than latching on to it.

global Gain g_mic;

// ===== PUBLISHED RESULTS =====
global float g_peak_freqs[8];
global float g_peak_mags[8];
global int g_peak_count;
g_peak_freqs.size() => int MAX_PEAKS;

// ===== ANALYSIS CHAIN =====
4096 => int FFT_SIZE;
g_mic => FFT fft => blackhole;
FFT_SIZE => fft.size;
Windowing.hann(FFT_SIZE) => fft.window;

FFT_SIZE / 2 => int HOP_SIZE;    // how often we analyze
float mag[FFT_SIZE / 2];         // this hop's spectrum
second / samp => float SR;

// ===== PARAMETERS =====
// The band the peak search runs over. Note this does NOT filter the audio and
// does not make the FFT cheaper — the whole spectrum is always computed; this
// only bounds which bins the search loop scans.
global float g_peak_detector_minfreq;
global float g_peak_detector_maxfreq;

// How loud a peak must be to count, as a fraction of the loudest peak this hop.
// Without this the spectrum's numerical noise floor always yields "peaks" —
// a scan will happily return 8 local maxima from silence — and a consumer with
// a fixed voice gain would sound them all at full volume. Relative rather than
// absolute so it holds up however hard the instrument is being played.
global float g_peak_detector_thresh;

40.0  => float MIN_FREQ_MIN;   500.0  => float MIN_FREQ_MAX;
500.0 => float MAX_FREQ_MIN;   5000.0 => float MAX_FREQ_MAX;
0.0   => float THRESH_MIN;     0.5    => float THRESH_MAX;
// ...and an absolute floor underneath it, so true silence publishes nothing
// rather than the loudest speck of noise plus everything within reach of it.
0.0005 => float SILENCE_FLOOR;

// Hysteresis. A partial sitting right on the threshold would otherwise flicker
// in and out of the published set every hop, and a consumer voicing it hears
// that as chatter. So a peak has to clear the full threshold to be reported,
// but only has to stay above this fraction of it to keep being reported. Worst
// on a plucked string's upper partials, which decay fast and hover at the edge.
0.6 => float HYSTERESIS;
// How close two frequencies must be to count as the same partial across hops,
// in octaves. Matches the tracking window in spectral-sines.ck.
0.05 => float SAME_PARTIAL_OCTAVES;

// what we published last hop, so hysteresis knows what was already sounding
float prevFreqs[8];

60.0 => float minFreq;
2000.0 => float maxFreq;
0.1 => float thresh;
6 => int MIN_BIN;
185 => int MAX_BIN;

// map a normalized 0..1 into a float range
fun float mapF(float g, float lo, float hi) { return lo + g * (hi - lo); }
// guard against an out-of-range value arriving before Python's first frame
fun float clampN(float g) { return Math.max(0.0, Math.min(1.0, g)); }

// Recompute the search window. isTruePeak reads bin-1 and bin+1, so the window
// has to stay one bin inside the spectrum at both ends.
fun void updateBins() {
    Math.ceil(minFreq * FFT_SIZE / SR) $ int => MIN_BIN;
    Math.floor(maxFreq * FFT_SIZE / SR) $ int => MAX_BIN;
    if (MIN_BIN < 1) 1 => MIN_BIN;
    if (MAX_BIN > mag.size() - 2) mag.size() - 2 => MAX_BIN;
    if (MAX_BIN <= MIN_BIN) MIN_BIN + 1 => MAX_BIN;
}

fun void readParams() {
    mapF(clampN(g_peak_detector_minfreq), MIN_FREQ_MIN, MIN_FREQ_MAX) => minFreq;
    mapF(clampN(g_peak_detector_maxfreq), MAX_FREQ_MIN, MAX_FREQ_MAX) => maxFreq;
    mapF(clampN(g_peak_detector_thresh),  THRESH_MIN,   THRESH_MAX)   => thresh;
    updateBins();
}

// ===== PEAK PICKING =====

// Frequency of a peak at `bin`, refined below bin resolution.
//
// A bin is SR/FFT_SIZE wide — about 10.8 Hz at 44.1k — so taking the bin centre
// leaves up to half a bin of error at every pitch. That is ~21 cents at 440 Hz
// but ~1.5 semitones at 60 Hz, which is exactly backwards for an instrument
// whose character lives in its bass strings. Fitting a parabola through the
// peak and its two neighbours recovers the true position to a few cents, using
// the same two samples isTruePeak already looks at.
fun float refinedFreq(int bin) {
    mag[bin - 1] => float lo;
    mag[bin]     => float mid;
    mag[bin + 1] => float hi;
    lo - 2.0 * mid + hi => float denom;
    0.0 => float delta;
    if (denom != 0.0) {
        0.5 * (lo - hi) / denom => delta;
        // a true peak sits within half a bin; anything else is numerical noise
        if (delta > 0.5) 0.5 => delta;
        if (delta < -0.5) -0.5 => delta;
    }
    return (bin + delta) * SR / FFT_SIZE;
}

// Was a peak at this frequency in last hop's published set? Drives hysteresis:
// something already sounding gets to stay on a lower threshold.
fun int wasPublished(float f) {
    for (0 => int i; i < MAX_PEAKS; i++) {
        if (prevFreqs[i] <= 0.0) continue;
        if (Math.fabs(Math.log2(f / prevFreqs[i])) < SAME_PARTIAL_OCTAVES) return 1;
    }
    return 0;
}

// check if bin is a true spectral peak (higher than both neighbors)
fun int isTruePeak(int bin) {
    if (mag[bin] > mag[bin - 1] && mag[bin] > mag[bin + 1]) return 1;
    return 0;
}

// clear the published set
fun void resetPeaks() {
    for (0 => int i; i < MAX_PEAKS; i++) {
        0.0 => g_peak_freqs[i];
        0.0 => g_peak_mags[i];
    }
    0 => g_peak_count;
}

// insert a peak into the published arrays, keeping them sorted loudest first
fun void insertPeak(int bin, float magnitude) {
    if (magnitude <= g_peak_mags[MAX_PEAKS - 1]) return;

    MAX_PEAKS - 1 => int slot;
    magnitude => g_peak_mags[slot];
    refinedFreq(bin) => g_peak_freqs[slot];

    // bubble up
    while (slot > 0 && g_peak_mags[slot] > g_peak_mags[slot - 1]) {
        g_peak_mags[slot - 1] => float tmpMag;
        g_peak_freqs[slot - 1] => float tmpFreq;
        g_peak_mags[slot] => g_peak_mags[slot - 1];
        g_peak_freqs[slot] => g_peak_freqs[slot - 1];
        tmpMag => g_peak_mags[slot];
        tmpFreq => g_peak_freqs[slot];
        slot - 1 => slot;
    }
}

// scan the spectrum and publish the loudest true peaks within the band.
// No yielding in here, so consumers only ever see a complete set.
fun void findPeaks() {
    resetPeaks();
    for (MIN_BIN => int bin; bin < MAX_BIN; bin++) {
        if (isTruePeak(bin)) {
            insertPeak(bin, mag[bin]);
        }
    }
    // Drop everything under the floor, with hysteresis: a peak already sounding
    // last hop only has to clear the lower release floor to stay.
    Math.max(SILENCE_FLOOR, g_peak_mags[0] * thresh) => float attackFloor;
    Math.max(SILENCE_FLOOR, attackFloor * HYSTERESIS) => float releaseFloor;

    // Survivors are compacted down so they stay a contiguous prefix, sorted
    // loudest first — that's what lets a consumer just take the first N.
    // Hysteresis makes this necessary rather than optional: a quieter peak that
    // was already sounding can outlive a louder one that wasn't, which would
    // otherwise leave a hole in the middle of the array. Compacting in place is
    // safe because the write index never runs ahead of the read index.
    0 => int found;
    for (0 => int i; i < MAX_PEAKS; i++) {
        if (g_peak_mags[i] <= 0.0) continue;
        releaseFloor => float floor;
        if (!wasPublished(g_peak_freqs[i])) attackFloor => floor;
        if (g_peak_mags[i] < floor) continue;

        g_peak_mags[i]  => g_peak_mags[found];
        g_peak_freqs[i] => g_peak_freqs[found];
        found++;
    }
    for (found => int i; i < MAX_PEAKS; i++) {
        0.0 => g_peak_mags[i];
        0.0 => g_peak_freqs[i];
    }
    found => g_peak_count;

    // remember this hop's set for the next hop's hysteresis
    for (0 => int i; i < MAX_PEAKS; i++) g_peak_freqs[i] => prevFreqs[i];
}

<<< "[peak-detector] ready — publishing up to", MAX_PEAKS, "spectral peaks" >>>;

while (true) {
    HOP_SIZE::samp => now;

    readParams();

    fft.upchuck() @=> UAnaBlob blob;
    blob.fvals() @=> mag;
    findPeaks();
}
