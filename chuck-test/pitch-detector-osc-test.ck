// pitch-detector-test.ck
// Pitch detection test using ChucK

// audio input (fake mic — swap with adc later)
SndBuf input => dac;
me.dir() + "/../samples/tiorba.wav" => input.read;
1 => input.loop;
1.0 => input.rate;

// FFT analysis chain
4096 => int FFT_SIZE;
input => FFT fft => blackhole;
FFT_SIZE => fft.size;
Windowing.hann(FFT_SIZE) => fft.window;

// hop size — how often we analyze
FFT_SIZE / 2 => int HOP_SIZE;

// spectrum storage
float mag[FFT_SIZE / 2];

// note names for freq-to-note conversion
["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"] @=> string noteNames[];

// convert frequency to nearest note name + octave
fun string freqToNote(float freq) {
    // MIDI note number from frequency (A4 = 440Hz = MIDI 69)
    Math.round(12.0 * Math.log2(freq / 440.0) + 69.0) $ int => int midi;
    midi % 12 => int note;
    midi / 12 - 1 => int octave;
    return noteNames[note] + octave;
}

// peak detection config
4 => int NUM_PEAKS;
float peakFreqs[NUM_PEAKS];
float peakMags[NUM_PEAKS];
second / samp => float SR;

// frequency range limits
60.0 => float MIN_FREQ;
2000.0 => float MAX_FREQ;
Math.ceil(MIN_FREQ * FFT_SIZE / SR) $ int => int MIN_BIN;
Math.floor(MAX_FREQ * FFT_SIZE / SR) $ int => int MAX_BIN;

// convert bin index to frequency
fun float binToFreq(int bin) {
    return bin * SR / FFT_SIZE;
}

// check if bin is a true spectral peak (higher than both neighbors)
fun int isTruePeak(int bin) {
    if (mag[bin] > mag[bin - 1] && mag[bin] > mag[bin + 1]) return 1;
    return 0;
}

// reset all peaks to zero
fun void resetPeaks() {
    for (0 => int i; i < NUM_PEAKS; i++) {
        0.0 => peakFreqs[i];
        0.0 => peakMags[i];
    }
}

// insert a peak into sorted arrays (loudest first)
fun void insertPeak(int bin, float magnitude) {
    if (magnitude <= peakMags[NUM_PEAKS - 1]) return;

    NUM_PEAKS - 1 => int slot;
    magnitude => peakMags[slot];
    binToFreq(bin) => peakFreqs[slot];

    // bubble up
    while (slot > 0 && peakMags[slot] > peakMags[slot - 1]) {
        peakMags[slot - 1] => float tmpMag;
        peakFreqs[slot - 1] => float tmpFreq;
        peakMags[slot] => peakMags[slot - 1];
        peakFreqs[slot] => peakFreqs[slot - 1];
        tmpMag => peakMags[slot];
        tmpFreq => peakFreqs[slot];
        slot - 1 => slot;
    }
}

// scan spectrum and find top N true peaks within frequency range
fun void findPeaks() {
    resetPeaks();
    for (MIN_BIN => int bin; bin < MAX_BIN; bin++) {
        if (isTruePeak(bin)) {
            insertPeak(bin, mag[bin]);
        }
    }
}

// --- TEMPORARY: oscillators to audition detected peaks (safe to remove) ---
SinOsc osc[NUM_PEAKS];
Gain oscMix => dac;
0.5 => oscMix.gain;
for (0 => int i; i < NUM_PEAKS; i++) {
    osc[i] => oscMix;
    0.0 => osc[i].gain;
}

fun void updateOscs() {
    for (0 => int i; i < NUM_PEAKS; i++) {
        if (peakFreqs[i] > 0.0) {
            peakFreqs[i] => osc[i].freq;
            0.25 => osc[i].gain;
        } else {
            0.0 => osc[i].gain;
        }
    }
}
// --- END TEMPORARY ---

// main loop
while (true) {
    HOP_SIZE::samp => now;

    fft.upchuck() @=> UAnaBlob blob;
    blob.fvals() @=> mag;
    findPeaks();
    updateOscs();

    // print detected frequencies
    chout <= "Peaks: ";
    for (0 => int i; i < NUM_PEAKS; i++) {
        if (peakFreqs[i] > 0.0) {
            chout <= peakFreqs[i]$int <= "Hz(" <= freqToNote(peakFreqs[i]) <= ") ";
        }
    }
    chout <= "\n";
}
