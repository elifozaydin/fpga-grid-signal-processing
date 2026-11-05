%% ============================================================
%  Goertzel – End-to-End Fixed-Point Validation
%
%  Objective
%  ---------
%  Validate the complete CIC-to-Goertzel signal-processing
%  path using arithmetic that matches the FPGA implementation.
%
%  Compare input quantization, recurrence arithmetic, spectral
%  error, and overflow behavior for two configurations.
%
%  Design Parameters
%  -----------------
%  CIC stages         : 4
%  Decimation factor  : 26
%  Differential delay : 1
%  CIC input          : Signed 13-bit
%  CIC output         : Signed 32-bit
%  CIC arithmetic     : Modulo-2^32
%  Goertzel window    : 32000 samples
%  Frequency bank     : 7 bins near 60 Hz
%  Coefficients       : Q2.24, signed 26-bit
%
%  Configuration A
%  ---------------
%  CIC scaling        : >>> 19
%  Goertzel input     : Signed 13-bit
%  Goertzel states    : Signed 32-bit
%
%  Configuration B (selected)
%  --------------------------
%  CIC scaling        : >>> 16
%  Goertzel input     : Signed 16-bit
%  Goertzel states    : Signed 36-bit
%
%  Configuration B calls goertzel_fixed_model.m (selected golden model).
%  Configuration A retains the parameterized recurrence for comparison.
%
%  CIC integrators and combs wrap modulo 2^32.
%  Goertzel arithmetic uses signed multiplication,
%  arithmetic right shifts, and state wraparound.
%
%% ============================================================

clear; clc; close all;

rng(42);

%% ---- System Configuration ----

% CIC configuration
R = 26;
M = 1;
CIC_STAGES = 4;

CIC_INPUT_BITS = 13;
CIC_OUTPUT_BITS = 32;

% Goertzel configuration
Fs_out = 986.193294;
Fs_in = Fs_out*R;

N = 32000;
TARGET_FREQ = 60;
NUM_BINS = 7;

COEFF_FRAC = 24;

% Candidate configurations
INPUT_WIDTHS = [13 16];
RIGHT_SHIFTS = [19 16];
STATE_WIDTHS = [32 36];

config_names = {'A: 13-bit / W32'; 'B: 16-bit / W36'};

% Save generated outputs alongside this script, independent of pwd.
script_dir = fileparts(mfilename('fullpath'));
output_dir = fullfile(script_dir, 'results', 'end_to_end');

if ~exist(output_dir,'dir')
    mkdir(output_dir);
end

num_configs = length(INPUT_WIDTHS);

%% ---- Goertzel Frequency Bank ----

center_bin = round(TARGET_FREQ*N/Fs_out);
half_width = (NUM_BINS-1)/2;

bins = center_bin + (-half_width:half_width);

omega = 2*pi*bins/N;

coeff_float = 2*cos(omega);
coeff_int = int64(round(coeff_float*2^COEFF_FRAC));

fprintf('=== CIC-to-Goertzel Fixed-Point Validation ===\n');
fprintf('CIC decimation     : %d\n',R);
fprintf('CIC stages         : %d\n',CIC_STAGES);
fprintf('Input Fs           : %.6f Hz\n',Fs_in);
fprintf('Output Fs          : %.6f Hz\n',Fs_out);
fprintf('Goertzel window    : %d samples\n',N);
fprintf('Frequency bins     : %s\n',mat2str(bins));
fprintf('Coefficient format : Q2.%d\n\n',COEFF_FRAC);

%% ---- CIC Gain and Output Range ----

% DC gain:
%
% G = (R*M)^N_stages
%
% The full-precision CIC output is bounded by the
% input range multiplied by the CIC gain.

cic_gain = (R*M)^CIC_STAGES;

input_min = -2^(CIC_INPUT_BITS-1);
input_max = 2^(CIC_INPUT_BITS-1)-1;

max_cic_bound = max(abs([input_min input_max]))*cic_gain;

fprintf('CIC DC gain        : %.0f\n',cic_gain);
fprintf('CIC output bound   : %.0f\n\n',max_cic_bound);

%% ---- Test Signal Generation ----

