%% ============================================================
%  CIC Decimator – Frequency Response and Order Comparison
%
%  Objective
%  ---------
%  Compare CIC filter orders based on passband attenuation,
%  single-tone alias rejection, and internal arithmetic width.
%  Evaluate the selected four-stage design across 60–300 Hz.
%
%  Design Parameters
%  -----------------
%  Decimation factor : R = 26
%  Differential delay: M = 1
%  Candidate stages  : N = 2, 3, 4, 5
%  Signal band       : 60–300 Hz
%  Input width       : 13-bit signed
%
%% =============================================================

clear; clc; close all;

%% ---- System Configuration ----

% XADC acquisition configuration
DCLK_HZ                   = 8e6;
ADC_CLOCK_DIVIDER         = 2;
ADC_CLOCKS_PER_CONVERSION = 26;
SEQUENCE_SLOTS            = 6;

% CIC design parameters
R = 26;                    % Decimation factor
M = 1;                     % Differential delay
N_candidates = 2:5;        % Candidate stage counts
N_selected = 4;           % Implemented CIC order

INPUT_BITS = 13;           % Signed input width
Fpass = [60 300];          % Signal band (Hz)

% Nominal input and output sample rates
Fs_in = DCLK_HZ / (ADC_CLOCK_DIVIDER * ...
    ADC_CLOCKS_PER_CONVERSION * SEQUENCE_SLOTS);

Fs_out = Fs_in / R;

fprintf('Nominal input rate : %.6f Hz\n', Fs_in);
fprintf('Nominal output rate: %.6f Hz\n\n', Fs_out);

%% ---- CIC Order Comparison ----

f_band = linspace(Fpass(1), Fpass(2), 1001);

% Columns:
% [N, attenuation at 60/180/300 Hz, worst-case alias rejection,
%  internal width, worst-case desired frequency, alias source frequency]
results = zeros(length(N_candidates), 8);

for idx = 1:length(N_candidates)

    N = N_candidates(idx);

    % DC-normalized CIC frequency response
    gain_db = 20 * log10(cic_mag(f_band, Fs_in, R, N, M));
    attenuation180 = -20 * log10(cic_mag(180, Fs_in, R, N, M));

    % Search single interfering tones that alias into the signal band.
    % Rejection assumes equal desired and interfering amplitudes;
    % it does not represent integrated aliasing noise power.
    worst_rejection = Inf;
    worst_source = NaN;
    worst_desired = NaN;

    for k = 1:ceil(R/2)
        for side = [-1 1]

            source = k * Fs_out + side * f_band;

            % Restrict aliases to the input Nyquist range.
            valid = source > Fs_out/2 & source <= Fs_in/2;

            if ~any(valid)
                continue;
            end

            desired_gain = cic_mag( ...
                f_band(valid), Fs_in, R, N, M);

            alias_gain = cic_mag( ...
                source(valid), Fs_in, R, N, M);

            rejection_db = 20 * log10( ...
                desired_gain ./ max(alias_gain, realmin));

            [min_rejection, min_idx] = min(rejection_db);

            if min_rejection < worst_rejection
                valid_sources = source(valid);
                valid_desired = f_band(valid);

                worst_rejection = min_rejection;
                worst_source = valid_sources(min_idx);
                worst_desired = valid_desired(min_idx);
            end
        end
    end

    % Full-precision CIC word-length requirement
    internal_bits = INPUT_BITS + ceil(N * log2(R*M));

    results(idx,:) = [ ...
        N, -gain_db(1), attenuation180, -gain_db(end), ...
        worst_rejection, internal_bits, ...
        worst_desired, worst_source ...
    ];
end

metrics = array2table(results, 'VariableNames', { ...
    'Stages', ...
    'Attenuation60_dB', ...
    'Attenuation180_dB', ...
    'Attenuation300_dB', ...
    'WorstAliasRejection_dB', ...
    'InternalBits', ...
    'WorstDesired_Hz', ...
    'WorstSource_Hz' ...
});

fprintf('=== CIC Order Comparison ===\n');
disp(metrics);

%% ---- Selected Design Tradeoff ----

selected = metrics(metrics.Stages == N_selected, :);
assert(height(selected) == 1, 'Selected stage count not evaluated.');

fprintf('\n=== Selected CIC: N = %d ===\n', N_selected);
fprintf('Passband attenuation: %.3f dB at 60 Hz, %.3f dB at 180 Hz, %.3f dB at 300 Hz\n', ...
    selected.Attenuation60_dB, selected.Attenuation180_dB, ...
    selected.Attenuation300_dB);
fprintf('Worst-case single-tone alias rejection: %.3f dB\n', ...
    selected.WorstAliasRejection_dB);
fprintf('Required full-precision width: %d bits\n', selected.InternalBits);
fprintf('The four-stage design trades greater alias rejection for more passband droop and arithmetic width.\n');
fprintf('Frequency-dependent gain should be accounted for when comparing downstream harmonic amplitudes.\n');

%% ---- Frequency Response Plot ----

f = linspace(0, Fs_out/2, 2001);

figure('Name', 'CIC Frequency Response', ...
       'Color', 'w', ...
       'Position', [100 100 900 550]);

hold on;

for N = N_candidates
    response_db = 20 * log10(cic_mag(f, Fs_in, R, N, M));

    line_width = 1.5;
    if N == N_selected
        line_width = 2.5;
    end
    plot(f, response_db, 'LineWidth', line_width, ...
        'DisplayName', sprintf('N = %d', N));
end

% Signal-band boundaries
xline(Fpass(1), 'k:', 'HandleVisibility', 'off');
xline(Fpass(2), 'k:', 'HandleVisibility', 'off');

xlabel('Frequency (Hz)');
ylabel('Gain relative to DC (dB)');
title('CIC Frequency Response – Order Comparison');
legend('Location', 'southwest');
grid on;
xlim([0 Fs_out/2]);

%% ---- CIC Magnitude Response ----

function gain = cic_mag(f, Fs, R, N, M)
    % DC-normalized magnitude response of an N-stage CIC filter.
    %
    % |H(f)| = |sin(pi*R*M*f/Fs) /
    %           (R*M*sin(pi*f/Fs))|^N

    gain = ones(size(f));

    nonzero = (f ~= 0);

    gain(nonzero) = abs( ...
        sin(pi*R*M*f(nonzero)/Fs) ./ ...
        (R*M*sin(pi*f(nonzero)/Fs)) ...
    ).^N;
end
