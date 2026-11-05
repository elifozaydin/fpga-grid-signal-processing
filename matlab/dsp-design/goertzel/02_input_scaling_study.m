%% ============================================================
%  Goertzel – Input Width and CIC Scaling Selection
%
%  Objective
%  ---------
%  Evaluate the trade-off between input precision and
%  arithmetic width when connecting the CIC decimator
%  to the Goertzel frequency bank.
%
%  Compare input quantization error, spectral error, and
%  recurrence-state magnitude for candidate input widths.
%
%  Design Parameters
%  -----------------
%  CIC stages        : 4
%  Decimation factor : 26
%  Differential delay: 1
%  CIC input         : Signed 13-bit
%  CIC output        : Signed 32-bit
%  Goertzel window   : 32000 samples
%  Frequency bank    : 7 bins near 60 Hz
%  Candidate widths  : 13, 16, 20, 24, 32 bits
%
%  Goertzel arithmetic remains double precision to isolate
%  the effect of CIC output scaling and input quantization.
%  Reported state widths are observed floating-point estimates,
%  not verified fixed-point overflow guarantees. Designs 03/04
%  evaluate Q2.24 arithmetic and final 36-bit recurrence states.
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

% Input formats to evaluate
INPUT_WIDTHS = [13 16 20 24 32];

% Keep outputs next to this script, independent of MATLAB's pwd.
script_dir = fileparts(mfilename('fullpath'));
output_dir = fullfile(script_dir, 'results', 'input_scaling');

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

%% ---- CIC Gain and Input Scaling ----

% DC gain of an N-stage CIC:
%
% G = (R*M)^N
%
% The conservative output-magnitude bound determines the
% arithmetic right shift needed for each input width.

cic_gain = (R*M)^CIC_STAGES;

input_min = -2^(CIC_INPUT_BITS-1);
input_max = 2^(CIC_INPUT_BITS-1)-1;

max_cic_magnitude = max(abs([input_min input_max])) ...
    * cic_gain;

num_widths = length(INPUT_WIDTHS);
right_shifts = zeros(num_widths,1);

for i = 1:num_widths

    W = INPUT_WIDTHS(i);
    shift = 0;

    % Check both signed endpoints after arithmetic right shift.
    % The CIC bound is conservative for either input polarity.
    while floor(max_cic_magnitude/2^shift) > 2^(W-1)-1 || ...
          floor(-max_cic_magnitude/2^shift) < -2^(W-1)

        shift = shift+1;

    end

    right_shifts(i) = shift;

end

fprintf('=== CIC-to-Goertzel Input Scaling ===\n');
fprintf('CIC gain           : %.0f\n', cic_gain);
fprintf('CIC input          : %d bits\n', CIC_INPUT_BITS);
fprintf('CIC output         : %d bits\n', CIC_OUTPUT_BITS);
fprintf('Post-CIC Fs        : %.6f Hz\n', Fs_out);
fprintf('Goertzel window    : %d samples\n', N);
fprintf('Maximum CIC bound  : %.0f\n\n', max_cic_magnitude);

ScalingTable = table( ...
    INPUT_WIDTHS(:), ...
    right_shifts, ...
    'VariableNames', { ...
        'InputBits', ...
        'RightShift' ...
    });

disp(ScalingTable);

%% ---- Goertzel Frequency Bank ----

center_bin = round(TARGET_FREQ*N/Fs_out);
half_width = (NUM_BINS-1)/2;

bins = center_bin + (-half_width:half_width);

omega = 2*pi*bins/N;
coeff = 2*cos(omega);

fprintf('Goertzel bins: %s\n', mat2str(bins));
fprintf('All error metrics below isolate CIC-output quantization.\n');
fprintf('Goertzel recurrence is double precision in this study.\n\n');

%% ---- CIC Impulse Response ----

% Equivalent FIR form of the CIC:
%
% H(z) = (1 + z^-1 + ... + z^-(R*M-1))^N
%
% This produces the same steady-state decimated samples
% as the integrator-comb structure with aligned timing.

