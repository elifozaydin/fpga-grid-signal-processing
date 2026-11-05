%% ============================================================
%  Goertzel – Frequency Bank Selection
%
%  Objective
%  ---------
%  Compare 5-, 7-, and 9-bin Goertzel banks based on frequency
%  coverage, edge-bin behavior, estimation accuracy, and
%  computational cost.
%
%  Evaluate synthetic signals with known frequencies and real
%  power-grid recordings against a ROOT-MUSIC reference.
%
%  Design Parameters
%  -----------------
%  FPGA sampling rate : 986.193294 Hz (nominal post-CIC)
%  WAV sampling rate  : 1000 Hz
%  Observation length : 32000 samples
%  Candidate banks    : 5, 7, 9 bins
%  Target frequency   : 60 Hz
%  Estimator          : Three-point log-power interpolation
%  Arithmetic         : Double precision
%
%  This study does not evaluate fixed-point precision,
%  ENF calibration, or ENV extraction.
%
%% ============================================================

clear; clc; close all;

rng(42);

%% ---- System Configuration ----

data_dir = fullfile(pwd, 'recordings');  % Local recordings directory

wav_file = fullfile( ...
    data_dir, 'power_20231221_090000_3.wav');

% Locate generated results relative to this script, not MATLAB's pwd.
script_dir = fileparts(mfilename('fullpath'));
music_file = fullfile( ...
    script_dir, 'results', 'music_reference', 'music_reference.mat');

output_dir = fullfile( ...
    script_dir, 'results', 'frequency_bank');

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

Fs_fpga = 986.193294;
Fs = 1000;

N = 32000;
HOP = N;                   % Nonoverlapping observations

TARGET_FREQ = 60;
BANK_SIZES = [5 7 9];

ANALYSIS_MINUTES = 10;

% Frequency range used for controlled synthetic testing.
SWEEP_FREQ = (59.94:0.002:60.06)';

TEST_PHASES = [0 pi/2];
NUM_TRIALS = 3;
SNR_DB = 30;

num_configs = length(BANK_SIZES);

%% ---- Load ROOT-MUSIC Reference ----

% This script uses the dedicated 10-minute reference produced by
% 00_generate_music_reference.m, not the one-hour Experiment 5A MAT file.

assert(isfile(music_file), ...
    'Run generate_music_reference.m to produce results/music_reference/music_reference.mat first.');

M = load(music_file);

assert(isfield(M,'Fs') && isfield(M,'locations') && ...
       isfield(M,'t') && isfield(M,'frequency'), ...
    'Reference must contain Fs, locations, t, and frequency.');
assert(size(M.frequency,1)==numel(M.t) && ...
       size(M.frequency,2)==numel(M.locations), ...
    'Reference dimensions disagree with timestamps/locations.');

assert(M.Fs == Fs, ...
    'ROOT-MUSIC reference sampling rate mismatch.');

loc_idx = find(strcmp(M.locations, 'A'), 1);

assert(~isempty(loc_idx), ...
    'Location A not found in MUSIC reference.');

music_t = M.t(:);
music_f = M.frequency(:,loc_idx);

% Match the initial ten-minute interval used by the Goertzel analysis.
in_interval = music_t >= 0 & music_t < ANALYSIS_MINUTES*60;
valid_music = music_f(in_interval & isfinite(music_f));

assert(~isempty(valid_music), ...
    'No valid ROOT-MUSIC frequency estimates.');

observed_min = min(valid_music);
observed_max = max(valid_music);

fprintf('=== Goertzel Frequency Bank Selection ===\n');
fprintf('FPGA Fs            : %.6f Hz\n', Fs_fpga);
fprintf('Recording Fs       : %.0f Hz\n', Fs);
fprintf('Observation length : %d samples\n', N);
fprintf('FPGA bin spacing   : %.6f Hz\n', Fs_fpga/N);
fprintf('WAV bin spacing    : %.6f Hz\n', Fs/N);
fprintf('FPGA window length : %.3f s\n', N/Fs_fpga);
fprintf('WAV window length  : %.3f s\n', N/Fs);
fprintf('Candidate banks    : %s\n', mat2str(BANK_SIZES));
fprintf('Observed ENF range : %.6f to %.6f Hz\n\n', ...
    observed_min, observed_max);

%% ---- FPGA Frequency Coverage ----

% The FPGA and WAV recordings use different sampling rates.
% Bank coverage is evaluated using the actual FPGA bin grid.

center_fpga = round(TARGET_FREQ*N/Fs_fpga);

fpga_lower = zeros(num_configs,1);
fpga_upper = zeros(num_configs,1);

