%% ============================================================
%  Goertzel – Fixed-Point Precision and State Width
%
%  Objective
%  ---------
%  Evaluate coefficient quantization and recurrence-state
%  width for the FPGA Goertzel frequency bank.
%
%  Compare numerical error, internal state magnitude, and
%  overflow behavior across candidate fixed-point formats.
%
%  Design Parameters
%  -----------------
%  Sampling frequency : 986.193294 Hz (nominal post-CIC)
%  Observation length : 32000 samples
%  Frequency bank     : 7 bins near 60 Hz
%  Input width        : Signed 16-bit
%  Coefficient formats: Q2.18, Q2.20, Q2.24
%  State widths       : 32, 36, 40 bits
%  Rounding           : Arithmetic right shift (floor)
%
%  The fixed-point model matches the recurrence arithmetic
%  used in the Verilog implementation.
%
%% ============================================================

clear; clc; close all;

rng(42);

%% ---- System Configuration ----

Fs = 986.193294;
N = 32000;

TARGET_FREQ = 60;
NUM_BINS = 7;

INPUT_BITS = 16;
FRAC_BITS = [18 20 24];
STATE_WIDTHS = [32 36 40];

% Place generated results next to this script, independent of pwd.
script_dir = fileparts(mfilename('fullpath'));
output_dir = fullfile(script_dir, 'results', 'fixed_point');

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

%% ---- Goertzel Frequency Bank ----

center_bin = round(TARGET_FREQ*N/Fs);
half_width = (NUM_BINS-1)/2;

bins = center_bin + (-half_width:half_width);

omega = 2*pi*bins/N;
coeff_float = 2*cos(omega);

fprintf('=== Goertzel Fixed-Point Precision ===\n');
fprintf('Sampling frequency : %.6f Hz\n', Fs);
fprintf('Observation length : %d samples\n', N);
fprintf('Frequency bins     : %s\n', mat2str(bins));
fprintf('Input width        : %d bits\n', INPUT_BITS);
fprintf('Coefficient formats: %s\n', mat2str(FRAC_BITS));
fprintf('State widths       : %s\n\n', mat2str(STATE_WIDTHS));

%% ---- Test Signal Generation ----

% Inputs represent signed 16-bit samples at the Goertzel
% interface, after CIC scaling.
%
% Coefficient and recurrence arithmetic are the only
% quantization effects investigated in this study.

t = (0:N-1)'/Fs;

INPUT_MIN = -2^(INPUT_BITS-1);
INPUT_MAX = 2^(INPUT_BITS-1)-1;

test_names = {
    'Near-full-scale sinusoid'
    'Low-amplitude sinusoid'
    'Off-bin sinusoid'
    'Two-tone with noise'
    'Random signed input'
};

test_signals = cell(length(test_names),1);

test_signals{1} = ...
    28000*cos(2*pi*60*t+0.3);

test_signals{2} = ...
    1000*cos(2*pi*60.013*t+0.7);

test_signals{3} = ...
    20000*cos(2*pi*59.975*t+0.4);

test_signals{4} = ...
    20000*cos(2*pi*60.011*t+0.2) + ...
    4000*cos(2*pi*120*t+0.8) + ...
    300*randn(N,1);

test_signals{5} = 10000*randn(N,1);

% Quantize every test to the signed 16-bit input range.
for i = 1:length(test_signals)

    x = round(test_signals{i});

    test_signals{i} = int64( ...
        min(max(x,INPUT_MIN),INPUT_MAX));

end

%% ---- Fixed-Point Configuration Sweep ----

num_tests = length(test_names);
num_formats = length(FRAC_BITS);
num_widths = length(STATE_WIDTHS);

num_cases = num_tests*num_formats*num_widths;

Test = strings(num_cases,1);
CoeffFracBits = zeros(num_cases,1);
CoeffTotalBits = zeros(num_cases,1);
StateBits = zeros(num_cases,1);

MaxComplexError_pct = zeros(num_cases,1);
MaxPowerError_pct = zeros(num_cases,1);

OverflowCount = zeros(num_cases,1);
MaxStateMagnitude = zeros(num_cases,1);
StateHeadroomBits = zeros(num_cases,1);

