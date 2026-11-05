%% Experiment 5C — Synthetic ENF calibration
% Train bin-specific LUTs with known-frequency synthetic sinusoids,
% validate on unseen frequencies/amplitudes/phases, then compare against MUSIC.
% The seven-bin Goertzel recurrence uses signed16 input, Q2.24 coefficients,
% signed36 states, floor division, and wrapping (Fs=1000 Hz, N=32000).

clear; clc; close all;

%% 1. Configuration
in_file  = fullfile(pwd,'Experiment5B_UncalibratedGoertzel.mat');
out_dir  = pwd;
Fs = 1000; N = 32000; BINS = 1917:1923;
Q = 24; SW = 36;
COEFF = int64(round(2*cos(2*pi*BINS/N)*2^Q));

% Keep training inside the usable seven-bin interpolation range.
f_train = (59.940:0.0005:60.060).';   % 0.5 mHz training grid
f_test  = (59.94025:0.0005:60.05975).'; % 0.25 mHz offset from training
train_amplitude = 24000;
train_phase = 0.31;
validation_amplitudes = [12000 28000];
validation_phases = [1.13 2.19];
block_size = 24;       % limits synthetic signal matrix memory

assert(isfile(in_file),'Cannot find Experiment 5B MAT: %s',in_file);
D = load(in_file);
assert(isfield(D,'G') && isfield(D,'params5B'),'Missing G/params5B from 5B MAT.');
p = D.params5B;
assert(p.Fs==Fs && p.N==N && isequal(double(p.bins(:).'),BINS) && ...
       p.frac_bits==Q && p.state_width==SW && ...
       isequal(int64(p.coeff_q24(:).'),COEFF), ...
       '5B configuration disagrees with this calibration; do not apply LUT.');

fprintf('\nENF CALIBRATION — SYNTHETIC LUT\n');
fprintf('--------------------------------\n');
fprintf('MUSIC is used only for evaluation, not LUT training.\n');

%% 2. Generate TRAINING data using the integer recurrence
fprintf('\nTraining synthetic calibration LUT...\n');
[train_raw,train_k,train_valid] = run_sweep(f_train,train_amplitude,train_phase, ...
    Fs,N,BINS,COEFF,Q,SW,block_size);
assert(all(train_valid),'Training produced invalid 3-point estimates; narrow calibration range.');

% Separate LUT for each dominant bin: raw interpolation can be piecewise
% due to transitions in the maximum-power bin. Never fit through jumps.
LUT = struct('dominant_k',{},'raw_hz',{},'true_hz',{});
for b=1:numel(BINS)
    k = BINS(b);
    idx = train_valid & train_k==k;
    if nnz(idx)<4,continue;end
    xr = train_raw(idx); yt = f_train(idx);
    [xr,ii] = sort(xr(:)); yt = yt(ii);
    if any(diff(xr)<=0)
        error('Training mapping nonmonotone/duplicate in dominant bin %d. Investigate.',k);
    end
    LUT(end+1).dominant_k = k; %#ok<SAGROW>
    LUT(end).raw_hz = xr;
    LUT(end).true_hz = yt;
end
assert(~isempty(LUT),'No LUT entries generated.');

%% 3. Held-out TEST: different frequencies, phases, and amplitudes
fprintf('\nEvaluating held-out synthetic cases...\n');
Test = table();
for ai=1:numel(validation_amplitudes)
    for ph=1:numel(validation_phases)
        amp = validation_amplitudes(ai); phase=validation_phases(ph);
        [raw,k,valid] = run_sweep(f_test,amp,phase, ...
            Fs,N,BINS,COEFF,Q,SW,block_size);
        calibrated = apply_lut(raw,k,LUT);
        n = numel(f_test);
        block = table(repmat(amp,n,1),repmat(phase,n,1),f_test,raw, ...
            calibrated,k,valid,isfinite(calibrated), ...
            'VariableNames',{'Amplitude','Phase_rad','True_Hz','Raw_Hz', ...
            'Calibrated_Hz','Dominant_k','RawValid','CalibrationValid'});
        Test = [Test;block]; %#ok<AGROW>
    end
end
raw_ok = Test.RawValid & isfinite(Test.Raw_Hz);
cal_ok = raw_ok & Test.CalibrationValid;
if ~any(cal_ok)
    error('LUT has no coverage of validation tests.');
end
raw_error_covered = 1000*(Test.Raw_Hz(cal_ok)-Test.True_Hz(cal_ok));
cal_error_covered = 1000*(Test.Calibrated_Hz(cal_ok)-Test.True_Hz(cal_ok));

fprintf('\nSYNTHETIC HELD-OUT VALIDATION\n');
fprintf('-----------------------------\n');
fprintf('Valid raw estimates:      %d / %d\n',nnz(raw_ok),height(Test));
fprintf('LUT-covered cases:        %d / %d\n',nnz(cal_ok),height(Test));
fprintf('Raw MAE (covered):        %.5f mHz\n',mean(abs(raw_error_covered)));
fprintf('Calibrated MAE (covered): %.5f mHz\n',mean(abs(cal_error_covered)));
fprintf('Maximum calibrated error: %.5f mHz\n',max(abs(cal_error_covered)));

%% 4. Apply the synthetic-only LUT to the previously computed REAL 5B ENF
locs={'A','K','C','G'};
Location = string(locs(:));
Count = zeros(4,1); Covered = zeros(4,1);
Raw_MAE_mHz=NaN(4,1); Cal_MAE_mHz=NaN(4,1);
Raw_RMSE_mHz=NaN(4,1);Cal_RMSE_mHz=NaN(4,1);
Raw_r=NaN(4,1);Cal_r=NaN(4,1);
R=struct();

fprintf('\nHISTORICAL WAVS VS MUSIC — MATCHED LUT COVERAGE\n');
for li=1:numel(locs)
    loc=locs{li}; g=D.G.(loc);
    raw=double(g.ENF(:));
    k=double(g.dominant_bin(:));
    music=double(g.MUSIC_ENF(:));
    corrected=apply_lut(raw,k,LUT);
    R.(loc).raw=raw; R.(loc).corrected=corrected;
    R.(loc).music=music; R.(loc).dominant_k=k;
    base=isfinite(raw)&isfinite(music);
    mask=base&isfinite(corrected);
    Count(li)=nnz(base); Covered(li)=nnz(mask);
    if any(mask)
        raw_delta = 1000*(raw(mask)-music(mask));
        cal_delta = 1000*(corrected(mask)-music(mask));
        Raw_MAE_mHz(li)=mean(abs(raw_delta));
        Raw_RMSE_mHz(li)=sqrt(mean(raw_delta.^2));
        Raw_r(li)=localcorr(raw(mask),music(mask));
        Cal_MAE_mHz(li)=mean(abs(cal_delta));
        Cal_RMSE_mHz(li)=sqrt(mean(cal_delta.^2));
        Cal_r(li)=localcorr(corrected(mask),music(mask));
    end
end
RealResults=table(Location,Count,Covered,Raw_MAE_mHz,Cal_MAE_mHz, ...
    Raw_RMSE_mHz,Cal_RMSE_mHz,Raw_r,Cal_r);
fprintf('\n==== REAL-DATA SUMMARY ====\n');disp(RealResults);

%% 5. Historical ENF disagreement (same covered windows)

figure('Name','Experiment 5C: ENF calibration vs MUSIC','Color','w');
for li=1:4
    loc=locs{li};
    subplot(4,1,li);
    rr=R.(loc);
    covered=isfinite(rr.raw)&isfinite(rr.corrected)&isfinite(rr.music);
    raw_error=NaN(size(rr.raw));
    calibrated_error=NaN(size(rr.raw));
    raw_error(covered)=1000*(rr.raw(covered)-rr.music(covered));
    calibrated_error(covered)=1000*(rr.corrected(covered)-rr.music(covered));
    plot(raw_error,'-','DisplayName','Raw'); hold on;
    plot(calibrated_error,'-','DisplayName','Calibrated');
    ylabel([loc ' (mHz)']); grid on;
    if li==1
        title('Goertzel minus MUSIC — identical covered windows');
        legend('Location','best');
    end
    if li==4, xlabel('Window index'); end
end

%% 6. Save reusable LUT and experiment outputs
if ~exist(out_dir,'dir'),mkdir(out_dir);end
cfg=struct('Fs',Fs,'N',N,'bins',BINS,'Q',Q,'state_width',SW, ...
    'coeff_q24',COEFF,'training_amplitude',train_amplitude, ...
    'training_phase',train_phase,'training_grid_hz',f_train, ...
    'test_grid_hz',f_test,'interpolation','pchip per dominant bin; no extrapolation');
save(fullfile(out_dir,'Experiment5C_ENFCalibration.mat'), ...
    'LUT','cfg','Test','RealResults','R','train_raw','train_k','f_train','-v7.3');
writetable(Test,fullfile(out_dir,'Experiment5C_SyntheticValidation.csv'));
writetable(RealResults,fullfile(out_dir,'Experiment5C_RealResults.csv'));
fprintf('\nSaved LUT, synthetic validation, and real results in %s\n',out_dir);

%% =================== LOCAL FUNCTIONS ===========================
function [raw,k,valid] = run_sweep(freq,amp,phase,Fs,N,bins,coeff,Q,SW,block_size)
% Vectorized across simultaneous independent frequencies and seven bins.
% Integer arithmetic is the same floor-shift, signed-state-wrap model as 4B.
    freq=double(freq(:)); m=numel(freq);
    raw=NaN(m,1);k=NaN(m,1);valid=false(m,1);
    nb=numel(bins);
    mask=int64(2^SW-1); half=int64(2^(SW-1)); modulus=int64(2^SW);
    for st=1:block_size:m
        en=min(st+block_size-1,m);
        f=freq(st:en).'; ns=numel(f);
        n=(0:N-1)';
        x=int64(round(amp*sin(2*pi*(n/Fs)*f+phase)));
        assert(all(x(:)<=32767 & x(:)>=-32768),'Synthetic signed16 out of range.');
        s1=zeros(ns,nb,'int64');s2=s1;
        c=reshape(coeff,1,nb);
        for t=1:N
            % ns-by-7 products are bounded by signed 64-bit range.
            prod=s1.*c;
            shifted=idivide(prod,int64(2^Q),'floor');
            next=bitand(shifted-s2+x(t,:).',mask);
            negative=next>=half;
            next(negative)=next(negative)-modulus;
            s2=s1;s1=next;
        end
        cc=double(c)/2^Q;
        P=double(s1).^2+double(s2).^2-cc.*double(s1).*double(s2);
        P=max(P,0);
        [~,ix]=max(P,[],2);
        for jj=1:ns
            j=ix(jj);k(st+jj-1)=bins(j);
            if j==1 || j==nb,continue;end
            z=P(jj,j-1:j+1);
            if any(z<=0),continue;end
            z=log(z);
            den=z(1)-2*z(2)+z(3);
            if ~isfinite(den) || den>=0 || abs(den)<1e-14,continue;end
            d=.5*(z(1)-z(3))/den;
            if ~isfinite(d)||abs(d)>1,continue;end
            raw(st+jj-1)=(bins(j)+d)*Fs/N;
            valid(st+jj-1)=true;
        end
    end
end

function corrected=apply_lut(raw,k,LUT)
% Bin-specific LUT: no extrapolation to untrained frequency regions.
    raw=double(raw(:));k=double(k(:));corrected=NaN(size(raw));
    for jj=1:numel(LUT)
        ix=isfinite(raw)&k==LUT(jj).dominant_k;
        if ~any(ix),continue;end
        corrected(ix)=interp1(LUT(jj).raw_hz,LUT(jj).true_hz, ...
            raw(ix),'pchip',NaN);
    end
end

function r=localcorr(x,y)
    x=double(x(:));y=double(y(:));ok=isfinite(x)&isfinite(y);
    x=x(ok);y=y(ok);if numel(x)<3,r=NaN;return;end
    x=x-mean(x);y=y-mean(y);den=sqrt(sum(x.^2)*sum(y.^2));
    if den==0,r=NaN;else,r=sum(x.*y)/den;end
end