interior_lower = zeros(num_configs,1);
interior_upper = zeros(num_configs,1);

full_coverage = zeros(num_configs,1);
interior_coverage = zeros(num_configs,1);

for c = 1:num_configs

    half = (BANK_SIZES(c)-1)/2;
    bins = center_fpga + (-half:half);

    frequencies = bins*Fs_fpga/N;

    fpga_lower(c) = frequencies(1);
    fpga_upper(c) = frequencies(end);

    % Three-point interpolation requires a neighbor on each
    % side of the strongest bin.
    interior_lower(c) = frequencies(2);
    interior_upper(c) = frequencies(end-1);

    full_coverage(c) = 100*mean( ...
        valid_music >= fpga_lower(c) & ...
        valid_music <= fpga_upper(c));

    interior_coverage(c) = 100*mean( ...
        valid_music >= interior_lower(c) & ...
        valid_music <= interior_upper(c));

end

CoverageTable = table( ...
    BANK_SIZES(:), ...
    fpga_lower, fpga_upper, ...
    interior_lower, interior_upper, ...
    full_coverage, interior_coverage, ...
    'VariableNames', { ...
        'Bins', ...
        'LowerFrequency_Hz', ...
        'UpperFrequency_Hz', ...
        'InteriorLower_Hz', ...
        'InteriorUpper_Hz', ...
        'FullCoverage_pct', ...
        'InteriorCoverage_pct' ...
    });

fprintf('=== FPGA Frequency Coverage (geometric) ===\n');
disp(CoverageTable);
fprintf('FPGA center bin: k=%d (%.6f Hz)\n', ...
    center_fpga, center_fpga*Fs_fpga/N);

% Geometric coverage is an indicator, not a guarantee that
% the strongest spectral bin will lie in the interior.

%% ---- WAV Frequency Bank Configuration ----

% For actual WAV processing, recompute the integer DFT bins
% using the recording's 1000 Hz sampling rate.

center_wav = round(TARGET_FREQ*N/Fs);

half_max = (max(BANK_SIZES)-1)/2;
all_bins = center_wav + (-half_max:half_max);

banks = cell(num_configs,1);
bank_masks = cell(num_configs,1);

for c = 1:num_configs

    half = (BANK_SIZES(c)-1)/2;
    banks{c} = center_wav + (-half:half);

    bank_masks{c} = ismember(all_bins, banks{c});

end

%% ---- Synthetic Frequency Sweep ----

% Use known-frequency sinusoids to evaluate bank-edge
% behavior and frequency-estimation error.
%
% All three banks receive the same signal realization.
% The widest bank is computed once, then narrowed.

num_freq = length(SWEEP_FREQ);
num_cases = num_freq*length(TEST_PHASES)*NUM_TRIALS;

freq_error = NaN(num_cases,num_configs);
edge_hits = false(num_cases,num_configs);

case_idx = 0;
t = (0:N-1)'/Fs;

for fi = 1:num_freq

    f_true = SWEEP_FREQ(fi);

    for phase = TEST_PHASES

        for trial = 1:NUM_TRIALS

            clean = cos(2*pi*f_true*t + phase);

            noise_std = sqrt(mean(clean.^2)) * ...
                10^(-SNR_DB/20);

            x = clean + noise_std*randn(N,1);

            power = goertzel_power(x, all_bins);

            case_idx = case_idx+1;

            for c = 1:num_configs

                p = power(bank_masks{c});

                [f_est, edge] = estimate_frequency( ...
                    p, banks{c}, Fs, N);

                freq_error(case_idx,c) = ...
                    1000*(f_est-f_true);

                edge_hits(case_idx,c) = edge;

            end

        end

    end

end

%% ---- Synthetic Comparison ----

synthetic_mae = NaN(num_configs,1);
synthetic_max = NaN(num_configs,1);

synthetic_valid_pct = zeros(num_configs,1);
synthetic_edge_pct = zeros(num_configs,1);

for c = 1:num_configs

    errors = freq_error(:,c);
    valid = isfinite(errors);

    synthetic_valid_pct(c) = 100*mean(valid);
    synthetic_edge_pct(c) = 100*mean(edge_hits(:,c));

    if any(valid)
        synthetic_mae(c) = mean(abs(errors(valid)));
        synthetic_max(c) = max(abs(errors(valid)));
    end

end

SyntheticTable = table( ...
    BANK_SIZES(:), ...
    synthetic_mae, ...
    synthetic_max, ...
    synthetic_valid_pct, ...
    synthetic_edge_pct, ...
    'VariableNames', { ...
        'Bins', ...
        'MAE_mHz', ...
        'MaxError_mHz', ...
        'ValidEstimates_pct', ...
        'EdgeHits_pct' ...
    });

