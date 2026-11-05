function [y, valid, wrap_count] = cic_fixed_model(x, input_valid)
%CIC_FIXED_MODEL Standalone bit-exact 4-stage CIC decimator model.
%   [Y, VALID, WRAP_COUNT] = CIC_FIXED_MODEL(X, INPUT_VALID)
%   processes one stream of signed 13-bit input samples on clock cycles
%   marked by INPUT_VALID. The implementation matches the default
%   configuration in rtl/preprocessing/cic_decimator.v:
%
%       R = 26; differential delay M = 1; stages N = 4;
%       signed input = 13 bits; integrators/combs = signed 32 bits.
%
%   The first output is valid on the 26th accepted sample. Invalid
%   cycles do not advance any state. All additions and subtractions
%   wrap modulo 2^32, including intermediate integrator values.
%   Y is zero on non-output cycles; VALID marks meaningful entries.
%   Each invocation starts at reset state (all zeros).
%   WRAP_COUNT counts integrator additions exceeding signed 32-bit
%   range before wrapping; comb wrap events are not counted.
%
%   This is a numeric accepted-sample reference, not an RTL
%   cycle/reset simulator; no independent reset input is modeled.

    R = 26;
    N = 4;
    B = 32;

    if ~(isnumeric(x) && isreal(x) && isvector(x))
        error('x must be a real numeric vector.');
    end
    if ~(islogical(input_valid) || isnumeric(input_valid)) || ...
            ~isvector(input_valid) || numel(input_valid) ~= numel(x)
        error('input_valid must be a vector matching x.');
    end
    if any(~isfinite(double(x(:)))) || ...
            any(double(x(:)) ~= fix(double(x(:)))) || ...
            any(double(x(:)) < -4096 | double(x(:)) > 4095)
        error('x must contain signed 13-bit integers.');
    end
    if any(~isfinite(double(input_valid(:)))) || ...
            any(double(input_valid(:)) ~= 0 & double(input_valid(:)) ~= 1)
        error('input_valid must contain only logical values 0 or 1.');
    end

    x = double(x(:));
    input_valid = logical(input_valid(:));
    num_samples = numel(x);
    integrators = zeros(N,1);
    delays = zeros(N,1);
    count = 0;
    wrap_count = 0;

    y = zeros(num_samples,1);
    valid = false(num_samples,1);

    for k = 1:num_samples
        if ~input_valid(k)
            continue;
        end

        z = x(k);
        for stage = 1:N
            unwrapped = integrators(stage) + z;
            if unwrapped < -2^(B-1) || unwrapped > 2^(B-1)-1
                wrap_count = wrap_count + 1;
            end
            z = mod(unwrapped + 2^(B-1),2^B) - 2^(B-1);
            integrators(stage) = z;
        end

        count = count + 1;
        if count == R
            count = 0;
            for stage = 1:N
                previous = delays(stage);
                delays(stage) = z;
                z = mod(z - previous + 2^(B-1),2^B) - 2^(B-1);
            end
            y(k) = z;
            valid(k) = true;
        end
    end
end
