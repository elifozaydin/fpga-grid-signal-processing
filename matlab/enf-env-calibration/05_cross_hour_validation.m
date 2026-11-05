%% Experiment 5E — Cross-hour validation
% Apply the unchanged synthetic ENF LUT (5C) and spectral gain curve (5D)
% to three consecutive hours of historical recordings at A/K/C/G.
% Compare fixed-point Goertzel features with MUSIC without fitting to MUSIC.
% Full hourly features are recomputed on each run; MAT files are retained
% for inspection, not automatically reused. This is RAW ENV, not high-pass.

clear; clc; close all;

%% 1 -- User settings
folder = fullfile(pwd, 'recordings');  % Local recordings directory
out_dir = pwd;
base_timestamp = datetime(2023,12,21,9,0,0);
hours_to_run = 0:2;  % Hours beginning 09:00, 10:00 and 11:00 (ending 12:00).
source_ids = [3 5 2 1];
locs = {'A','K','C','G'};
pairs = {'A','K'; 'A','C'; 'A','G'; 'K','C'; 'K','G'; 'C','G'};

Fs = 1000; hour_samples = Fs*3600;
music_N = 10000; music_H = 1000;
N = 32000; HOP = 32000;
Q = 24; SW = 36; BINS = 1917:1923;
coeff = int64(round(2*cos(2*pi*BINS/N)*2^Q));
num_win = floor((hour_samples-N)/HOP)+1;  % 112
f_grid_expected = [59.925 60.075];

fC=fullfile(out_dir,'Experiment5C_ENFCalibration.mat');
fD=fullfile(out_dir,'Experiment5D_GainCompensation.mat');
assert(isfile(fC) && isfile(fD), ...
  'Run 5C and 5D first: both saved MAT files must be in current folder.');
C=load(fC,'LUT','cfg'); D0=load(fD,'gain_curve','gain_config');
assert(isfield(C,'LUT') && isfield(C,'cfg'), '5C file missing LUT/cfg.');
assert(isfield(D0,'gain_curve') && isfield(D0,'gain_config'), ...
    '5D file missing gain_curve/gain_config.');