fprintf('\n=== Synthetic Frequency Accuracy (1000 Hz WAV bin grid) ===\n');
disp(SyntheticTable);

%% ---- Real Recording Processing ----

assert(isfile(wav_file), ...
    'Power recording not found: %s', wav_file);

info = audioinfo(wav_file);

assert(info.SampleRate == Fs, ...
    'Expected a 1000 Hz WAV recording.');

num_samples = round(ANALYSIS_MINUTES*60*Fs);

assert(info.TotalSamples >= num_samples, ...
    'Recording is shorter than the requested interval.');

x_real = audioread(wav_file, [1 num_samples]);
x_real = double(x_real(:,1));

% Remove the overall DC component before processing.
x_real = x_real-mean(x_real);

num_windows = floor((num_samples-N)/HOP)+1;

real_time = NaN(num_windows,1);
real_freq = NaN(num_windows,num_configs);
real_edge = false(num_windows,num_configs);
music_reference = NaN(num_windows,1);

for w = 1:num_windows

    first = (w-1)*HOP+1;
    last = first+N-1;

    segment = x_real(first:last);
    segment = segment-mean(segment);

    power = goertzel_power(segment, all_bins);

    t_start = (first-1)/Fs;
    t_end = last/Fs;

    real_time(w) = ((first-1)+(N-1)/2)/Fs;

    % Compare against MUSIC estimates whose observation
    % centers lie inside this Goertzel window.
    mask = music_t >= t_start & music_t < t_end;

    f_window = music_f(mask);
    f_window = f_window(isfinite(f_window));

    if ~isempty(f_window)
        music_reference(w) = mean(f_window);
    end

    for c = 1:num_configs

        p = power(bank_masks{c});

        [real_freq(w,c), real_edge(w,c)] = ...
            estimate_frequency(p, banks{c}, Fs, N);

    end

end

%% ---- Real Recording Comparison ----

music_mae = NaN(num_configs,1);
music_bias = NaN(num_configs,1);

real_valid_pct = zeros(num_configs,1);
real_edge_pct = zeros(num_configs,1);

for c = 1:num_configs

    estimates = real_freq(:,c);

    valid = isfinite(estimates) & ...
            isfinite(music_reference);

    errors = 1000*(estimates(valid)-music_reference(valid));

    real_valid_pct(c) = 100*mean(valid);
    real_edge_pct(c) = 100*mean(real_edge(:,c));

    if any(valid)
        music_mae(c) = mean(abs(errors));
        music_bias(c) = mean(errors);
    end

end

RealTable = table( ...
    BANK_SIZES(:), ...
    music_mae, ...
    music_bias, ...
    real_valid_pct, ...
    real_edge_pct, ...
    'VariableNames', { ...
        'Bins', ...
        'MUSICDifferenceMAE_mHz', ...
        'MUSICBias_mHz', ...
        'ValidEstimates_pct', ...
        'EdgeHits_pct' ...
    });

fprintf('\n=== Real Recording vs ROOT-MUSIC (1000 Hz WAV bin grid) ===\n');
disp(RealTable);
fprintf(['ROOT-MUSIC reference: mean of 10-s estimates centered inside ', ...
    'each 32-s Goertzel window; disagreement is not ground-truth error.\n']);

%% ---- Computational Cost Comparison ----

% Each independent Goertzel bin evaluates one recurrence
% per input sample. This is an algorithmic operation count,
% not a post-synthesis FPGA resource measurement.

recurrences_per_window = BANK_SIZES(:)*N;

relative_cost = BANK_SIZES(:)/BANK_SIZES(2);

CostTable = table( ...
    BANK_SIZES(:), ...
    recurrences_per_window, ...
    relative_cost, ...
    'VariableNames', { ...
        'Bins', ...
        'RecurrencesPerWindow', ...
        'RelativeTo7Bins' ...
    });

fprintf('\n=== Computational Cost ===\n');
disp(CostTable);

%% ---- Frequency Bank Coverage Plot ----

figure('Name', 'Goertzel Bank Coverage', ...
       'Color', 'w', ...
       'Position', [100 100 950 500]);

hold on;

for c = 1:num_configs

    y = c;

    plot([fpga_lower(c) fpga_upper(c)], ...
         [y y], '-o', ...
         'LineWidth', 2, ...
         'MarkerSize', 6);

    plot([interior_lower(c) interior_upper(c)], ...
         [y y], '-', ...
         'LineWidth', 5, ...
         'HandleVisibility','off');

