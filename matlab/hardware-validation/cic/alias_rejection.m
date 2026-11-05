%% FPGA CIC Hardware Alias Rejection
% Measure rejection of a 686 Hz aliasing tone relative to a 300 Hz tone.
% Compare equal-amplitude recordings against the theoretical CIC response.

clear; clc; close all;

%% ---- Recording Configuration ----

recording_dir = fullfile(pwd, 'recordings');  % Local capture directory
files = fullfile(recording_dir, [
    "5062FC_19691231_2243_FPGA.bin"
    "5062FC_19691231_2244_FPGA.bin"
]);

frequencies_hz = [300; 686];

% Set to measured input amplitudes if they differ.
input_amplitudes = [1.0; 1.0];

settling_seconds = 1.0;
freq_search_hz   = 1.0;

%% ---- CIC Configuration ----

Fs_clk = 8e6; % Nominal FPGA clock frequency

R = 26;
M = 1;
N = 4;

timing_intervals = 1024;

%% ---- Analyze FPGA Recordings ----

num_tests = numel(frequencies_hz);

measured_amp = nan(num_tests, 1);
Fs_out       = nan(num_tests, 1);

for k = 1:num_tests

    f0 = frequencies_hz(k);

    % Decode CIC samples and timing measurements.
    [T, timing] = parser(files(k));

    S = T(T.session_id == 1, :);
    P = timing(timing.session_id == 1, :);

    %% ---- Sampling Rate Measurement ----

    cycles = double(P.clock_cycles);

    Fs_out(k) = Fs_clk * timing_intervals / mean(cycles);

    % Fold the input tone into the CIC output Nyquist band.
    expected_freq = abs( ...
        mod(f0 + Fs_out(k)/2, Fs_out(k)) - Fs_out(k)/2);


    %% ---- Select Steady-State Samples ----

    t = double(S.sample_idx) / Fs_out(k);
    y = double(S.cic_raw);

    keep = t >= settling_seconds;

    t = t(keep);
    y = y(keep);

    t = t - t(1);

    %% ---- Estimate Tone Frequency ----

    % Coarse search, followed by refinement using all samples.
    coarse = t <= min(5, t(end));

    coarse_freqs = linspace( ...
        expected_freq - freq_search_hz, ...
        expected_freq + freq_search_hz, 301);

    coarse_error = arrayfun( ...
        @(f) tone_sse(f, t(coarse), y(coarse)), coarse_freqs);

    [~, idx] = min(coarse_error);
    f_initial = coarse_freqs(idx);

    halfwidth = min(0.025, 0.35 / max(t(end), 1));

    fbest = fminbnd( ...
        @(f) tone_sse(f, t, y), ...
        max(expected_freq - freq_search_hz, ...
            f_initial - halfwidth), ...
        min(expected_freq + freq_search_hz, ...
            f_initial + halfwidth), ...
        optimset('TolX', 1e-9, 'Display', 'off'));

    %% ---- Estimate Tone Amplitude ----

    X = [ ...
        cos(2*pi*fbest*t), ...
        sin(2*pi*fbest*t), ...
        ones(size(t)) ...
    ];

    beta = X \ y;

    measured_amp(k) = hypot(beta(1), beta(2));


end

%% ---- Theoretical and Measured Alias Rejection ----

% Normalize output amplitudes by the applied input amplitudes.
gain = measured_amp ./ input_amplitudes;

measured_rejection_db = 20 * log10(gain(1) / gain(2));

% Calculate theoretical gain using the sampling rate measured
% for each recording.
Fs_in = R * Fs_out;

Hd = cic_magnitude(frequencies_hz(1), Fs_in(1), R, M, N);
Ha = cic_magnitude(frequencies_hz(2), Fs_in(2), R, M, N);

theoretical_rejection_db = 20 * log10(Hd / Ha);
error_db = measured_rejection_db - theoretical_rejection_db;

%% ---- Results ----

fprintf('\nFPGA CIC ALIAS REJECTION\n');
fprintf('------------------------\n');
fprintf('Desired input:          %.0f Hz\n', frequencies_hz(1));
fprintf('Aliasing input:         %.0f Hz\n', frequencies_hz(2));
fprintf('Theoretical rejection:  %.6f dB\n', theoretical_rejection_db);
fprintf('Measured rejection:     %.6f dB\n', measured_rejection_db);
fprintf('Difference from theory: %+.6f dB\n', error_db);

%% ---- Sinusoidal Fit Error ----

function sse = tone_sse(f, t, y)

    X = [ ...
        cos(2*pi*f*t), ...
        sin(2*pi*f*t), ...
        ones(size(t)) ...
    ];

    beta = X \ y;
    residual = y - X*beta;

    sse = sum(residual.^2);
end

%% ---- CIC Theoretical Magnitude ----

function gain = cic_magnitude(f, Fs_in, R, M, N)

    if f == 0
        gain = 1;
    else
        gain = abs( ...
            sin(pi*R*M*f/Fs_in) / ...
            (R*M*sin(pi*f/Fs_in)) ...
        )^N;
    end
end