row = 0;

for ti = 1:num_tests

    x = test_signals{ti};

    % Floating-point reference uses the same quantized input.
    [X_ref, P_ref] = goertzel_float( ...
        double(x),coeff_float,omega);

    complex_scale = max(1,max(abs(X_ref)));
    power_scale = max(1,max(P_ref));

    fprintf('Processing: %s\n',test_names{ti});

    for fi = 1:num_formats

        F = FRAC_BITS(fi);

        coeff_int = int64(round( ...
            coeff_float*2^F));

        for wi = 1:num_widths

            W = STATE_WIDTHS(wi);

            [s1,s2,overflow_count,max_state] = ...
                goertzel_fixed(x,coeff_int,F,W);

            % Reconstruct complex DFT coefficients from
            % the final fixed-point recurrence states.
            %
            % The floating-point coefficient is replaced by
            % its quantized representation.

            coeff_q = double(coeff_int)/2^F;
            omega_q = acos(coeff_q/2);

            phase_q = exp(-1j*omega_q);

            X_fixed = conj(phase_q).* ...
                (double(s1)-phase_q.*double(s2));

            P_fixed = abs(X_fixed).^2;

            complex_error = 100*max( ...
                abs(X_fixed-X_ref))/complex_scale;

            power_error = 100*max( ...
                abs(P_fixed-P_ref))/power_scale;

            % Headroom is measured relative to the signed
            % state limit, using the largest observed state.
            state_limit = 2^(W-1)-1;

            if max_state == 0
                headroom = Inf;
            else
                headroom = log2(state_limit/max_state);
            end

            row = row+1;

            Test(row) = string(test_names{ti});
            CoeffFracBits(row) = F;
            CoeffTotalBits(row) = F+2;
            StateBits(row) = W;

            MaxComplexError_pct(row) = complex_error;
            MaxPowerError_pct(row) = power_error;

            OverflowCount(row) = overflow_count;
            MaxStateMagnitude(row) = max_state;
            StateHeadroomBits(row) = headroom;

        end

    end

end

%% ---- Detailed Results ----

DetailedTable = table( ...
    Test, ...
    CoeffFracBits, ...
    CoeffTotalBits, ...
    StateBits, ...
    MaxComplexError_pct, ...
    MaxPowerError_pct, ...
    OverflowCount, ...
    MaxStateMagnitude, ...
    StateHeadroomBits);

fprintf('\n=== Fixed-Point Test Results ===\n');
disp(DetailedTable);

%% ---- Configuration Summary ----

num_configs = num_formats*num_widths;

Format = strings(num_configs,1);
CoeffBits = zeros(num_configs,1);
StateWidth = zeros(num_configs,1);

WorstComplexError_pct = zeros(num_configs,1);
WorstPowerError_pct = zeros(num_configs,1);

TotalOverflows = zeros(num_configs,1);
LargestState = zeros(num_configs,1);
MinHeadroomBits = zeros(num_configs,1);

row = 0;

for fi = 1:num_formats

    for wi = 1:num_widths

        F = FRAC_BITS(fi);
        W = STATE_WIDTHS(wi);

        mask = ...
            CoeffFracBits == F & StateBits == W;

        row = row+1;

        Format(row) = sprintf('Q2.%d',F);
        CoeffBits(row) = F+2;
        StateWidth(row) = W;

        WorstComplexError_pct(row) = ...
            max(MaxComplexError_pct(mask));

        WorstPowerError_pct(row) = ...
            max(MaxPowerError_pct(mask));

        TotalOverflows(row) = ...
            sum(OverflowCount(mask));

        LargestState(row) = ...
            max(MaxStateMagnitude(mask));

        MinHeadroomBits(row) = ...
            min(StateHeadroomBits(mask));

    end

end

SummaryTable = table( ...
    Format, ...
    CoeffBits, ...
    StateWidth, ...
    WorstComplexError_pct, ...
    WorstPowerError_pct, ...
    TotalOverflows, ...
    LargestState, ...
    MinHeadroomBits);

fprintf('\n=== Fixed-Point Configuration Comparison ===\n');
disp(SummaryTable);
fprintf(['Error metrics compare against double-precision recurrence ', ...
    'on the same quantized signed-16 input.\n']);
