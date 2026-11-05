%% ============================================================
%  CIC Decimator – Fixed-Point Arithmetic Analysis
%
%  Objective
%  ---------
%  Verify the arithmetic behavior of a fixed-point CIC
%  decimator against an independent FIR reference model.
%
%  Configuration
%  -------------
%  Decimation factor : R = 26
%  Differential delay: M = 1
%  Number of stages  : N = 4
%  Input width       : 13-bit signed
%  Internal width    : 32-bit signed
%  Arithmetic        : Modulo-2^32 wraparound
%
%  Test Cases
%  ----------
%  TC1 – Zero input
%  TC2 – Impulse response
%  TC3 – Positive full-scale DC
%  TC4 – Negative full-scale DC
%  TC5 – Alternating input extremes
%  TC6 – Random signed inputs
%  TC7 – Input-valid gaps
%  TC8 – Input-valid gaps with fewer than R accepted samples
%
%  Verification
%  ------------
%  Exact output comparison against an independent FIR model,
%  output-valid timing checks, and integrator overflow coverage.
%
%% =============================================================

clear; clc; close all;

% Uses standalone cic_fixed_model.m in the same directory.

%% ---- Filter Configuration ----

R = 26;                   % Decimation factor
M = 1;                    % Differential delay
N = 4;                    % Number of CIC stages

INPUT_BITS = 13;
INTERNAL_BITS = 32;   % RTL integrator/comb state width

INPUT_MIN = -2^(INPUT_BITS-1);
INPUT_MAX =  2^(INPUT_BITS-1)-1;

NUM_SAMPLES = 8192;

assert(M == 1 && INTERNAL_BITS == INPUT_BITS + ceil(N*log2(R*M)), ...
    'This model targets the 32-bit, M=1 CIC implementation.');

%% ---- Independent FIR Reference ----

% Unnormalized CIC transfer function:
% H(z) = (1 + z^-1 + ... + z^-(R-1))^N
%
% Repeated convolution constructs the FIR equivalent
% independently of the CIC integrator/comb architecture.

h = 1;

for k = 1:N
    h = conv(h, ones(1, R));
end

%% ---- Test Signal Generation ----

rng(3403, 'twister');

test_inputs = { ...
    zeros(NUM_SAMPLES, 1), ...
    [INPUT_MAX; zeros(NUM_SAMPLES-1, 1)], ...
    INPUT_MAX * ones(NUM_SAMPLES, 1), ...
    INPUT_MIN * ones(NUM_SAMPLES, 1), ...
    repmat([INPUT_MAX; INPUT_MIN], NUM_SAMPLES/2, 1), ...
    randi([INPUT_MIN INPUT_MAX], NUM_SAMPLES, 1) ...
};

test_valid = cell(size(test_inputs));
for k = 1:numel(test_inputs)
    test_valid{k} = true(NUM_SAMPLES, 1);
end

% A cycle-level test with irregular input-valid gaps.
gap_inputs = randi([INPUT_MIN INPUT_MAX], NUM_SAMPLES, 1);
gap_valid = mod((1:NUM_SAMPLES)', 7) ~= 0 & ...
            mod((1:NUM_SAMPLES)', 11) ~= 0;
test_inputs{end+1} = gap_inputs;
test_valid{end+1} = gap_valid;

% No output should be generated until R accepted samples.
test_inputs{end+1} = randi([INPUT_MIN INPUT_MAX], 3*R, 1);
test_valid{end+1} = [true(R-1, 1); false(2*R+1, 1)];

test_names = { ...
    'Zero input', ...
    'Impulse', ...
    'Positive DC', ...
    'Negative DC', ...
    'Alternating extremes', ...
    'Random signed input', ...
    'Input-valid gaps', ...
    'Fewer than R accepted samples' ...
};

%% ---- Fixed-Point Arithmetic Verification ----

max_errors = zeros(numel(test_inputs), 1);
wrap_counts = zeros(numel(test_inputs), 1);
outputs_checked = zeros(numel(test_inputs), 1);

for k = 1:numel(test_inputs)

    x = test_inputs{k};
    input_valid = test_valid{k};

    % The FIR reference advances only on accepted input samples.
    accepted = x(input_valid);
    reference = filter(h, 1, accepted);
    reference = reference(R:R:end);

    % Expected output-valid cycles are every Rth accepted sample.
    accepted_count = cumsum(double(input_valid));
    expected_valid = input_valid & mod(accepted_count, R) == 0;

    [y, valid, wrap_counts(k)] = cic_fixed_model(x, input_valid);

    assert(isequal(valid, expected_valid), ...
        'Output-valid timing mismatch: %s', test_names{k});

    actual = y(valid);
    assert(numel(actual) == numel(reference), ...
        'Output count mismatch: %s', test_names{k});

    outputs_checked(k) = numel(actual);
    if ~isempty(actual)
        max_errors(k) = max(abs(actual - reference));
    end

    assert(isequal(actual, reference), ...
        'CIC/FIR arithmetic mismatch: %s', test_names{k});
end

% Full-scale DC must exercise modular integrator arithmetic.
assert(wrap_counts(3) > 0 && wrap_counts(4) > 0, ...
    'Expected positive and negative DC tests to exercise overflow.');

%% ---- Verification Results ----

metrics = table( ...
    string(test_names(:)), outputs_checked, max_errors, wrap_counts, ...
    'VariableNames', {'TestCase', 'OutputsChecked', ...
                      'MaxError_counts', 'IntegratorWraps'} ...
);

fprintf('=== Fixed-Point Arithmetic Verification ===\n');
disp(metrics);
fprintf('PASS: FIR outputs, output-valid timing, and wraparound coverage verified.\n');

