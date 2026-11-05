%% Experiment 5A — MUSIC ENF and raw ENV reference
% Extract 60 Hz MUSIC features from four timestamp-aligned one-hour WAVs.
% Raw ENV is the MUSIC power parameter; no high-pass filtering is applied.

clear; clc; close all;

%% 1. Configuration
folder = fullfile(pwd, 'recordings');  % Local recordings directory
output_folder = pwd;

files = struct( ...
    'A', fullfile(folder,'power_20231221_090000_3.wav'), ...
    'K', fullfile(folder,'power_20231221_090000_5.wav'), ...
    'C', fullfile(folder,'power_20231221_090000_2.wav'), ...
    'G', fullfile(folder,'power_20231221_090000_1.wav'));
locs = {'A','K','C','G'};
pairs = {'A','K';'A','C';'A','G';'K','C';'K','G';'C','G'};

Fs = 1000;
segment_seconds = 3600;
segment_samples = Fs * segment_seconds;
frame_N = 10000;        % 10-second MUSIC frame
hop_N = 1000;          % one-second feature spacing
band_Hz = [59.8 60.2];
music_order = 2;
n_frames = floor((segment_samples - frame_N)/hop_N) + 1;
frame_time_s = ((0:n_frames-1)' * hop_N + frame_N/2) / Fs;

assert(exist('rootmusic','file') ~= 0, ...
    'rootmusic requires the Signal Processing Toolbox.');
if ~exist(output_folder,'dir'), mkdir(output_folder); end

fprintf('\n==== EXPERIMENT 5A: MUSIC ENF + RAW ENV (NO HIGH-PASS) ====\n');
fprintf('Date: 2023-12-21 09:00–10:00 | Fs=%d Hz\n', Fs);
fprintf('Bandpass: %.1f–%.1f Hz | window: %.0f s | hop: %.0f s\n', ...
    band_Hz(1),band_Hz(2),frame_N/Fs,hop_N/Fs);
fprintf('Frames/location: %d\n', n_frames);

%% 2. Extract MUSIC features
DATA = struct();
for li = 1:numel(locs)
    loc = locs{li};
    name = files.(loc);
    assert(isfile(name), 'Missing recording for %s: %s', loc, name);
    info = audioinfo(name);
    assert(info.SampleRate == Fs, '%s has Fs=%g, expected %g',loc,info.SampleRate,Fs);
    assert(info.TotalSamples >= segment_samples, ...
        'Recording %s has fewer than %d samples',loc,segment_samples);

    fprintf('\nLocation %s: reading and filtering...\n',loc);
    x = audioread(name,[1 segment_samples]);
    x = double(x(:,1));
    peak = max(abs(x));
    assert(isfinite(peak) && peak > 0, 'Invalid/zero input at %s',loc);
    x = x / peak;
    x = x - mean(x);
    x = bandpass(x, band_Hz, Fs);

    enf = NaN(n_frames,1);
    env = NaN(n_frames,1);
    for fi=1:n_frames
        ind = (fi-1)*hop_N + (1:frame_N);
        sig = x(ind);
        sig = sig - mean(sig);
        try
            [f,p] = rootmusic(sig, music_order, Fs);
            % Retain the ordering convention of the earlier MUSIC script.
            if ~isempty(f) && ~isempty(p) && isfinite(f(1)) && isfinite(p(1))
                enf(fi) = double(f(1));
                env(fi) = double(p(1));
            end
        catch ME
            if fi <= 3
                warning('Location %s frame %d: %s',loc,fi,ME.message);
            end
        end
    end
    valid = isfinite(enf) & isfinite(env) & enf>=band_Hz(1) & enf<=band_Hz(2);
    fprintf('  Valid 60-Hz MUSIC estimates: %d/%d | mean ENF: %.9f Hz\n', ...
        nnz(valid), n_frames, mean(enf(valid)));
    % Preserve raw values for inspection; invalid frames remain NaN.
    enf(~valid)=NaN; env(~valid)=NaN;
    DATA.(loc).ENF = enf;
    DATA.(loc).ENV = env;
    DATA.(loc).valid = valid;
    DATA.(loc).filename = name;
end

%% 3. Timestamp-aligned pairwise correlations

np = size(pairs,1);
Pair = strings(np,1);
Timestamp_ENF_r = NaN(np,1);
Timestamp_ENV_r = NaN(np,1);

for pi=1:np
    a=pairs{pi,1}; b=pairs{pi,2};
    Pair(pi)=string(a)+'-'+string(b);
    Timestamp_ENF_r(pi)=local_pearson(DATA.(a).ENF,DATA.(b).ENF);
    Timestamp_ENV_r(pi)=local_pearson(DATA.(a).ENV,DATA.(b).ENV);
end

Results = table(Pair,Timestamp_ENF_r,Timestamp_ENV_r);
fprintf('\nMUSIC ENF/ENV REFERENCE — TIMESTAMP-ALIGNED PAIRS\n');
disp(Results);

%% 4. Correlation matrices (common WAV timestamps only)
ENF_corr = eye(numel(locs));
ENV_corr = eye(numel(locs));
for pi=1:np
    a=find(strcmp(locs,pairs{pi,1}));
    b=find(strcmp(locs,pairs{pi,2}));
    ENF_corr(a,b)=Timestamp_ENF_r(pi);
    ENF_corr(b,a)=Timestamp_ENF_r(pi);
    ENV_corr(a,b)=Timestamp_ENV_r(pi);
    ENV_corr(b,a)=Timestamp_ENV_r(pi);
end

%% 5. ENF and raw ENV correlation matrices

figure('Name','Experiment 5A: MUSIC pairwise correlations','Color','w');
subplot(1,2,1);
imagesc(ENF_corr,[-1 1]); axis image; colorbar;
set(gca,'XTick',1:4,'XTickLabel',locs,'YTick',1:4,'YTickLabel',locs);
title('Timestamp-aligned ENF correlation');
subplot(1,2,2);
imagesc(ENV_corr,[-1 1]); axis image; colorbar;
set(gca,'XTick',1:4,'XTickLabel',locs,'YTick',1:4,'YTickLabel',locs);
title('Timestamp-aligned raw ENV correlation');

%% 6. Save complete data for later Goertzel comparison
params = struct('Fs',Fs,'frame_N',frame_N,'hop_N',hop_N, ...
    'band_Hz',band_Hz,'music_order',music_order, ...
    'segment_seconds',segment_seconds,'high_pass_applied',false);
save(fullfile(output_folder,'Experiment5A_MUSIC_NoHighPass.mat'), ...
    'DATA','Results','ENF_corr','ENV_corr','frame_time_s','params','files','locs');
writetable(Results,fullfile(output_folder,'Experiment5A_MUSIC_NoHighPass_Pairs.csv'));
fprintf('\nSaved MAT and CSV to: %s\n',output_folder);
fprintf('NOTE: This is a 1-hour RAW-ENV baseline, not Figure 5 replication.\n');

%% Pearson correlation of jointly valid samples
function r=local_pearson(x,y)
    x=double(x(:)); y=double(y(:));
    valid=isfinite(x)&isfinite(y);
    x=x(valid); y=y(valid);
    if numel(x)<3, r=NaN; return; end
    x=x-mean(x); y=y-mean(y);
    den=sqrt(sum(x.^2)*sum(y.^2));
    if den==0, r=NaN; else, r=sum(x.*y)/den; end
end
