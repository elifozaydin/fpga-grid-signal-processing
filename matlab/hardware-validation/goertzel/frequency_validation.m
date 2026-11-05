function result = frequency_validation(verified, show_plot)
%FREQUENCY_VALIDATION Compare FPGA-derived ENF with ROOT-MUSIC for both
% architectures, using the exact capture and alignment already verified.
% Requires VERIFIED returned by bitexact_hardware_validation.
    if nargin<2 || isempty(show_plot),show_plot=true;end
    assert(isstruct(verified)&&isfield(verified,'passed')&&verified.passed, ...
        'Run bitexact_hardware_validation first.');
    assert(exist('rootmusic','file')~=0, ...
        'ROOT-MUSIC requires Signal Processing Toolbox.');
    data=verified.data;offset=verified.offset_samples;
    wids=data.wids;N=data.N;Fs=data.Fs;bins=data.bins;
    coeff_q24=[31139567 31137112 31134656 31132199 ...
               31129741 31127281 31124821];
    M=64;band=[59.8 60.2];nw=numel(wids);
    f_goertzel=nan(nw,1);f_music=nan(nw,1);
    for wi=1:nw
        w=wids(wi);i1=offset+w*N+1;i2=i1+N-1;
        x=data.raw(i1:i2);
        s1=double(data.hw_s1(wi,:));
        s2=double(data.hw_s2(wi,:));
        P=s1.^2+s2.^2-(coeff_q24/2^24).*s1.*s2;
        if any(~isfinite(P))||any(P<=0),continue;end
        [~,imax]=max(P);
        if imax==1||imax==numel(bins),continue;end
        L=log(P(imax-1:imax+1));
        den=L(1)-2*L(2)+L(3);
        if ~isfinite(den)||den>=0||abs(den)<1e-12,continue;end
        delta=0.5*(L(1)-L(3))/den;
        if ~isfinite(delta)||abs(delta)>1,continue;end
        f_goertzel(wi)=(bins(imax)+delta)*Fs/N;

        % Same covariance-based ROOT-MUSIC as the previous scripts.
        x=x-mean(x);
        normalizer=max(abs(x));
        if normalizer==0,continue;end
        x=x/normalizer;
        X=hankel(x(1:M),x(M:end));
        C=(X*X')/size(X,2);
        C=(C+C')/2;
        try
            roots=real(rootmusic(C,2,'corr',Fs));
            hits=roots(isfinite(roots)&roots>=band(1)&roots<=band(2));
            if numel(hits)==1,f_music(wi)=hits(1);end
        catch ME
            warning('ROOT-MUSIC failed for window %d: %s',w,ME.message);
        end
    end
    valid=isfinite(f_goertzel)&isfinite(f_music);
    assert(any(valid),'No windows have both valid ENF estimates.');
    diff_mHz=1000*(f_goertzel-f_music);
    d=diff_mHz(valid);
    mae=mean(abs(d));rmse=sqrt(mean(d.^2));r=NaN;
    if nnz(valid)>=2
        cc=corrcoef(f_goertzel(valid),f_music(valid));
        r=cc(1,2);
    end
    fprintf('\nFPGA GOERTZEL VS ROOT-MUSIC (%s)\n',upper(data.architecture));
    fprintf('Valid observations: %d/%d\n',nnz(valid),nw);
    fprintf('Window     Goertzel (Hz)    ROOT-MUSIC (Hz)    Difference (mHz)\n');
    for wi=find(valid).'
        fprintf('%6d     %13.9f    %15.9f     %+9.3f\n', ...
            wids(wi),f_goertzel(wi),f_music(wi),diff_mHz(wi));
    end
    fprintf('MAE %.4f mHz | RMSE %.4f mHz | Pearson r %.5f\n', ...
        mae,rmse,r);
    result=struct('architecture',data.architecture,'Fs',Fs, ...
        'window_ids',wids,'f_goertzel',f_goertzel,'f_music',f_music, ...
        'valid',valid,'difference_mHz',diff_mHz, ...
        'mae_mHz',mae,'rmse_mHz',rmse,'correlation',r);
    if show_plot
        centers=(wids(:)*N+N/2+offset)/Fs;
        figure('Name','FPGA Goertzel vs ROOT-MUSIC','Color','w');
        plot(centers/60,f_goertzel,'o-','LineWidth',1.2);
        hold on;plot(centers/60,f_music,'s-','LineWidth',1.2);
        xlabel('Time since session start (min)');
        ylabel('Estimated ENF (Hz)');grid on;
        legend('FPGA Goertzel','ROOT-MUSIC','Location','best');
        title(sprintf('%s Goertzel vs ROOT-MUSIC',data.architecture));
    end
end