fprintf(['Overflow counts are observed events for these five test ', ...
    'signals, not a universal arithmetic bound.\n']);

%% ---- Coefficient Precision Comparison ----

% Compare coefficient formats using the selected 36-bit state width.

selected_width = 36;

% Use summary-table rows (one row per coefficient/state configuration).
mask = SummaryTable.StateWidth == selected_width;

figure('Name','Goertzel Coefficient Precision', ...
       'Color','w', ...
       'Position',[100 100 900 500]);

semilogy(SummaryTable.CoeffBits(mask), ...
    max(SummaryTable.WorstComplexError_pct(mask),eps),'-o', ...
    'LineWidth',1.5, ...
    'DisplayName','Complex DFT error');

hold on;

semilogy(SummaryTable.CoeffBits(mask), ...
    max(SummaryTable.WorstPowerError_pct(mask),eps),'-s', ...
    'LineWidth',1.5, ...
    'DisplayName','Spectral power error');

xlabel('Coefficient width (bits)');
ylabel('Worst-case normalized error (%)');

title('Goertzel Coefficient Quantization');
xticks(FRAC_BITS+2);
legend('Location','best');
grid on;

%% ---- State Width Comparison ----

% Compare state widths with the selected Q2.24 format.

selected_frac = 24;

mask = SummaryTable.CoeffBits == selected_frac + 2;

figure('Name','Goertzel State Width', ...
       'Color','w', ...
       'Position',[100 100 900 500]);

subplot(2,1,1);

semilogy(SummaryTable.StateWidth(mask), ...
    max(SummaryTable.WorstComplexError_pct(mask),eps),'-o', ...
    'LineWidth',1.5);

xlabel('State width (bits)');
ylabel('Complex DFT error (%)');

title('State Width vs Numerical Error');
xticks(STATE_WIDTHS);
grid on;

subplot(2,1,2);

bar(SummaryTable.StateWidth(mask), ...
    SummaryTable.TotalOverflows(mask));

xlabel('State width (bits)');
ylabel('State overflow events');

title('Observed State Overflow');
xticks(STATE_WIDTHS);
grid on;

%% ---- Save Results ----

writetable(DetailedTable, ...
    fullfile(output_dir,'fixed_point_tests.csv'));

writetable(SummaryTable, ...
    fullfile(output_dir,'fixed_point_comparison.csv'));

fprintf('\nFixed-point precision study complete.\n');
fprintf('Results saved to: %s\n',output_dir);

%% ---- Local Functions ----

function [X,P] = goertzel_float(x,coeff,omega)

    % Double-precision Goertzel recurrence for the
    % selected integer DFT bins.

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
    % Models signed arithmetic shifts, W-bit state
    % wraparound, and overflow detection.

    num_bins = length(coeff);

    s1 = zeros(1,num_bins,'int64');
    s2 = zeros(1,num_bins,'int64');

    overflow_count = 0;
    max_state = 0;

    state_min = -bitshift(int64(1),W-1);
    state_max = bitshift(int64(1),W-1)-1;
    state_modulus = bitshift(int64(1),W);

    scale = bitshift(int64(1),F);

    % MATLAB int64 arithmetic is safe for the tested
    % state ranges, provided multiplication is checked.

    product_limit = intmax('int64');

    for n = 1:length(x)

        % Prevent MATLAB integer multiplication overflow.
        if any(abs(s1) > ...
               idivide(product_limit, ...
               max(abs(coeff),int64(1)),'floor'))

            error('Intermediate product exceeds int64 range.');

        end

        product = s1.*coeff;

        % Integer floor division matches arithmetic >>> F.
        term = idivide(product,scale,'floor');

        full_state = x(n)+term-s2;

        max_state = max( ...
            max_state,max(abs(double(full_state))));

        overflow = ...
            full_state < state_min | ...
            full_state > state_max;

        overflow_count = overflow_count+nnz(overflow);

        % Signed W-bit two's-complement wraparound.
        wrapped = mod( ...
            full_state-state_min,state_modulus) ...
            +state_min;

        s2 = s1;
        s1 = wrapped;

    end

end