c=C.cfg; g=D0.gain_config;
assert(c.Fs==Fs && c.N==N && c.Q==Q && c.state_width==SW && ...
    isequal(double(c.bins(:).'),BINS) && ...
    isequal(int64(c.coeff_q24(:).'),coeff),'5C configuration mismatch.');
assert(g.Fs==Fs && g.N==N && g.Q==Q && g.state_width==SW && ...
    isequal(double(g.bins(:).'),BINS) && ...
    isequal(int64(g.coeff_q24(:).'),coeff),'5D configuration mismatch.');
f_grid=double(g.f_grid(:)); gain=double(D0.gain_curve(:));
assert(numel(f_grid)==numel(gain) && all(diff(f_grid)>0) && ...
    all(isfinite(gain) & gain>0) && ...
    f_grid(1)<=f_grid_expected(1) && f_grid(end)>=f_grid_expected(2), ...
    'Invalid 5D gain curve.');

if ~exist(out_dir,'dir'),mkdir(out_dir);end
fprintf('\nCROSS-HOUR VALIDATION — FIXED SYNTHETIC CALIBRATION\n');
fprintf('---------------------------------------------------\n');
fprintf('Hours: 09:00–12:00 | 5C LUT and 5D gain curve unchanged.\n');

%% 2 -- Process each available recording hour
HourResults=table(); PairResults=table();
for hi=1:numel(hours_to_run)
    offset = hours_to_run(hi);
    ts = base_timestamp + hours(offset);
    hour_label = datestr(ts,'yyyymmdd_HHMMSS');
    cache = fullfile(out_dir,['Experiment5E_hour_' hour_label '.mat']);
    fprintf('\n--- HOUR %s (offset %+d h) ---\n',hour_label,offset);

        Features=struct(); source_description=struct();
        have_all=true;
        for li=1:4
            loc=locs{li}; id=source_ids(li);
            [fn,first,last] = locate_hour(folder,base_timestamp,ts,id,Fs);
            if isempty(fn)
                warning('Missing complete recording for %s at %s. Skipping hour.', ...
                    loc,hour_label);
                have_all=false;break;
            end
            source_description.(loc)=sprintf('%s samples %d:%d',fn,first,last);
        end
        if ~have_all,continue;end

        for li=1:4
            loc=locs{li};id=source_ids(li);
            [fn,first,last] = locate_hour(folder,base_timestamp,ts,id,Fs);
            fprintf('  Loc-%s: reading %s [%d:%d]\n',loc,fn,first,last);
            y=audioread(fn,[first last]);y=double(y(:,1));
            assert(numel(y)==hour_samples && all(isfinite(y)), ...
                'Invalid waveform at %s',loc);
            peak=max(abs(y)); assert(peak>0,'All-zero WAV at %s',loc);
            % Reproduce 5A preprocessing (MUSIC) and 5B mapping (Goertzel).
            y=y/peak; y=y-mean(y);
            y_music=bandpass(y,[59.8 60.2],Fs);
            n_music=floor((hour_samples-music_N)/music_H)+1;
            music_enf=NaN(n_music,1);music_env=NaN(n_music,1);
            for j=1:n_music
                idx=(j-1)*music_H+(1:music_N);
                frame=y_music(idx);frame=frame-mean(frame);
                try
                    [w,pow]=rootmusic(frame,2,Fs);
                    if ~isempty(w) && ~isempty(pow) && ...
                            isfinite(w(1)) && isfinite(pow(1)) && ...
                            w(1)>=59.8 && w(1)<=60.2
                        music_enf(j)=double(w(1));
                        music_env(j)=double(pow(1));
                    end
                catch ME
                    if j<=3
                        warning('Location %s frame %d: %s',loc,j,ME.message);
                    end
                end
            end
            x=int64(min(max(round(32767*y),-32768),32767));
            Psum=NaN(num_win,1); raw_f=NaN(num_win,1); dom=NaN(num_win,1);
            music_window_enf=NaN(num_win,1);
            music_window_env=NaN(num_win,1);
            mt=((0:n_music-1)'*music_H+music_N/2)/Fs;
            for j=1:num_win
                istart=(j-1)*N+1;
                xx=x(istart:istart+N-1);
                [s1,s2]=goertzel7(xx,coeff,Q,SW);
                a=double(coeff)/2^Q;
                P=max(double(s1).^2+double(s2).^2-a.*double(s1).*double(s2),0);
                Psum(j)=sum(P);
                [~,m]=max(P);dom(j)=BINS(m);
                if m>1 && m<7 && all(P(m-1:m+1)>0)
                    z=log(P(m-1:m+1)); den=z(1)-2*z(2)+z(3);
                    if isfinite(den) && den< -1e-14
                        d=0.5*(z(1)-z(3))/den;
                        if isfinite(d) && abs(d)<=1
                            raw_f(j)=(BINS(m)+d)*Fs/N;
                        end
                    end
                end
                % SAME definition as 5B: MUSIC frame centers in Goertzel window.
                t0=(istart-1)/Fs;
                midx=mt>=t0 & mt<t0+N/Fs;
                mf=music_enf(midx);me=music_env(midx);
                if ~isempty(mf) && all(isfinite(mf)),music_window_enf(j)=mean(mf);end
                if ~isempty(me) && all(isfinite(me)),music_window_env(j)=mean(me);end
            end
            cal_f=apply_lut(raw_f,dom,C.LUT);
            gain_raw=interp1(f_grid,gain,raw_f,'pchip',NaN);
            gain_cal=interp1(f_grid,gain,cal_f,'pchip',NaN);
            P_rawcorr=Psum./gain_raw;
            P_calcorr=Psum./gain_cal;
            P_rawcorr(~isfinite(gain_raw)|gain_raw<=0)=NaN;
            P_calcorr(~isfinite(gain_cal)|gain_cal<=0)=NaN;
            covered=isfinite(Psum)&Psum>0 & isfinite(raw_f) & ...
                isfinite(cal_f) & isfinite(music_window_env) & ...
                isfinite(P_rawcorr)&isfinite(P_calcorr);
            Features.(loc)=struct('music_enf',music_window_enf, ...
                'music_env',music_window_env,'raw_enf',raw_f,'cal_enf',cal_f, ...
                'raw_power',Psum,'rawfreq_power',P_rawcorr, ...
                'calfreq_power',P_calcorr,'covered',covered, ...
                'peak',peak,'dominant_bin',dom);
        end
        save(cache,'Features','source_description','-v7.3');
        fprintf('Saved hourly extracted features: %s\n',cache);

    % One row per location, correlations computed on the same set.
    for li=1:4
        loc=locs{li};a=Features.(loc);ok=a.covered & isfinite(a.music_enf);
        row=table(string(hour_label),string(loc),nnz(ok), ...
            corr_safe(a.raw_power(ok),a.music_env(ok)), ...
            corr_safe(a.rawfreq_power(ok),a.music_env(ok)), ...
            corr_safe(a.calfreq_power(ok),a.music_env(ok)), ...
            mean(abs(1000*(a.raw_enf(ok)-a.music_enf(ok)))), ...
            mean(abs(1000*(a.cal_enf(ok)-a.music_enf(ok)))), ...
            'VariableNames',{'Hour','Location','CommonWindows','Raw_ENV_r', ...
            'RawFreqComp_ENV_r','CalFreqComp_ENV_r','RawENF_MAE_mHz', ...
            'CalENF_MAE_mHz'});
        HourResults=[HourResults;row]; %#ok<AGROW>
    end

    % Correlations on identical timestamps and identical common coverage.
    for pi=1:size(pairs,1)
        aa=pairs{pi,1};bb=pairs{pi,2};
        a=Features.(aa);b=Features.(bb);
        mask=a.covered & b.covered;
        row=table(string(hour_label),string([aa '-' bb]),nnz(mask), ...
            corr_safe(a.music_env(mask),b.music_env(mask)), ...
            corr_safe(a.raw_power(mask),b.raw_power(mask)), ...
            corr_safe(a.rawfreq_power(mask),b.rawfreq_power(mask)), ...
            corr_safe(a.calfreq_power(mask),b.calfreq_power(mask)), ...
            'VariableNames',{'Hour','Pair','CommonWindows', ...
            'MUSIC_ENV_r','Raw_Goertzel_r','RawENF_Corrected_r', ...
            'CalENF_Corrected_r'});
        PairResults=[PairResults;row]; %#ok<AGROW>
    end
    writetable(HourResults,fullfile(out_dir,'Experiment5E_HourResults.csv'));
    writetable(PairResults,fullfile(out_dir,'Experiment5E_PairResults.csv'));
end

%% 3 -- Results / no unjustified aggregate correlation
assert(~isempty(HourResults),'No complete matched four-location hours found.');
% Full per-location and per-pair results remain in the CSV/MAT exports.
hoursProcessed=unique(HourResults.Hour,'stable');
MeanRawENF_MAE_mHz=NaN(numel(hoursProcessed),1);
MeanCalENF_MAE_mHz=NaN(numel(hoursProcessed),1);
MeanRawENV_r=NaN(numel(hoursProcessed),1);
MeanCalENV_r=NaN(numel(hoursProcessed),1);
for hi=1:numel(hoursProcessed)
    ix=HourResults.Hour==hoursProcessed(hi);
    MeanRawENF_MAE_mHz(hi)=mean(HourResults.RawENF_MAE_mHz(ix),'omitnan');
    MeanCalENF_MAE_mHz(hi)=mean(HourResults.CalENF_MAE_mHz(ix),'omitnan');
    MeanRawENV_r(hi)=mean(HourResults.Raw_ENV_r(ix),'omitnan');
    MeanCalENV_r(hi)=mean(HourResults.CalFreqComp_ENV_r(ix),'omitnan');
end
HourSummary=table(hoursProcessed,MeanRawENF_MAE_mHz, ...
    MeanCalENF_MAE_mHz,MeanRawENV_r,MeanCalENV_r, ...
    'VariableNames',{'Hour','RawENF_MAE_mHz','CalENF_MAE_mHz', ...
    'RawPower_MUSIC_r','CorrectedPower_MUSIC_r'});
fprintf('\n==== PER-HOUR SUMMARY (MEAN ACROSS FOUR LOCATIONS) ====\n');
disp(HourSummary);

% Aggregate: descriptive mean/median of hourly r values (NOT Fisher
% averaging of the publication; does NOT equal a pooled signal correlation).
summaryPairs=unique(PairResults.Pair,'stable');
Mean_MUSIC_r=NaN(numel(summaryPairs),1);Mean_Raw_r=Mean_MUSIC_r;
Mean_Corrected_r=Mean_MUSIC_r;Median_Corrected_r=Mean_MUSIC_r;
Hours_Used=zeros(numel(summaryPairs),1);
for i=1:numel(summaryPairs)
    ix=PairResults.Pair==summaryPairs(i) & PairResults.CommonWindows>=10;
    Hours_Used(i)=nnz(ix);
    if Hours_Used(i)==0,continue;end
    Mean_MUSIC_r(i)=mean(PairResults.MUSIC_ENV_r(ix),'omitnan');
    Mean_Raw_r(i)=mean(PairResults.Raw_Goertzel_r(ix),'omitnan');
    Mean_Corrected_r(i)=mean(PairResults.CalENF_Corrected_r(ix),'omitnan');
    Median_Corrected_r(i)=median(PairResults.CalENF_Corrected_r(ix),'omitnan');
end
Summary=table(summaryPairs,Hours_Used,Mean_MUSIC_r,Mean_Raw_r, ...
    Mean_Corrected_r,Median_Corrected_r, ...
    'VariableNames',{'Pair','HoursUsed','MeanMUSIC_r','MeanRaw_r', ...
    'MeanCorrected_r','MedianCorrected_r'});
fprintf('\n==== LOCATION-PAIR CORRELATIONS (MEAN ACROSS HOURS) ====\n');
disp(Summary(:,{'Pair','HoursUsed','MeanMUSIC_r','MeanRaw_r','MeanCorrected_r'}));

figure('Name','Experiment 5E: pairwise correlations by hour','Color','w');
for i=1:numel(summaryPairs)
    subplot(3,2,i);
    ix=PairResults.Pair==summaryPairs(i);
    t=find(ix); hold on;
    plot(1:numel(t),PairResults.MUSIC_ENV_r(ix),'-o','DisplayName','MUSIC');
    plot(1:numel(t),PairResults.Raw_Goertzel_r(ix),'-x','DisplayName','Raw Goertzel');
    plot(1:numel(t),PairResults.CalENF_Corrected_r(ix),'-s','DisplayName','Corrected');
    ylim([-1 1]);grid on;title(summaryPairs(i));xlabel('Processed hour index');
    ylabel('Pearson r');if i==1,legend('Location','best');end
end

writetable(Summary,fullfile(out_dir,'Experiment5E_Summary.csv'));
save(fullfile(out_dir,'Experiment5E_CrossHourValidation.mat'), ...
    'HourResults','PairResults','HourSummary','Summary','hours_to_run','-v7.3');
fprintf('\nSaved cross-hour tables and MAT to %s\n',out_dir);

%% Local functions
function [fn,first,last]=locate_hour(folder,base_ts,target_ts,id,Fs)
    fn='';first=NaN;last=NaN;n=Fs*3600;
    base=fullfile(folder,sprintf('power_%s_%d.wav',datestr(base_ts,'yyyymmdd_HHMMSS'),id));
    off=round(seconds(target_ts-base_ts)*Fs);
    if isfile(base) && off>=0
        inf=audioinfo(base);
        if inf.SampleRate==Fs && inf.TotalSamples>=off+n
            fn=base;first=off+1;last=off+n;return;
        end
    end
    candidate=fullfile(folder,sprintf('power_%s_%d.wav', ...
        datestr(target_ts,'yyyymmdd_HHMMSS'),id));
    if isfile(candidate)
        inf=audioinfo(candidate);
        if inf.SampleRate==Fs && inf.TotalSamples>=n
            fn=candidate;first=1;last=n;
        end
    end
end

function [s1,s2]=goertzel7(x,coeff,Q,SW)
    s1=zeros(1,numel(coeff),'int64');s2=s1;
    mask=int64(2^SW-1);half=int64(2^(SW-1));modulus=int64(2^SW);
    for j=1:numel(x)
        product=s1.*coeff;
        term=idivide(product,int64(2^Q),'floor');
        next=bitand(x(j)+term-s2,mask);
        ix=next>=half;next(ix)=next(ix)-modulus;
        s2=s1;s1=next;
    end
end

function corrected=apply_lut(raw,k,LUT)
    raw=double(raw(:));k=double(k(:));corrected=NaN(size(raw));
    for j=1:numel(LUT)
        ix=isfinite(raw) & k==LUT(j).dominant_k;
        if any(ix)
            corrected(ix)=interp1(LUT(j).raw_hz,LUT(j).true_hz, ...
                raw(ix),'pchip',NaN);
        end
    end
end

function r=corr_safe(x,y)
    x=double(x(:));y=double(y(:));ok=isfinite(x)&isfinite(y);
    x=x(ok);y=y(ok);
    if numel(x)<10,r=NaN;return;end
    x=x-mean(x);y=y-mean(y);
    den=sqrt(sum(x.^2)*sum(y.^2));
    if den==0 || ~isfinite(den),r=NaN;else,r=sum(x.*y)/den;end
end