end

xline(observed_min,'k:', ...
    'HandleVisibility','off');

xline(observed_max,'k:', ...
    'HandleVisibility','off');

yticks(1:num_configs);
yticklabels(compose('%d bins',BANK_SIZES));

xlabel('Frequency (Hz)');
ylabel('Goertzel bank');
title('FPGA Goertzel Bank Coverage of Observed ENF');
grid on;

%% ---- Accuracy and Validity Plot ----

figure('Name', 'Goertzel Bank Comparison', ...
       'Color', 'w', ...
       'Position', [100 100 950 650]);

subplot(2,1,1);

plot(BANK_SIZES, synthetic_mae, '-o', ...
     BANK_SIZES, music_mae, '-s', ...
     'LineWidth',1.5);

ylabel('Mean absolute difference (mHz)');
title('Frequency Estimation vs Bank Size');
legend('Synthetic ground truth', ...
       'ROOT-MUSIC reference', ...
       'Location','best');

xticks(BANK_SIZES);
grid on;

subplot(2,1,2);

plot(BANK_SIZES, synthetic_valid_pct, '-o', ...
     BANK_SIZES, real_valid_pct, '-s', ...
     'LineWidth',1.5);

xlabel('Number of Goertzel bins');
ylabel('Valid estimates (%)');
legend('Synthetic','Real recording', ...
       'Location','best');

xticks(BANK_SIZES);
ylim([0 105]);
grid on;

%% ---- Real ENF Comparison Plot ----

figure('Name', 'Real ENF Comparison', ...
       'Color', 'w', ...
       'Position', [100 100 1000 500]);

plot(music_t/60, music_f, 'k-', ...
    'LineWidth', 1.3, ...
    'DisplayName','ROOT-MUSIC');

hold on;

for c = 1:num_configs

    plot(real_time/60, real_freq(:,c), ...
        '-o', ...
        'LineWidth',1.1, ...
        'MarkerSize',4, ...
        'DisplayName',sprintf('%d bins',BANK_SIZES(c)));

end

xlabel('Time (minutes)');
ylabel('Estimated frequency (Hz)');
title('Real ENF: Goertzel Bank Comparison');
legend('Location','best');
grid on;

%% ---- Save Results ----

writetable(CoverageTable, ...
    fullfile(output_dir,'frequency_coverage.csv'));

writetable(SyntheticTable, ...
    fullfile(output_dir,'synthetic_accuracy.csv'));

writetable(RealTable, ...
    fullfile(output_dir,'real_frequency_comparison.csv'));

writetable(CostTable, ...
    fullfile(output_dir,'computational_cost.csv'));

save(fullfile(output_dir,'frequency_bank_study.mat'), ...
    'Fs','Fs_fpga','N','HOP', ...
    'BANK_SIZES','banks', ...
    'CoverageTable','SyntheticTable', ...
    'RealTable','CostTable', ...
    'real_time','real_freq','music_reference');

fprintf('\nFrequency-bank study complete.\n');
fprintf('Results saved to: %s\n',output_dir);

%% ---- Local Functions ----

function power = goertzel_power(x, bins)

    % Compute spectral power for selected integer DFT bins
    % using the final two Goertzel recurrence states.

    x = double(x(:));
    N = length(x);

    omega = 2*pi*bins/N;
    coeff = 2*cos(omega);

    s1 = zeros(size(bins));
    s2 = zeros(size(bins));

    for n = 1:N

        s0 = x(n) + coeff.*s1 - s2;

        s2 = s1;
        s1 = s0;

    end

    power = s1.^2 + s2.^2 - coeff.*s1.*s2;

    power = max(power,0);

end

function [f_est,edge_hit] = ...
    estimate_frequency(power,bins,Fs,N)

    % Estimate frequency using three-point quadratic
    % interpolation of log-power.
    %
    % Edge-bin peaks cannot use both neighboring bins.

    [~,idx] = max(power);

    edge_hit = idx == 1 || idx == numel(power);

    if edge_hit
        f_est = NaN;
        return;
    end

    y = log(max(power(idx-1:idx+1),realmin));

    denominator = y(1)-2*y(2)+y(3);

    if ~isfinite(denominator) || denominator >= -1e-14
        f_est = NaN;
        return;
    end

    delta = 0.5*(y(1)-y(3))/denominator;

    if ~isfinite(delta) || abs(delta)>1
        f_est = NaN;
        return;
    end

    f_est = (bins(idx)+delta)*Fs/N;

end
