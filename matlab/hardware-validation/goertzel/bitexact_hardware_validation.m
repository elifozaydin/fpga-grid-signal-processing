function verified = bitexact_hardware_validation(data, first_window_id, search_max_offset)
%BITEXACT_HARDWARE_VALIDATION Compare all seven FPGA s1/s2 pairs with
% the repository's integer fixed-point reference on the same CIC samples.
% Requires DATA returned by capture_analysis; returns VERIFIED on PASS.
    if nargin<2 || isempty(first_window_id), first_window_id=0; end
    if nargin<3 || isempty(search_max_offset), search_max_offset=32; end
    assert(isstruct(data) && isfield(data,'scaled_int') && ...
        isfield(data,'hw_s1') && isfield(data,'hw_s2'), ...
        'Input must be DATA from capture_analysis.');
    here=fileparts(mfilename('fullpath'));
    model_dir=fullfile(here,'..','..','fixed-point-models');
    model_file=fullfile(model_dir,'goertzel_fixed_model.m');
    assert(isfile(model_file),'Missing repository fixed-point model: %s',model_file);
    addpath(model_dir,'-begin');
    resolved=which('goertzel_fixed_model');
    assert(isfile(resolved) && ...
        strcmp(fileread(resolved), fileread(model_file)), ...
        'MATLAB resolved a different goertzel_fixed_model: %s', resolved);

    N=data.N;wids=data.wids;num_win=numel(wids);
    assert(first_window_id>=0 && first_window_id==floor(first_window_id), ...
        'Invalid first_window_id.');
    assert(search_max_offset>=0 && search_max_offset==floor(search_max_offset), ...
        'Invalid search_max_offset.');
    first_row=find(wids==first_window_id,1);
    assert(~isempty(first_row),'First window %d is not in the capture.',first_window_id);
    offset=NaN;
    for p=0:search_max_offset
        i1=first_window_id*N+p+1;i2=i1+N-1;
        if i2>numel(data.scaled_int),break;end
        [a,b]=goertzel_fixed_model(data.scaled_int(i1:i2));
        if isequal(a,data.hw_s1(first_row,:)) && ...
           isequal(b,data.hw_s2(first_row,:))
            offset=p;break;
        end
    end
    assert(isfinite(offset),'No exact alignment within 0:%d samples.',search_max_offset);

    matched=0;total=0;max_diff=0;
    for wi=1:num_win
        w=wids(wi);i1=offset+w*N+1;i2=i1+N-1;
        assert(i2<=numel(data.scaled_int), ...
            'Insufficient CIC input for window %d.',w);
        [s1,s2]=goertzel_fixed_model(data.scaled_int(i1:i2));
        eq=[s1==data.hw_s1(wi,:),s2==data.hw_s2(wi,:)];
        delta=[double(s1)-double(data.hw_s1(wi,:)), ...
               double(s2)-double(data.hw_s2(wi,:))];
        matched=matched+nnz(eq);total=total+numel(eq);
        max_diff=max(max_diff,max(abs(delta)));
        fprintf('Window %d: %d/14 exact; max difference %.0f\n', ...
            w,nnz(eq),max(abs(delta)));
    end
    fprintf('\nBIT-EXACT FPGA VERIFICATION\n');
    fprintf('Alignment: %d samples | states: %d/%d | max difference: %.0f\n', ...
        offset,matched,total,max_diff);
    assert(total>0 && matched==total,'FAIL: FPGA and MATLAB states differ.');
    fprintf('Result: PASS\n');
    verified=struct('data',data,'offset_samples',offset, ...
        'matched_states',matched,'total_states',total,'passed',true);
end
