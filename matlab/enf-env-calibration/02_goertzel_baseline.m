%% Experiment 5B — Uncalibrated fixed-point Goertzel baseline
% Compare 32-second, seven-bin fixed-point Goertzel ENF and summed power
% against the timestamp-aligned MUSIC reference from Experiment 5A.
% Historical WAVs use Fs=1000 Hz (not the FPGA capture's 986.193 Hz).

clear; clc; close all;

%% 1. Settings
folder = fullfile(pwd, 'recordings');  % Local recordings directory
baseline_file = fullfile(pwd, 'Experiment5A_MUSIC_NoHighPass.mat');
output_folder = pwd;
Fs = 1000;
N = 32000;
HOP = N;                  % current RTL: nonoverlapping windows
STATE_W = 36;
FRAC_BITS = 24;
BINS = 1917:1923;       % seven nearest centered at k=1920 (60Hz)
INPUT_PEAK = 32767;       % normalized waveform -> signed16 surrogate

locs = {'A','K','C','G'};
pairs = {'A','K';'A','C';'A','G';'K','C';'K','G';'C','G'};
file_names = struct( ...
 'A','power_20231221_090000_3.wav', ...
 'K','power_20231221_090000_5.wav', ...
 'C','power_20231221_090000_2.wav', ...
 'G','power_20231221_090000_1.wav');

assert(isfile(baseline_file), ...
    'Cannot find 5A MAT file: %s',baseline_file);
S = load(baseline_file);
assert(isfield(S,'DATA') && isfield(S,'frame_time_s') && isfield(S,'Results'), ...
    '5A MAT file is missing DATA, frame_time_s, or Results.');
assert(isfield(S,'params') && S.params.Fs == Fs, ...
    'MUSIC baseline has unexpected sample rate.');
assert(isfield(S.params,'high_pass_applied') && ~S.params.high_pass_applied, ...
    '5A baseline must be the no-high-pass version.');
assert(isfield(S.params,'frame_N') && S.params.frame_N==10000 && ...
       S.params.hop_N==1000, 'Unexpected MUSIC frame/hop in 5A MAT.');

coeff_q24 = int64(round(2*cos(2*pi*BINS/N) * 2^FRAC_BITS));
assert(all(abs(coeff_q24) < 2^25), 'Q2.24 coefficient exceeds signed26.');
window_count = floor((Fs*3600-N)/HOP)+1;
window_start_s = (0:window_count-1)'*HOP/Fs;
window_end_s = window_start_s + N/Fs;
window_mid_s = (window_start_s+window_end_s)/2;
bin_freq = BINS * Fs/N;

fprintf('\nGOERTZEL BASELINE VS MUSIC\n');
fprintf('-------------------------\n');

%% 2. Extract Goertzel from each WAV; align MUSIC by window-center timestamps
G = struct();
for li = 1:numel(locs)
    loc = locs{li};
    filename = fullfile(folder,file_names.(loc));
    assert(isfile(filename),'Missing WAV for %s: %s',loc,filename);
    info = audioinfo(filename);
    assert(info.SampleRate==Fs && info.TotalSamples>=Fs*3600, ...
        'Invalid sample rate or duration for location %s',loc);

    y = audioread(filename,[1 Fs*3600]);
    y = double(y(:,1));
    peak = max(abs(y));
    assert(isfinite(peak) && peak>0,'Invalid signal at %s',loc);
    y = y/peak;                 % same global normalization convention as 5A
    y = y-mean(y);              % mean removed before signed16 conversion
    x = int64(min(max(round(INPUT_PEAK*y),-32768),32767));

    s1_result = zeros(window_count,7,'int64');
    s2_result = zeros(window_count,7,'int64');
    p_result = NaN(window_count,7);
    enf = NaN(window_count,1);
    dom_k = NaN(window_count,1);
    off = NaN(window_count,1);
    status = strings(window_count,1);

    for wi = 1:window_count
        first = (wi-1)*HOP+1;
        xx = x(first:first+N-1);
        [s1,s2] = recurrence36(xx,coeff_q24);
        s1_result(wi,:) = s1;
        s2_result(wi,:) = s2;
        % Same power identity as used previously; coefficient quantized.
        a = double(coeff_q24)/2^FRAC_BITS;
        P = double(s1).^2+double(s2).^2-a.*double(s1).*double(s2);
        P = max(P,0);          % numerical roundoff guard at zero
        p_result(wi,:) = P;

        % 3-point parabolic interpolation of LOG POWER, no calibration.
        [~,j] = max(P);
        dom_k(wi) = BINS(j);
        if j==1 || j==7 || any(P(j-1:j+1)<=0)
            status(wi) = "edge_or_nonpositive";
            continue;
        end
        z = log(P(j-1:j+1));
        denom = z(1)-2*z(2)+z(3);
        if ~isfinite(denom) || denom>=0 || abs(denom)<1e-14
            status(wi) = "invalid_parabola";
            continue;
        end
        d = 0.5*(z(1)-z(3))/denom;
        if ~isfinite(d) || abs(d)>1
            status(wi) = "invalid_offset";
            continue;
        end
        off(wi) = d;
        enf(wi) = (BINS(j)+d)*Fs/N;
        status(wi) = "valid";
    end

    % Raw summed power is a spectral-energy proxy, NOT voltage amplitude.
    % Compare both summed power and sqrt(power) to MUSIC's pow parameter.
    total_power = sum(p_result,2);
    amplitude_proxy = sqrt(total_power);

    % MUSIC features generated 1/s (10-s windows). Include frames whose
    % CENTER falls inside each 32-s Goertzel observation; explicitly avoid
    % point-interpolating a 10-s MUSIC feature onto a 32-s feature.
    mt = double(S.frame_time_s(:));
    music_enf = double(S.DATA.(loc).ENF(:));
    music_env = double(S.DATA.(loc).ENV(:));
    assert(numel(mt)==numel(music_enf) && numel(mt)==numel(music_env), ...
        'MUSIC baseline length mismatch for location %s',loc);
    m_enf = NaN(window_count,1);
    m_env = NaN(window_count,1);
    m_num = zeros(window_count,1);
    for wi=1:window_count
        indices = mt>=window_start_s(wi) & mt<window_end_s(wi);
        m_num(wi) = nnz(indices);
        f = music_enf(indices); v = music_env(indices);
        if ~isempty(f) && all(isfinite(f)),m_enf(wi)=mean(f);end
        if ~isempty(v) && all(isfinite(v)),m_env(wi)=mean(v);end
    end

    G.(loc).s1 = s1_result;
    G.(loc).s2 = s2_result;
    G.(loc).bin_power = p_result;
    G.(loc).power_sum = total_power;
    G.(loc).amplitude_proxy = amplitude_proxy;
    G.(loc).ENF = enf;
    G.(loc).MUSIC_ENF = m_enf;
    G.(loc).MUSIC_ENV = m_env;
    G.(loc).MUSIC_count = m_num;
    G.(loc).dominant_bin = dom_k;
    G.(loc).interp_offset = off;
    G.(loc).status = status;
    G.(loc).wav_peak = peak;

end

%% 3. Per-location accuracy table
Location = string(locs(:));
Valid_Windows = zeros(4,1);
Mean_Delta_mHz = NaN(4,1);
MAE_mHz = NaN(4,1);
RMSE_mHz = NaN(4,1);
Goertzel_vs_MUSIC_ENF_r = NaN(4,1);
GoertzelPower_vs_MUSIC_ENV_r = NaN(4,1);
for li=1:4
    a=G.(locs{li});
    valid=isfinite(a.ENF) & isfinite(a.MUSIC_ENF);
    d=(a.ENF(valid)-a.MUSIC_ENF(valid))*1000;
    Valid_Windows(li)=nnz(valid);
    if ~isempty(d)
        Mean_Delta_mHz(li)=mean(d);
        MAE_mHz(li)=mean(abs(d));
        RMSE_mHz(li)=sqrt(mean(d.^2));
    end
    Goertzel_vs_MUSIC_ENF_r(li)=localcorr(a.ENF,a.MUSIC_ENF);
    GoertzelPower_vs_MUSIC_ENV_r(li)=localcorr(a.power_sum,a.MUSIC_ENV);
end
LocationResults = table(Location,Valid_Windows,Mean_Delta_mHz,MAE_mHz,RMSE_mHz, ...
    Goertzel_vs_MUSIC_ENF_r,GoertzelPower_vs_MUSIC_ENV_r);
fprintf('\n==== PER-LOCATION RESULTS ====\n');disp(LocationResults);

%% 4. Compare location topology on common 32-s timestamps
Pair = strings(size(pairs,1),1);
MUSIC_ENF_r = NaN(size(Pair));
Goertzel_ENF_r = NaN(size(Pair));
MUSIC_ENV_r = NaN(size(Pair));
Goertzel_Power_r = NaN(size(Pair));
Goertzel_Amplitude_r = NaN(size(Pair));
for pi=1:numel(Pair)
    a=pairs{pi,1};b=pairs{pi,2};
    Pair(pi)=string(a)+'-'+string(b);
    MUSIC_ENF_r(pi)=localcorr(G.(a).MUSIC_ENF,G.(b).MUSIC_ENF);
    Goertzel_ENF_r(pi)=localcorr(G.(a).ENF,G.(b).ENF);
    MUSIC_ENV_r(pi)=localcorr(G.(a).MUSIC_ENV,G.(b).MUSIC_ENV);
    Goertzel_Power_r(pi)=localcorr(G.(a).power_sum,G.(b).power_sum);
    Goertzel_Amplitude_r(pi)=localcorr(G.(a).amplitude_proxy,G.(b).amplitude_proxy);
end
PairResults = table(Pair,MUSIC_ENF_r,Goertzel_ENF_r,MUSIC_ENV_r, ...
    Goertzel_Power_r,Goertzel_Amplitude_r);
fprintf('\n==== RAW ENV TOPOLOGY: IDENTICAL 32-s TIMESTAMPS ====\n');
disp(PairResults);
fprintf(['NOTE: MUSIC power is averaged from 1-s estimates. Correlation is\n' ...
    'comparable, but absolute power magnitudes have different definitions.\n']);

%% 5. Raw ENV correlations across locations

figure('Name','Experiment 5B: raw ENV correlations','Color','w');
bar(categorical(Pair),[MUSIC_ENV_r Goertzel_Power_r]);
ylim([-1 1]);
ylabel('Pearson correlation');
title('MUSIC raw ENV vs. uncorrected Goertzel summed power');
legend('MUSIC raw ENV','Goertzel summed power','Location','best');
grid on;

%% 6. Save raw uncalibrated features for calibration study
params5B=struct('Fs',Fs,'N',N,'hop',HOP,'bins',BINS, ...
    'coeff_q24',coeff_q24,'state_width',STATE_W,'frac_bits',FRAC_BITS, ...
    'input_peak',INPUT_PEAK,'input_method', ...
    'global_peak_normalization_DC_removal_round_to_signed16_no_bandpass', ...
    'MUSIC_alignment','average 1-s MUSIC estimates by 32-s window center');
if ~exist(output_folder,'dir'),mkdir(output_folder);end
save(fullfile(output_folder,'Experiment5B_UncalibratedGoertzel.mat'), ...
    'G','LocationResults','PairResults','params5B','window_start_s', ...
    'window_end_s','window_mid_s','bin_freq','-v7.3');
writetable(LocationResults,fullfile(output_folder,'Experiment5B_LocationResults.csv'));
writetable(PairResults,fullfile(output_folder,'Experiment5B_PairResults.csv'));
fprintf('\nSaved Experiment5B MAT and CSV results in %s\n',output_folder);

%% Local functions
function [s1,s2] = recurrence36(samples,coeff)
% Identical recurrence rules to successfully replayed Exp 4B MATLAB model.
% s0 = x + ((coeff * s1) >>> 24) - s2, with signed36 wrap.
    s1=zeros(1,numel(coeff),'int64');
    s2=zeros(1,numel(coeff),'int64');
    mask=int64(2^36-1);signbit=int64(2^35);modulus=int64(2^36);
    for n=1:numel(samples)
        product=coeff.*s1; % max product fits in signed int64
        shifted=idivide(product,int64(2^24),'floor');
        tmp=samples(n)+shifted-s2;
        next=bitand(tmp,mask);
        neg=next>=signbit;
        next(neg)=next(neg)-modulus;
        s2=s1;s1=next;
    end
end

function r=localcorr(x,y)
    x=double(x(:));y=double(y(:));
    ok=isfinite(x)&isfinite(y);x=x(ok);y=y(ok);
    if numel(x)<3,r=NaN;return;end
    x=x-mean(x);y=y-mean(y);
    den=sqrt(sum(x.^2)*sum(y.^2));
    if den==0,r=NaN;else,r=sum(x.*y)/den;end
end