h = 1;

for stage = 1:CIC_STAGES

    h = conv(h, ones(1,R*M));

end

%% ---- Test Signal Generation ----

% Generate signals at the pre-CIC sampling frequency.
% The historical 1000 Hz WAV recordings are not used here,
% since they do not represent the pre-CIC ADC samples.

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

% Quantize to the signed 13-bit ADC input range.
for i = 1:num_tests

    x = round(test_signals{i});

    test_signals{i} = min(max( ...
        x,input_min),input_max);

end

%% ---- Input Precision Evaluation ----

num_cases = num_tests*num_widths;

Test = strings(num_cases,1);
InputBits = zeros(num_cases,1);
RightShift = zeros(num_cases,1);

ClipCount = zeros(num_cases,1);

InputSQNR_dB = NaN(num_cases,1);
MaxComplexError_pct = NaN(num_cases,1);
MaxPowerError_pct = NaN(num_cases,1);

MaxStateMagnitude = zeros(num_cases,1);
RequiredStateBits = zeros(num_cases,1);

row = 0;

for ti = 1:num_tests

    fprintf('Processing: %s\n',test_names{ti});

    % Equivalent FIR CIC followed by decimation.
    cic_all = filter(h,1,test_signals{ti});

    cic = cic_all(R:R:end);

    % Full-precision CIC output is the reference.
    X_full = fft(cic);

    X_ref = X_full(bins+1).';
    P_ref = abs(X_ref).^2;

    complex_scale = max(1,max(abs(X_ref)));
    power_scale = max(1,max(P_ref));

    for wi = 1:num_widths

        W = INPUT_WIDTHS(wi);
        S = right_shifts(wi);

        % Arithmetic right shift, including negative inputs.
        scaled = floor(cic/2^S);

        q_min = -2^(W-1);
        q_max = 2^(W-1)-1;

        clip_count = nnz( ...
            scaled < q_min | scaled > q_max);

        % Saturation is used only if a candidate exceeds
        % its representable range.
        scaled = min(max(scaled,q_min),q_max);

        % Restore original scale for spectral comparison.
        reconstructed = scaled*2^S;

        error_signal = reconstructed-cic;

        signal_rms = sqrt(mean(cic.^2));
        error_rms = sqrt(mean(error_signal.^2));

        if error_rms == 0
            sqnr = Inf;
        else
            sqnr = 20*log10(signal_rms/error_rms);
        end

        % Compare the selected spectral coefficients.
        X_quantized = fft(reconstructed);
        X_quantized = X_quantized(bins+1).';

        P_quantized = abs(X_quantized).^2;

        complex_error = 100*max( ...
            abs(X_quantized-X_ref))/complex_scale;

        power_error = 100*max( ...
            abs(P_quantized-P_ref))/power_scale;

        % Measure state magnitude on the scaled integer
        % samples using floating-point Goertzel arithmetic.
        peak_state = max_goertzel_state( ...
            scaled,coeff);

        required_bits = ...
            signed_width_for_peak(peak_state);

        row = row+1;

        Test(row) = string(test_names{ti});

        InputBits(row) = W;
        RightShift(row) = S;

        ClipCount(row) = clip_count;

        InputSQNR_dB(row) = sqnr;
        MaxComplexError_pct(row) = complex_error;
        MaxPowerError_pct(row) = power_error;

        MaxStateMagnitude(row) = peak_state;
        RequiredStateBits(row) = required_bits;

    end

end

%% ---- Per-Test Results ----

DetailedTable = table( ...
    Test, InputBits, RightShift, ClipCount, ...
    InputSQNR_dB, ...
    MaxComplexError_pct, ...
    MaxPowerError_pct, ...
    MaxStateMagnitude, ...
    RequiredStateBits);

fprintf('\n=== Input Precision Results ===\n');
disp(DetailedTable);

%% ---- Input Width Comparison ----