% Generate signed 13-bit input samples at the original
% sampling frequency, before CIC decimation.

N_in = N*R;

t = (0:N_in-1)'/Fs_in;

test_names = {
    'Near-full-scale sinusoid'
    'Low-amplitude sinusoid'
    'Off-bin sinusoid'
    'Two-tone with noise'
};

num_tests = length(test_names);

test_signals = cell(num_tests,1);

test_signals{1} = ...
    4000*cos(2*pi*60*t+0.3);

test_signals{2} = ...
    30*cos(2*pi*60.013*t+0.7);

test_signals{3} = ...
    2800*cos(2*pi*59.975*t+0.4);

test_signals{4} = ...
    2500*cos(2*pi*60.011*t+0.2) + ...
    600*cos(2*pi*120*t+0.8) + ...
    40*randn(N_in,1);

for i = 1:num_tests

    x = round(test_signals{i});

    test_signals{i} = int64( ...
        min(max(x,input_min),input_max));

end

%% ---- End-to-End Configuration Evaluation ----

num_cases = num_tests*num_configs;

Test = strings(num_cases,1);
Configuration = strings(num_cases,1);

InputBits = zeros(num_cases,1);
StateBits = zeros(num_cases,1);
RightShift = zeros(num_cases,1);

InputSQNR_dB = NaN(num_cases,1);

InputComplexError_pct = zeros(num_cases,1);
ArithmeticComplexError_pct = zeros(num_cases,1);
TotalComplexError_pct = zeros(num_cases,1);
TotalPowerError_pct = zeros(num_cases,1);

ClipCount = zeros(num_cases,1);
OverflowCount = zeros(num_cases,1);

MaxStateMagnitude = zeros(num_cases,1);
StateHeadroomBits = zeros(num_cases,1);

CICMaxDifference = zeros(num_tests,1);

row = 0;

