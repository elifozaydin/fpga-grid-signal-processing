%% Experiment 5D — Synthetic Goertzel spectral-gain compensation
% Estimate seven-bin power gain G(f) using fixed-point synthetic sinusoids.
% Compare raw power with gain-compensated power using raw and calibrated ENF.
% MUSIC is an evaluation reference only, never used to train the gain curve.
% All correlations use common timestamps and the same covered windows.
% This is raw ENV feature analysis, not the paper's high-pass ENV analysis.

clear; clc; close all;

%% 1. CONFIGURATION / SOURCE VALIDATION
workdir = pwd;
fileB = fullfile(workdir,'Experiment5B_UncalibratedGoertzel.mat');
fileC = fullfile(workdir,'Experiment5C_ENFCalibration.mat');
assert(isfile(fileB),'Missing Experiment 5B MAT: %s',fileB);
assert(isfile(fileC),'Missing Experiment 5C MAT: %s',fileC);
B = load(fileB,'G','params5B','window_mid_s');
C = load(fileC,'R','cfg');
assert(isfield(B,'G') && isfield(B,'params5B'),'Invalid 5B MAT.');
assert(isfield(C,'R') && isfield(C,'cfg'),'Invalid 5C MAT.');

Fs = 1000; N = 32000; Q = 24; SW = 36;
BINS = 1917:1923;
COEFF = int64(round(2*cos(2*pi*BINS/N)*2^Q));
p = B.params5B; c = C.cfg;
assert(p.Fs==Fs && p.N==N && p.hop==N && p.state_width==SW ...
    && p.frac_bits==Q && isequal(double(p.bins(:).'),BINS) ...
    && isequal(int64(p.coeff_q24(:).'),COEFF), ...
    'Experiment 5B configuration mismatch.');
assert(c.Fs==Fs && c.N==N && c.Q==Q && c.state_width==SW ...
    && isequal(double(c.bins(:).'),BINS) ...
    && isequal(int64(c.coeff_q24(:).'),COEFF), ...
    'Experiment 5C LUT configuration mismatch.');

locs = {'A','K','C','G'};
pairNames = {'A','K';'A','C';'A','G';'K','C';'K','G';'C','G'};
nWin = numel(B.window_mid_s);
assert(nWin > 5,'Too few Goertzel observations.');

% Synthetic gain curve: denser than the 5C training sweep, extends past
% most 5C corrected-frequency values, but never extrapolates.
f_grid = (59.925:0.00025:60.075).';    % 0.25 mHz resolution
amp_train = 24000;                    % within signed16 range
phases_train = [0.31,1.13,2.19];     % average away phase dependence
block_size = 24;

fprintf('\nENV COMPENSATION — SYNTHETIC GAIN\n');
fprintf('---------------------------------\n');
fprintf('Gain is derived synthetically; MUSIC is evaluation-only.\n');
fprintf('Building gain curve from %d frequencies and %d phases...\n', ...
    numel(f_grid),numel(phases_train));

%% 2. SYNTHETICALLY MEASURE FREQUENCY-DEPENDENT POWER GAIN
% Each synthetic waveform has known amplitude amp_train.
% The recurrence and summed-power expression match 5B.
gain_by_phase = zeros(numel(f_grid),numel(phases_train));
for ip=1:numel(phases_train)
    powers = synthetic_power_sweep(f_grid,amp_train,phases_train(ip), ...
        Fs,N,COEFF,Q,SW,block_size);
    gain_by_phase(:,ip) = powers / amp_train^2;
end
gain_curve = mean(gain_by_phase,2);
assert(all(isfinite(gain_curve) & gain_curve > 0), ...
    'Invalid synthetic gain curve.');

rel_phase_span_pct = 100*(max(gain_by_phase,[],2)- ...
    min(gain_by_phase,[],2))./gain_curve;
fprintf('Gain max/min ratio over sweep: %.4f\n', ...
    max(gain_curve)/min(gain_curve));
fprintf('Phase sensitivity: median %.5f%%, maximum %.5f%%\n', ...
    median(rel_phase_span_pct),max(rel_phase_span_pct));

%% 3. APPLY GAIN CURVE TO REAL 5B POWER, USING 5C FREQUENCY LUT
D = struct();
Names = string(locs(:));
N_Total = zeros(4,1); N_Covered = zeros(4,1);
Raw_vs_MUSIC_r = NaN(4,1);
RawFrequencyCorrected_vs_MUSIC_r = NaN(4,1);
CalFrequencyCorrected_vs_MUSIC_r = NaN(4,1);
CalFrequencyCorrectedSqrt_vs_MUSIC_r = NaN(4,1);

for li=1:4
    loc = locs{li};
    b = B.G.(loc);
    assert(isfield(C.R,loc),'Location %s missing in 5C.',loc);
    raw_f = double(b.ENF(:));
    cal_f = double(C.R.(loc).corrected(:));
    pow = double(b.power_sum(:));
    music_env = double(b.MUSIC_ENV(:));
    assert(numel(pow)==nWin && numel(raw_f)==nWin && ...
        numel(cal_f)==nWin && numel(music_env)==nWin, ...
        'Length mismatch at location %s.',loc);

    % pchip interpolation is shape preserving; outside curve => NaN.
    gain_raw = interp1(f_grid,gain_curve,raw_f,'pchip',NaN);
    gain_cal = interp1(f_grid,gain_curve,cal_f,'pchip',NaN);
    corr_raw_f = pow ./ gain_raw;
    corr_cal_f = pow ./ gain_cal;
    corr_raw_f(~isfinite(gain_raw) | gain_raw<=0) = NaN;
    corr_cal_f(~isfinite(gain_cal) | gain_cal<=0) = NaN;
    sqrt_raw = sqrt(max(pow,0));
    sqrt_corr_cal = sqrt(max(corr_cal_f,0));

    % Restrict EVERY correlation in the main per-location table to
    % exactly the same windows where calibrated frequency is available.
    covered = isfinite(pow) & pow>0 & isfinite(music_env) & ...
        isfinite(corr_raw_f) & isfinite(corr_cal_f) & ...
        isfinite(cal_f);
    N_Total(li) = nWin;
    N_Covered(li) = nnz(covered);
    assert(nnz(covered)>=10, ...
        'Fewer than 10 jointly covered windows at %s.',loc);

    D.(loc) = struct('raw_power',pow, 'raw_freq_Hz',raw_f, ...
        'cal_freq_Hz',cal_f,'music_env',music_env, ...
        'gain_raw',gain_raw,'gain_cal',gain_cal, ...
        'corrected_using_raw_ENF',corr_raw_f, ...
        'corrected_using_cal_ENF',corr_cal_f, ...
        'raw_amplitude',sqrt_raw, ...
        'corrected_amplitude',sqrt_corr_cal, ...
        'covered',covered);

    Raw_vs_MUSIC_r(li) = pearson(pow(covered),music_env(covered));
    RawFrequencyCorrected_vs_MUSIC_r(li) = ...
        pearson(corr_raw_f(covered),music_env(covered));
    CalFrequencyCorrected_vs_MUSIC_r(li) = ...
        pearson(corr_cal_f(covered),music_env(covered));
    CalFrequencyCorrectedSqrt_vs_MUSIC_r(li) = ...
        pearson(sqrt_corr_cal(covered),music_env(covered));

end

LocationResults = table(Names,N_Total,N_Covered, ...
    Raw_vs_MUSIC_r,RawFrequencyCorrected_vs_MUSIC_r, ...
    CalFrequencyCorrected_vs_MUSIC_r, ...
    CalFrequencyCorrectedSqrt_vs_MUSIC_r, ...
    'VariableNames',{'Location','TotalWindows','CommonWindows', ...
    'RawPower_MUSIC_r','RawENFCorrectedPower_MUSIC_r', ...
    'CalENFCorrectedPower_MUSIC_r', ...
    'CalENFCorrectedAmplitude_MUSIC_r'});

fprintf('\n==== SAME-LOCATION AGREEMENT WITH MUSIC RAW ENV ====\n');
disp(LocationResults(:,{'Location','TotalWindows','CommonWindows', ...
    'RawPower_MUSIC_r','RawENFCorrectedPower_MUSIC_r', ...
    'CalENFCorrectedPower_MUSIC_r'}));

%% 4. CROSS-LOCATION TOPOLOGY CORRELATIONS (MATCHED COVERAGE)
np = size(pairNames,1);
Pair = strings(np,1);
CommonWindows = zeros(np,1);
Music_ENV_r = NaN(np,1);
Raw_Goertzel_Power_r = NaN(np,1);
RawENF_Corrected_Power_r = NaN(np,1);
CalENF_Corrected_Power_r = NaN(np,1);
CalENF_Corrected_Amplitude_r = NaN(np,1);
for pi=1:np
    aa=pairNames{pi,1};bb=pairNames{pi,2};
    Pair(pi)=string(aa)+'-'+string(bb);
    a=D.(aa); b=D.(bb);
    mask=a.covered & b.covered;
    CommonWindows(pi)=nnz(mask);
    if nnz(mask)<10
        warning('Only %d matched windows for pair %s.',nnz(mask),Pair(pi));
        continue;
    end

    % Consistent timestamp windows and identical coverage across columns.
    Music_ENV_r(pi)=pearson(a.music_env(mask),b.music_env(mask));
    Raw_Goertzel_Power_r(pi)= ...
        pearson(a.raw_power(mask),b.raw_power(mask));
    RawENF_Corrected_Power_r(pi)=pearson( ...
        a.corrected_using_raw_ENF(mask), b.corrected_using_raw_ENF(mask));
    CalENF_Corrected_Power_r(pi)=pearson( ...
        a.corrected_using_cal_ENF(mask), b.corrected_using_cal_ENF(mask));
    CalENF_Corrected_Amplitude_r(pi)=pearson( ...
        a.corrected_amplitude(mask), b.corrected_amplitude(mask));
end
PairResults = table(Pair,CommonWindows,Music_ENV_r, ...
    Raw_Goertzel_Power_r,RawENF_Corrected_Power_r, ...
    CalENF_Corrected_Power_r,CalENF_Corrected_Amplitude_r);
fprintf('\n==== LOCATION TOPOLOGY (COMMON 32-SECOND WINDOWS) ====\n');
disp(PairResults(:,{'Pair','CommonWindows','Music_ENV_r', ...
    'Raw_Goertzel_Power_r','RawENF_Corrected_Power_r', ...
    'CalENF_Corrected_Power_r'}));

%% 5. Location-pair correlation comparison
figure('Name','Experiment 5D: location-pair raw ENV correlations','Color','w');
bar(categorical(Pair),[Music_ENV_r,Raw_Goertzel_Power_r, ...
    RawENF_Corrected_Power_r,CalENF_Corrected_Power_r]);
ylabel('Pearson correlation');
ylim([-1,1]); grid on;
title('MUSIC raw ENV vs raw and frequency-compensated Goertzel power');
legend('MUSIC raw ENV','Raw Goertzel','Corrected using raw ENF', ...
    'Corrected using calibrated ENF','Location','best');

%% 6. SAVE
gain_config = struct('Fs',Fs,'N',N,'bins',BINS, ...
    'coeff_q24',COEFF,'Q',Q,'state_width',SW, ...
    'amplitude_train',amp_train,'phases_train',phases_train, ...
    'f_grid',f_grid, ...
    'interpolation','pchip no extrapolation', ...
    'gain_definition','sum_7_bin_P(f,A,phase) / A^2');
save(fullfile(workdir,'Experiment5D_GainCompensation.mat'), ...
    'D','LocationResults','PairResults','gain_config', ...
    'gain_curve','gain_by_phase','rel_phase_span_pct','-v7.3');
writetable(LocationResults,fullfile(workdir,'Experiment5D_LocationResults.csv'));
writetable(PairResults,fullfile(workdir,'Experiment5D_PairResults.csv'));
fprintf('\nSaved 5D MAT and CSV results to %s\n',workdir);

%% LOCAL FUNCTIONS
function power_sum=synthetic_power_sweep(freq,amp,phase,Fs,N,coeff,Q,SW,block_size)
    % Vectorized across frequencies and bins, bit-accurate recurrence.
    freq=double(freq(:));nf=numel(freq);nb=numel(coeff);
    power_sum=zeros(nf,1);
    mask=int64(2^SW-1);
    half=int64(2^(SW-1));
    modulus=int64(2^SW);
    for start=1:block_size:nf
        stop=min(nf,start+block_size-1);
        f=freq(start:stop).';
        ns=numel(f);
        n=(0:N-1)';
        xin=int64(round(amp*sin(2*pi*(n/Fs)*f+phase)));
        assert(all(xin(:)>=-32768 & xin(:)<=32767), ...
            'Synthetic input exceeds signed16.');
        s1=zeros(ns,nb,'int64');s2=s1;
        coeffrow=reshape(coeff,1,nb);
        for t=1:N
            prod=s1.*coeffrow;
            shifted=idivide(prod,int64(2^Q),'floor');
            updated=bitand(shifted-s2+xin(t,:).',mask);
            neg=updated>=half;
            updated(neg)=updated(neg)-modulus;
            s2=s1;s1=updated;
        end
        cr=double(coeffrow)/2^Q;
        P=double(s1).^2+double(s2).^2- ...
            cr.*double(s1).*double(s2);
        P=max(P,0);
        power_sum(start:stop)=sum(P,2);
    end
end

function r=pearson(x,y)
    x=double(x(:));y=double(y(:));
    good=isfinite(x)&isfinite(y);
    x=x(good);y=y(good);
    if numel(x)<3,r=NaN;return;end
    x=x-mean(x);y=y-mean(y);
    denom=sqrt(sum(x.^2)*sum(y.^2));
    if denom<=0 || ~isfinite(denom),r=NaN;else,r=sum(x.*y)/denom;end
end
