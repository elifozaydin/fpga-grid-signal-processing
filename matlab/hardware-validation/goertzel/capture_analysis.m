function data = capture_analysis(capture_file, architecture, session_id, show_plots)
%CAPTURE_ANALYSIS Inspect an FPGA capture from either Goertzel architecture.
% DATA = capture_analysis(capture_file,'parallel' or 'shared',session_id,plots)
% ARCHITECTURE is a user-declared label; the packet format is identical.
    if nargin < 2 || isempty(architecture), architecture = 'parallel'; end
    if nargin < 3 || isempty(session_id), session_id = 1; end
    if nargin < 4 || isempty(show_plots), show_plots = true; end
    architecture=lower(char(architecture));
    assert(any(strcmp(architecture,{'parallel','shared'})), ...
        'Architecture must be parallel or shared.');
    assert(isfile(capture_file),'Capture not found: %s',capture_file);
    % Multiple hardware-validation folders contain a function named parser.
    % Select the Goertzel parser explicitly before decoding the capture.
    here = fileparts(mfilename('fullpath'));
    addpath(here, '-begin');
    expected_parser = fullfile(here, 'parser.m');
    resolved_parser = which('parser');
    assert(isfile(resolved_parser) && ...
        strcmp(fileread(resolved_parser), fileread(expected_parser)), ...
        'MATLAB resolved a different parser.m: %s', resolved_parser);
    N=32000; bins=1944:1950;
    [T,timing,G]=parser(capture_file);
    S=T(T.session_id==session_id,:);
    Q=timing(timing.session_id==session_id,:);
    H=G(G.session_id==session_id,:);
    assert(~isempty(S),'No CIC samples in selected session.');
    assert(~isempty(Q),'No timing measurements in selected session.');
    assert(~isempty(H),'No Goertzel states in selected session.');
    % sample_idx is assigned sequentially by parser.m; it cannot detect
    % CIC frames lost before or during packet capture.

    raw_int=int64(S.cic_raw(:));
    scaled_int=idivide(raw_int,int64(2^16),'floor');
    scaled_int=min(max(scaled_int,int64(-32768)),int64(32767));
    scaled=double(scaled_int);
    cycles=double(Q.clock_cycles(:));
    cycles=cycles(isfinite(cycles)&cycles>0);
    assert(~isempty(cycles),'No valid timing intervals.');
    Fs=median(8e6*1024./cycles);
    assert(isfinite(Fs)&&Fs>0,'Invalid measured sampling rate.');

    wids=sort(unique(double(H.window_idx(:))));
    nw=numel(wids);
    assert(nw>0,'No complete seven-bin observations.');
    assert(isequal(wids(:),(0:nw-1)'), ...
        'Window IDs must be contiguous from zero for alignment.');
    hw_s1=zeros(nw,7,'int64');hw_s2=zeros(nw,7,'int64');
    for wi=1:nw
        rr=H(H.window_idx==wids(wi),:);
        assert(height(rr)==7 && isequal(sort(double(rr.bin_k(:)))',bins), ...
            'Window %d missing/duplicate/unexpected bins.',wids(wi));
        [found,order]=ismember(bins,double(rr.bin_k(:))');
        assert(all(found),'Missing Goertzel bin in window %d.',wids(wi));
        hw_s1(wi,:)=int64(rr.s1(order))';
        hw_s2(wi,:)=int64(rr.s2(order))';
    end
    assert(numel(scaled_int)>=nw*N, ...
        'Not enough CIC samples for decoded Goertzel windows.');
    data=struct('architecture',architecture,'capture_file',char(capture_file), ...
        'session_id',session_id,'N',N,'bins',bins,'Fs',Fs, ...
        'raw',double(S.cic_raw(:)),'scaled_int',scaled_int, ...
        'wids',wids,'hw_s1',hw_s1,'hw_s2',hw_s2);

    fprintf('\nFPGA ACQUISITION (%s; user-declared architecture)\n',upper(architecture));
    fprintf('CIC samples: %d | Fs: %.9f Hz\n',height(S),Fs);
    fprintf('Complete windows: %d | scaled input: %.0f to %.0f\n', ...
        nw,min(scaled),max(scaled));

    if show_plots
        snippet=min(numel(scaled),max(1,round(0.25*Fs)));
        figure('Name','Goertzel input','Color','w');
        plot((0:snippet-1)'/Fs,scaled(1:snippet));
        xlabel('Time (s)');ylabel('Signed 16-bit sample');grid on;
        fft_n=min(numel(scaled),N);
        x=scaled(1:fft_n)-mean(scaled(1:fft_n));
        n=(0:fft_n-1)';
        hann_window=0.5-0.5*cos(2*pi*n/(fft_n-1));
        spectrum=abs(fft(x.*hann_window));
        freq=(0:floor(fft_n/2))'*Fs/fft_n;
        spectrum=spectrum(1:numel(freq));
        inband=freq>=55&freq<=65;
        figure('Name','CIC spectrum near 60 Hz','Color','w');
        plot(freq(inband),20*log10(max(spectrum(inband),realmin)));
        xlabel('Frequency (Hz)');ylabel('Magnitude (dB)');grid on;
    end
end