for ti = 1:num_tests

    fprintf('Processing: %s\n',test_names{ti});

    %% RTL-Style CIC Decimation

    % Four 32-bit integrators followed by four 32-bit combs.
    %
    % All arithmetic wraps modulo 2^32.
    % The current input is propagated through the integrator
    % next-state calculations before decimation.
    %
    % All generated samples are accepted (input_valid = 1).

    cic = cic_decimator_rtl( ...
        test_signals{ti},R,CIC_OUTPUT_BITS);

    %% CIC Reference Comparison

    % Compare against the mathematically equivalent
    % full-precision FIR implementation.
    %
    % Because the final CIC output fits in 32 signed bits,
    % both models should produce identical samples.

    h = 1;

    for stage = 1:CIC_STAGES
        h = conv(h,ones(1,R*M));
    end

    cic_fir = filter(h,1,double(test_signals{ti}));
    cic_fir = cic_fir(R:R:end);

    CICMaxDifference(ti) = max(abs( ...
        double(cic)-cic_fir));

    fprintf('  CIC/FIR max difference: %.0f LSB\n', ...
        CICMaxDifference(ti));

    if CICMaxDifference(ti) ~= 0
        error('CIC RTL model does not match FIR reference.');
    end

    %% Full-Precision Frequency Reference

    % FFT uses the signed 32-bit CIC output before
    % scaling to the Goertzel input width.

    X_full = fft(double(cic));
    X_ref = X_full(bins+1).';

    P_ref = abs(X_ref).^2;

    complex_scale = max(1,max(abs(X_ref)));
    power_scale = max(1,max(P_ref));

    %% Evaluate Candidate Configurations

    for ci = 1:num_configs

        W_in = INPUT_WIDTHS(ci);
        W_state = STATE_WIDTHS(ci);
        S = RIGHT_SHIFTS(ci);

        %% CIC Output Scaling

        % Signed arithmetic right shift:
        %
        % scaled = cic >>> S
        %
        % Floor division reproduces the behavior of
        % Verilog arithmetic right shifts for negative
        % two's-complement values.

        scaled = idivide( ...
            cic,bitshift(int64(1),S),'floor');

        q_min = -2^(W_in-1);
        q_max = 2^(W_in-1)-1;

        clip_count = nnz( ...
            scaled < q_min | scaled > q_max);

        % The selected scaling should fit the destination
        % width without saturation.
        if clip_count > 0
            error('CIC scaling exceeds Goertzel input range.');
        end

        x_fixed = scaled;

        %% Input Quantization Error

        reconstructed = double(x_fixed)*2^S;

        quantization_error = reconstructed-double(cic);

        signal_rms = sqrt(mean(double(cic).^2));
        error_rms = sqrt(mean(quantization_error.^2));

        if error_rms == 0
            sqnr = Inf;
        else
            sqnr = 20*log10(signal_rms/error_rms);
        end

        % Floating-point Goertzel with quantized input.
        % This isolates the error introduced by CIC scaling.

        [X_input,~] = goertzel_float( ...
            double(x_fixed),coeff_float,omega);

        X_input = X_input*2^S;

        input_error = 100*max( ...
            abs(X_input-X_ref))/complex_scale;

        %% Fixed-Point Goertzel Recurrence

        % Integer recurrence:
        %
        % s0 = x + ((Cint*s1) >>> 24) - s2
        %
        % Recurrence states wrap to their selected
        % two's-complement width.

        if ci == 2
            % Selected hardware configuration: use the standalone
            % bit-exact golden model rather than a duplicate recurrence.
            [s1,s2,model_stats] = goertzel_fixed_model(x_fixed);
            assert(isequal(model_stats.coefficients,coeff_int), ...
                'Golden-model coefficient mismatch.');
            overflow_count = model_stats.overflow_count;
            max_state = model_stats.max_pre_wrap_magnitude;
        else
            % Keep the 13-bit / 32-bit comparison configuration here.
            [s1,s2,overflow_count,max_state] = ...
                goertzel_fixed(x_fixed,coeff_int,COEFF_FRAC,W_state);
        end

        %% Final Spectral Reconstruction

        % Convert the final states to complex DFT values.
        % Use nominal DFT bin frequencies for comparison.

        phase = exp(-1j*omega);

        X_fixed = conj(phase).* ...
            (double(s1)-phase.*double(s2));

        % Restore the original CIC amplitude scale.
        X_fixed = X_fixed*2^S;

        P_fixed = abs(X_fixed).^2;

        %% Numerical Error Comparison

        arithmetic_error = 100*max( ...
            abs(X_fixed-X_input))/complex_scale;

        total_complex_error = 100*max( ...
            abs(X_fixed-X_ref))/complex_scale;

        total_power_error = 100*max( ...
            abs(P_fixed-P_ref))/power_scale;

        %% State Dynamic Range

        state_limit = 2^(W_state-1)-1;

        if max_state == 0
            headroom = Inf;
        else
            headroom = log2(state_limit/max_state);
        end

        %% Store Results

        row = row+1;

        Test(row) = string(test_names{ti});
        Configuration(row) = string(config_names{ci});

        InputBits(row) = W_in;
        StateBits(row) = W_state;
        RightShift(row) = S;

        InputSQNR_dB(row) = sqnr;

        InputComplexError_pct(row) = input_error;
        ArithmeticComplexError_pct(row) = arithmetic_error;

        TotalComplexError_pct(row) = total_complex_error;
        TotalPowerError_pct(row) = total_power_error;

        ClipCount(row) = clip_count;
        OverflowCount(row) = overflow_count;

        MaxStateMagnitude(row) = max_state;
        StateHeadroomBits(row) = headroom;

    end

end

%% ---- Detailed Results ----

DetailedTable = table( ...
    Test, ...
    Configuration, ...
    InputBits, ...
    StateBits, ...
    RightShift, ...
    InputSQNR_dB, ...
    InputComplexError_pct, ...
    ArithmeticComplexError_pct, ...
    TotalComplexError_pct, ...
    TotalPowerError_pct, ...
    ClipCount, ...
    OverflowCount, ...
    MaxStateMagnitude, ...
    StateHeadroomBits);

fprintf('\n=== End-to-End Fixed-Point Results ===\n');
disp(DetailedTable);

%% ---- Configuration Summary ----

WorstInputSQNR_dB = zeros(num_configs,1);
WorstInputError_pct = zeros(num_configs,1);

