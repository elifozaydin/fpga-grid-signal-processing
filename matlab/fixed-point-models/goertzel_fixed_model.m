function [s1, s2, stats] = goertzel_fixed_model(x)
%GOERTZEL_FIXED_MODEL Bit-exact seven-bin fixed-point recurrence reference.
%   [S1,S2,STATS] = GOERTZEL_FIXED_MODEL(X) processes one window of
%   accepted signed 16-bit samples, in order, from zero recurrence history.
%   S1 and S2 are 1-by-7 int64 arrays ordered by DFT bins 1944:1950.
%
%   The arithmetic matches goertzel_bin.v and goertzel_bank_shared.v:
%     s0 = x + ((coeff * s1) >>> 24) - s2;
%     s2 = s1; s1 = s0[35:0];
%
%   Multiplication uses the full signed 36x26-bit product. Arithmetic
%   right shift rounds toward minus infinity; states wrap modulo 2^36.
%   This function models accepted-sample behavior, NOT ready/valid
%   scheduling, clock latency, or the CIC preceding the bank.
%   Call separately for each nonoverlapping window (normally 32000 samples).
%
%   STATS contains overflow_count, max_pre_wrap_magnitude, bins, and
%   coefficients. An observed zero overflow count is not a proof that
%   arbitrary sample sequences cannot overflow.

    bins = 1944:1950;
    coeff = int64([31139567 31137112 31134656 31132199 ...
                   31129741 31127281 31124821]);
    frac = 24;
    width = 36;
    max_samples = 32000;

    if ~(isnumeric(x) && isreal(x) && isvector(x) && ~isempty(x))
        error('Input must be a nonempty real numeric vector.');
    end
    if numel(x) > max_samples
        error('One invocation accepts at most 32000 samples (one window).');
    end
    if any(~isfinite(double(x(:)))) || ...
            any(double(x(:)) ~= fix(double(x(:)))) || ...
            any(double(x(:)) < -32768 | double(x(:)) > 32767)
        error('All samples must be signed 16-bit integers.');
    end
    x = int64(x(:));

    s1 = zeros(1,7,'int64');
    s2 = zeros(1,7,'int64');
    state_min = -bitshift(int64(1),width-1);
    state_max = bitshift(int64(1),width-1)-1;
    state_mod = bitshift(int64(1),width);
    scale = bitshift(int64(1),frac);

    overflow_count = 0;
    max_pre_wrap_magnitude = 0;

    for n = 1:numel(x)
        % Signed 36x26 multiplication fits in int64 at this fixed width.
        product = s1 .* coeff;
        term = idivide(product,scale,'floor');
        full_state = x(n) + term - s2;

        overflow_count = overflow_count + nnz( ...
            full_state < state_min | full_state > state_max);
        max_pre_wrap_magnitude = max(max_pre_wrap_magnitude, ...
            max(abs(double(full_state))));

        next_s1 = mod(full_state-state_min,state_mod)+state_min;
        s2 = s1;
        s1 = next_s1;
    end

    stats = struct('bins',bins, 'coefficients',coeff, ...
        'coefficient_frac_bits',frac, 'state_width',width, ...
        'accepted_samples',numel(x), 'overflow_count',overflow_count, ...
        'max_pre_wrap_magnitude',max_pre_wrap_magnitude);
end