worst_sqnr = zeros(num_widths,1);
worst_complex_error = zeros(num_widths,1);
worst_power_error = zeros(num_widths,1);

max_state = zeros(num_widths,1);
max_required_bits = zeros(num_widths,1);
total_clips = zeros(num_widths,1);

for wi = 1:num_widths

    mask = InputBits == INPUT_WIDTHS(wi);

    worst_sqnr(wi) = min(InputSQNR_dB(mask));

    worst_complex_error(wi) = ...
        max(MaxComplexError_pct(mask));

    worst_power_error(wi) = ...
        max(MaxPowerError_pct(mask));

    max_state(wi) = max(MaxStateMagnitude(mask));

    max_required_bits(wi) = ...
        max(RequiredStateBits(mask));

    total_clips(wi) = sum(ClipCount(mask));

end

SummaryTable = table( ...
    INPUT_WIDTHS(:), ...
    right_shifts, ...
    total_clips, ...
    worst_sqnr, ...
    worst_complex_error, ...
    worst_power_error, ...
    max_required_bits, ...
    max_state, ...
    'VariableNames', { ...
        'InputBits', ...
        'RightShift', ...
        'TotalClips', ...
        'WorstSQNR_dB', ...
        'WorstComplexError_pct', ...
        'WorstPowerError_pct', ...
        'MaxRequiredStateBits', ...
        'MaxStateMagnitude' ...
    });

fprintf('\n=== Input Width Comparison ===\n');
disp(SummaryTable);
fprintf(['State-bit estimates use observed floating-point recurrence ', ...
    'magnitudes, not a fixed-point overflow proof.\n']);
fprintf(['The final 16-bit input / 36-bit Q2.24 state configuration ', ...
    'is evaluated in Designs 03 and 04.\n']);

%% ---- Spectral Error Comparison ----

figure('Name','Goertzel Input Precision', ...
       'Color','w', ...
       'Position',[100 100 900 500]);

semilogy(INPUT_WIDTHS, ...
    max(worst_complex_error,eps),'-o', ...
    'LineWidth',1.5, ...
    'DisplayName','Complex DFT error');

hold on;

semilogy(INPUT_WIDTHS, ...
    max(worst_power_error,eps),'-s', ...
    'LineWidth',1.5, ...
    'DisplayName','Spectral power error');

xlabel('Goertzel input width (bits)');
ylabel('Maximum normalized error (%)');

title('CIC-to-Goertzel Input Quantization');
legend('Location','best');
xticks(INPUT_WIDTHS);
grid on;

%% ---- Input SQNR Comparison ----

figure('Name','CIC Output Quantization', ...
       'Color','w', ...
       'Position',[100 100 900 500]);

plot(INPUT_WIDTHS,worst_sqnr,'-o', ...
    'LineWidth',1.5);

xlabel('Goertzel input width (bits)');
ylabel('Worst-case input SQNR (dB)');

title('CIC-to-Goertzel Input Precision');
xticks(INPUT_WIDTHS);
grid on;

%% ---- Save Results ----

writetable(DetailedTable, ...
    fullfile(output_dir,'input_precision_tests.csv'));

writetable(SummaryTable, ...
    fullfile(output_dir,'input_width_comparison.csv'));

fprintf('\nInput scaling study complete.\n');
fprintf('Results saved to: %s\n',output_dir);

%% ---- Local Functions ----

function peak = max_goertzel_state(x,coeff)

    % Measure the largest recurrence-state magnitude
    % using unquantized coefficients and arithmetic.

    s1 = zeros(size(coeff));
    s2 = zeros(size(coeff));

    peak = 0;

    for n = 1:length(x)

        s0 = x(n)+coeff.*s1-s2;

        peak = max(peak,max(abs(s0)));

        s2 = s1;
        s1 = s0;

    end

end

function bits = signed_width_for_peak(peak)

    % Minimum signed two's-complement width accommodating
    % the observed floating-point state magnitude.

    bits = 1;

    while peak > 2^(bits-1)-1
        bits = bits+1;
    end

end