WorstArithmeticError_pct = zeros(num_configs,1);
WorstTotalComplexError_pct = zeros(num_configs,1);
WorstTotalPowerError_pct = zeros(num_configs,1);

TotalClips = zeros(num_configs,1);
TotalOverflows = zeros(num_configs,1);

LargestState = zeros(num_configs,1);
MinHeadroomBits = zeros(num_configs,1);

for ci = 1:num_configs

    mask = InputBits == INPUT_WIDTHS(ci);

    WorstInputSQNR_dB(ci) = ...
        min(InputSQNR_dB(mask));

    WorstInputError_pct(ci) = ...
        max(InputComplexError_pct(mask));

    WorstArithmeticError_pct(ci) = ...
        max(ArithmeticComplexError_pct(mask));

    WorstTotalComplexError_pct(ci) = ...
        max(TotalComplexError_pct(mask));

    WorstTotalPowerError_pct(ci) = ...
        max(TotalPowerError_pct(mask));

    TotalClips(ci) = sum(ClipCount(mask));
    TotalOverflows(ci) = sum(OverflowCount(mask));

    LargestState(ci) = max(MaxStateMagnitude(mask));

    MinHeadroomBits(ci) = min(StateHeadroomBits(mask));

end

SummaryTable = table( ...
    string(config_names), ...
    INPUT_WIDTHS(:), ...
    STATE_WIDTHS(:), ...
    RIGHT_SHIFTS(:), ...
    WorstInputSQNR_dB, ...
    WorstInputError_pct, ...
    WorstArithmeticError_pct, ...
    WorstTotalComplexError_pct, ...
    WorstTotalPowerError_pct, ...
    TotalClips, ...
    TotalOverflows, ...
    LargestState, ...
    MinHeadroomBits, ...
    'VariableNames',{ ...
        'Configuration', ...
        'InputBits', ...
        'StateBits', ...
        'RightShift', ...
        'WorstInputSQNR_dB', ...
        'WorstInputError_pct', ...
        'WorstArithmeticError_pct', ...
        'WorstTotalComplexError_pct', ...
        'WorstTotalPowerError_pct', ...
        'TotalClips', ...
        'TotalOverflows', ...
        'LargestState', ...
        'MinHeadroomBits' ...
    });

fprintf('\n=== End-to-End Configuration Comparison ===\n');
disp(SummaryTable);

%% ---- Numerical Error Comparison ----

figure('Name','CIC-to-Goertzel Error Comparison', ...
       'Color','w', ...
       'Position',[100 100 950 500]);

errors = [ ...
    WorstInputError_pct, ...
    WorstArithmeticError_pct, ...
    WorstTotalComplexError_pct];

bar(errors);

xticks(1:num_configs);
xticklabels(config_names);

ylabel('Maximum normalized complex DFT error (%)');

title('End-to-End Fixed-Point Error Comparison');

legend( ...
    'Input quantization', ...
    'Coefficient and arithmetic', ...
    'Total error', ...
    'Location','best');

grid on;

%% ---- State Headroom Comparison ----

figure('Name','Goertzel State Headroom', ...
       'Color','w', ...
       'Position',[100 100 900 500]);

bar(MinHeadroomBits);

xticks(1:num_configs);
xticklabels(config_names);

ylabel('Minimum observed headroom (bits)');

title('Goertzel Recurrence-State Headroom');

grid on;

%% ---- Save Results ----

writetable(DetailedTable, ...
    fullfile(output_dir,'end_to_end_tests.csv'));

writetable(SummaryTable, ...
    fullfile(output_dir,'configuration_comparison.csv'));

save(fullfile(output_dir,'end_to_end_validation.mat'), ...
    'SummaryTable','DetailedTable', ...
    'CICMaxDifference', ...
    'Fs_in','Fs_out','N','bins', ...
    'INPUT_WIDTHS','RIGHT_SHIFTS','STATE_WIDTHS');

fprintf('\nEnd-to-end fixed-point validation complete.\n');
fprintf('Results saved to: %s\n',output_dir);

%% ---- Local Functions ----

