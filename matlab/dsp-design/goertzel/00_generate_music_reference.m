%% ============================================================
%  ROOT-MUSIC – ENF Reference Generation
%
%  Objective
%  ---------
%  Extract reference electrical network frequency (ENF)
%  estimates from recorded power-grid signals using ROOT-MUSIC.
%
%  The reference will be used to evaluate Goertzel observation
%  lengths and frequency-bank configurations.
%
%  Analysis Parameters
%  -------------------
%  Sampling frequency : 1000 Hz (recorded WAV files)
%  Frequency band     : 59.8–60.2 Hz
%  Observation length : 10 seconds
%  Update interval    : 1 second
%  MUSIC model order  : 2
%  Analysis duration  : 10 minutes
%
%% ============================================================

clear; clc; close all;

%% ---- System Configuration ----

data_dir = fullfile(pwd, 'recordings');  % Local recordings directory

% Store generated references next to the design scripts, independent of pwd.
script_dir = fileparts(mfilename('fullpath'));
output_dir = fullfile(script_dir, 'results', 'music_reference');

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

locations = {'A', 'K', 'C', 'G'};
source_ids = [3 5 2 1];

recording_timestamp = '20231221_090000';

TARGET_FREQ = 60;
BANDPASS_RANGE = [59.8 60.2];

FRAME_SECONDS = 10;
HOP_SECONDS = 1;
ANALYSIS_MINUTES = 10;

MODEL_ORDER = 2;

%% ---- Recording Configuration ----

num_locations = length(locations);
filepaths = cell(num_locations, 1);

for i = 1:num_locations

    filename = sprintf('power_%s_%d.wav', ...
        recording_timestamp, source_ids(i));

    filepaths{i} = fullfile(data_dir, filename);

    assert(isfile(filepaths{i}), ...
        'Recording not found: %s', filepaths{i});

end

info = audioinfo(filepaths{1});

Fs = info.SampleRate;

assert(Fs == 1000, ...
    'Expected recordings sampled at 1000 Hz.');

frame_samples = round(FRAME_SECONDS * Fs);
hop_samples = round(HOP_SECONDS * Fs);
analysis_samples = round(ANALYSIS_MINUTES * 60 * Fs);

num_frames = floor( ...
    (analysis_samples - frame_samples) / hop_samples) + 1;

% Center timestamp of each MUSIC observation.
t = ((0:num_frames-1)' * hop_samples + ...
    (frame_samples-1)/2) / Fs;

frequency = NaN(num_frames, num_locations);

fprintf('=== ROOT-MUSIC ENF Reference ===\n');
fprintf('Sampling frequency : %.0f Hz\n', Fs);
fprintf('Analysis duration  : %d minutes\n', ANALYSIS_MINUTES);
fprintf('Frame length       : %d seconds\n', FRAME_SECONDS);
fprintf('Update interval    : %d second\n', HOP_SECONDS);
fprintf('Frames per location: %d\n\n', num_frames);

%% ---- ROOT-MUSIC Frequency Extraction ----

for i = 1:num_locations

    info = audioinfo(filepaths{i});

    assert(info.SampleRate == Fs, ...
        'Sampling frequency mismatch at Location %s.', ...
        locations{i});

    assert(info.TotalSamples >= analysis_samples, ...
        'Insufficient samples at Location %s.', locations{i});

    x = audioread(filepaths{i}, [1 analysis_samples]);
    x = double(x(:,1));

    % Match the preprocessing used in the original MUSIC study.
    peak = max(abs(x));

    assert(peak > 0, ...
        'Recording at Location %s is empty.', locations{i});

    x = x / peak;
    x = x - mean(x);

    x = bandpass(x, BANDPASS_RANGE, Fs);

    fprintf('Processing Location %s...\n', locations{i});

    for j = 1:num_frames

        first = (j-1)*hop_samples + 1;
        last = first + frame_samples - 1;

        segment = x(first:last);
        segment = segment - mean(segment);

        try
            [f_music, ~] = rootmusic( ...
                segment, MODEL_ORDER, Fs);

            if ~isempty(f_music)

                % Select the estimated component nearest 60 Hz.
                [~, idx] = min(abs(f_music(:)-TARGET_FREQ));

                frequency(j,i) = f_music(idx);

            end

        catch
            % Preserve NaN for unsuccessful MUSIC estimates.
        end

        if mod(j,100) == 0 || j == num_frames
            fprintf('  %d/%d frames\n', j, num_frames);
        end

    end

end

%% ---- Reference Summary ----

valid_frames = zeros(num_locations,1);
mean_frequency = NaN(num_locations,1);
std_frequency = NaN(num_locations,1);
min_frequency = NaN(num_locations,1);
max_frequency = NaN(num_locations,1);

for i = 1:num_locations

    f = frequency(:,i);
    f = f(isfinite(f));

    valid_frames(i) = numel(f);

    if ~isempty(f)
        mean_frequency(i) = mean(f);
        std_frequency(i) = std(f);
        min_frequency(i) = min(f);
        max_frequency(i) = max(f);
    end

end

results = table( ...
    string(locations(:)), ...
    valid_frames, ...
    mean_frequency, ...
    std_frequency, ...
    min_frequency, ...
    max_frequency, ...
    'VariableNames', { ...
        'Location', ...
        'ValidFrames', ...
        'MeanFrequency_Hz', ...
        'StdFrequency_Hz', ...
        'MinFrequency_Hz', ...
        'MaxFrequency_Hz' ...
    });

fprintf('\n=== MUSIC Reference Summary ===\n');
disp(results);

assert(all(valid_frames >= 10), ...
    'Insufficient valid MUSIC results for one or more locations.');

%% ---- ENF Reference Plot ----

figure('Name', 'ROOT-MUSIC ENF Reference', ...
       'Color', 'w', ...
       'Position', [100 100 1000 500]);

plot(t/60, frequency, 'LineWidth', 1.2);

xlabel('Time (minutes)');
ylabel('Estimated ENF (Hz)');
title('ROOT-MUSIC Frequency Reference');
legend(locations, 'Location', 'best');
grid on;

%% ---- Save Reference ----

save(fullfile(output_dir, 'music_reference.mat'), ...
    'Fs', 't', 'frequency', 'locations', ...
    'source_ids', 'MODEL_ORDER', ...
    'FRAME_SECONDS', 'HOP_SECONDS', ...
    'ANALYSIS_MINUTES');

writetable(results, ...
    fullfile(output_dir, 'music_reference_summary.csv'));

fprintf('\nReference saved to: %s\n', output_dir);