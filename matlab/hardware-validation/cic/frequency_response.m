%% FPGA CIC Hardware Frequency Response
% Compare measured attenuation at five input frequencies against the
% theoretical four-stage CIC response, normalized to 60 Hz.

clear; clc; close all;

%% ---- Recording Configuration ----

frequencies_hz = [60; 120; 180; 240; 300];

recording_dir = fullfile(pwd, 'recordings');  % Local capture directory
files = fullfile(recording_dir, [
    "5062FC_19691231_2238_FPGA.bin"
    "5062FC_19691231_2239_FPGA (1).bin"
    "5062FC_19691231_2240_FPGA (1).bin"
    "5062FC_19691231_2242_FPGA.bin"
    "5062FC_19691231_2243_FPGA.bin"
]);

settling_seconds = 1.0;
freq_search_hz   = 0.30;

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
    %% ---- Select Steady-State Samples ----

    t = double(S.sample_idx) / Fs_out(k);
    y = double(S.cic_raw);

    keep = t >= settling_seconds;

    t = t(keep);
    y = y(keep);

    t = t - t(1);

    %% ---- Estimate Tone Frequency ----

    % Coarse frequency search using the first five seconds.
    coarse = t <= min(5, t(end));

    coarse_freqs = linspace( ...
        f0 - freq_search_hz, ...
        f0 + freq_search_hz, 241);

    coarse_error = arrayfun( ...
        @(f) tone_sse(f, t(coarse), y(coarse)), coarse_freqs);

    [~, idx] = min(coarse_error);
    f_initial = coarse_freqs(idx);

    % Refine using the full recording.
    halfwidth = min(0.025, 0.35 / max(t(end), 1));

    fbest = fminbnd( ...
        @(f) tone_sse(f, t, y), ...
        max(f0 - freq_search_hz, f_initial - halfwidth), ...
        min(f0 + freq_search_hz, f_initial + halfwidth), ...
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

%% ---- Theoretical and Measured Frequency Response ----

% Compare amplitudes relative to the 60 Hz recording.
measured_db = 20 * log10(measured_amp / measured_amp(1));

Fs_in = R * Fs_out;

theory_db = zeros(num_tests, 1);

for k = 1:num_tests
    theory_db(k) = cic_gain_db( ...
        frequencies_hz(k), Fs_in(k), R, M, N);
end

theory_db = theory_db - theory_db(1);
error_db = measured_db - theory_db;

%% ---- Measurement Results ----

metrics = table(frequencies_hz, measured_db, theory_db, error_db, ...
    'VariableNames', {'Frequency_Hz', 'Measured_dB', 'Theoretical_dB', 'Error_dB'});

fprintf('\nFPGA CIC FREQUENCY RESPONSE\n');
disp(metrics);
fprintf('Maximum absolute deviation from theory: %.6f dB\n', max(abs(error_db)));

%% ---- Theoretical vs. Measured Plot ----

% Use the mean measured sample rate for the smooth curve.
Fs_in_plot = mean(Fs_in);

f_curve = linspace(60, 300, 1000).';

theory_curve = cic_gain_db(f_curve, Fs_in_plot, R, M, N) ...
    - cic_gain_db(60, Fs_in_plot, R, M, N);

fig = figure('Name', 'FPGA CIC Frequency Response', ...
    'Color', 'w', 'Position', [100 100 900 550]);

plot(f_curve, theory_curve, '-', ...
    'LineWidth', 2, ...
    'DisplayName', 'Theoretical CIC');

hold on;

plot(frequencies_hz, measured_db, 'o', ...
    'MarkerSize', 8, ...
    'LineWidth', 1.5, ...
    'DisplayName', 'Measured FPGA');

grid on;
box on;

xlabel('Input frequency (Hz)');
ylabel('Gain relative to 60 Hz (dB)');
title('FPGA CIC – Theoretical vs. Measured Frequency Response');

legend('Location', 'southwest');
xticks(frequencies_hz);
xlim([55 305]);

%% ---- Export Figure ----

exportgraphics(fig, 'frequency_response.png', 'Resolution', 300);

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

%% ---- CIC Theoretical Gain ----

function gain_db = cic_gain_db(f, Fs_in, R, M, N)

    x = pi * double(f) / Fs_in;

    ratio = abs( ...
        sin(R*M*x) ./ (R*M*sin(x)));

    ratio(x == 0) = 1;

    gain_db = 20*N * log10( ...
        max(ratio, realmin('double')));
end