function y = cic_decimator_rtl(x,R,W)

    % RTL-equivalent CIC decimator.
    %
    % Four integrator stages update on every accepted sample.
    % Four comb stages update every R accepted samples.
    %
    % The current input propagates through all integrator
    % next-state calculations before the comb chain.
    %
    % Every addition and subtraction wraps modulo 2^W.
    %
    % The model starts from reset with zeroed registers
    % and sample_count = 0.

    num_samples = length(x);
    num_outputs = floor(num_samples/R);

    y = zeros(num_outputs,1,'int64');

    integrator = zeros(1,4);
    comb_delay = zeros(1,4);

    sample_count = 0;
    output_idx = 0;

    for n = 1:num_samples

        % Next-state integrator chain.
        i1 = wrap_signed( ...
            integrator(1)+double(x(n)),W);

        i2 = wrap_signed( ...
            integrator(2)+i1,W);

        i3 = wrap_signed( ...
            integrator(3)+i2,W);

        i4 = wrap_signed( ...
            integrator(4)+i3,W);

        integrator = [i1 i2 i3 i4];

        % Decimation after R accepted samples.
        if sample_count == R-1

            sample_count = 0;

            % Next-state comb chain.
            c1 = wrap_signed( ...
                i4-comb_delay(1),W);

            c2 = wrap_signed( ...
                c1-comb_delay(2),W);

            c3 = wrap_signed( ...
                c2-comb_delay(3),W);

            c4 = wrap_signed( ...
                c3-comb_delay(4),W);

            % Nonblocking register updates in the RTL
            % use the previous comb delay values.
            comb_delay = [i4 c1 c2 c3];

            output_idx = output_idx+1;
            y(output_idx) = int64(c4);

        else

            sample_count = sample_count+1;

        end

    end

end

function value = wrap_signed(x,W)

    % W-bit signed two's-complement wraparound.
    %
    % Uses double precision because intermediate CIC sums
    % are small enough to remain exact integer values.

    modulus = 2^W;
    half_range = 2^(W-1);

    value = mod(x+half_range,modulus)-half_range;

end

function [X,P] = goertzel_float(x,coeff,omega)

    % Double-precision Goertzel recurrence.

    s1 = zeros(size(coeff));
    s2 = zeros(size(coeff));

    for n = 1:length(x)

        s0 = x(n)+coeff.*s1-s2;

        s2 = s1;
        s1 = s0;

    end

    phase = exp(-1j*omega);

    X = conj(phase).*(s1-phase.*s2);
    P = abs(X).^2;

end

function [s1,s2,overflow_count,max_state] = ...
    goertzel_fixed(x,coeff,F,W)

    % Integer Goertzel recurrence:
    %
    % s0 = x + ((Cint*s1) >>> F) - s2
    %
    % Models signed arithmetic shifts, state overflow,
    % and W-bit two's-complement wraparound.

    num_bins = length(coeff);

    s1 = zeros(1,num_bins,'int64');
    s2 = zeros(1,num_bins,'int64');

    overflow_count = 0;
    max_state = 0;

    state_min = -bitshift(int64(1),W-1);
    state_max = bitshift(int64(1),W-1)-1;

    state_modulus = bitshift(int64(1),W);
    scale = bitshift(int64(1),F);

    for n = 1:length(x)

        % Verify that int64 multiplication remains exact before
        % evaluating the signed fixed-point recurrence.
        product_limit = intmax('int64');
        if any(abs(s1) > idivide(product_limit, ...
                max(abs(coeff),int64(1)), 'floor'))
            error('Intermediate product exceeds int64 range.');
        end
        product = s1.*coeff;

        % Arithmetic right shift with floor rounding.
        term = idivide(product,scale,'floor');

        full_state = x(n)+term-s2;

        max_state = max( ...
            max_state,max(abs(double(full_state))));

        overflow = full_state < state_min | ...
                   full_state > state_max;

        overflow_count = overflow_count+nnz(overflow);

        % Signed state wraparound.
        wrapped = mod( ...
            full_state-state_min,state_modulus) ...
            +state_min;

        s2 = s1;
        s1 = wrapped;

    end

end
