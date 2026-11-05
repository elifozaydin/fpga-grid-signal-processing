function [T, timing, goertzel] = parser(inputData)
%% ============================================================
% CIC + Goertzel FPGA Data Parser
%
% Outputs:
%   T        - Raw signed 32-bit CIC samples
%   timing   - FPGA clock-cycle measurements
%   goertzel - Reconstructed signed 36-bit Goertzel states
%
% Packet Format (6 bytes, big-endian):
%
% Session header: 55 AA 55 AA D4 06
%
% CIC sample    : [32-bit signed]   [00]       [A3]
% Timing        : [32-bit unsigned] [80]       [A3]
% Goertzel s1 LO: [lower 32 bits]   [B0..B6]  [A3]
% Goertzel s2 LO: [lower 32 bits]   [C0..C6]  [A3]
% Goertzel s1 HI: [upper 4 bits]    [D0..D6]  [A3]
% Goertzel s2 HI: [upper 4 bits]    [E0..E6]  [A3]
%
% Seven Goertzel bins:
%   k = 1944:1950
%
% N = 32000 samples per observation.
%
% Each completed observation contains:
%   7 s1 low frames
%   7 s1 high frames
%   7 s2 low frames
%   7 s2 high frames
%
% Total: 28 Goertzel frames.
%
% Incomplete observations are excluded with a warning.
% Window indices start at zero within each session.
%
% Existing calls with two outputs remain supported.
%% ============================================================

%% ---- Load Binary Data ----

if ischar(inputData) || isstring(inputData)

    fid = fopen(char(inputData), 'rb');

    assert(fid >= 0, ...
        'Could not open file: %s', char(inputData));

    bytes = fread(fid, inf, '*uint8');
    fclose(fid);

else
    bytes = uint8(inputData(:));
end

%% ---- Packet Definitions ----

header = uint8([ ...
    hex2dec('55'), hex2dec('AA'), ...
    hex2dec('55'), hex2dec('AA'), ...
    hex2dec('D4'), hex2dec('06')]);

marker = uint8(hex2dec('A3'));

frame_bytes = 6;

sample_type = uint8(hex2dec('00'));
timing_type = uint8(hex2dec('80'));

s1_low_base  = uint8(hex2dec('B0'));
s2_low_base  = uint8(hex2dec('C0'));
s1_high_base = uint8(hex2dec('D0'));
s2_high_base = uint8(hex2dec('E0'));

goertzel_bins = 1944:1950;
num_bins = numel(goertzel_bins);

%% ---- Output Definitions ----

sample_names = { ...
    'packet_pos', ...
    'session_id', ...
    'sample_idx', ...
    'cic_raw'};

timing_names = { ...
    'packet_pos', ...
    'session_id', ...
    'measurement_idx', ...
    'clock_cycles'};

goertzel_names = { ...
    'packet_pos', ...
    'session_id', ...
    'window_idx', ...
    'bin_idx', ...
    'bin_k', ...
    's1', ...
    's2'};

L = numel(bytes);

max_frames = floor(L/frame_bytes);

sample_rows = zeros(max_frames,4);
timing_rows = zeros(max_frames,4);
goertzel_rows = zeros(max_frames,7);

n_samples = 0;
n_timing = 0;
n_goertzel = 0;

session_id = 0;
sample_idx = 0;
measurement_idx = 0;

skipped = 0;
incomplete_windows = 0;
orphan_frames = 0;

i = 1;

%% ---- Goertzel Assembly State ----
%
% Parts:
%   Row 1: s1 low
%   Row 2: s1 high
%   Row 3: s2 low
%   Row 4: s2 high
%
% Columns correspond to bins 0..6.

g_parts = zeros(4,num_bins,'uint32');
g_seen = false(4,num_bins);

g_active = false;
g_start_pos = 0;

g_window_idx = 0;
next_window_idx = 0;

%% ---- Decode FPGA Frames ----

while i + frame_bytes - 1 <= L

    % --------------------------------------------------------
    % Session header
    % --------------------------------------------------------

    if isequal(bytes(i:i+5).', header)

        if g_active && ~all(g_seen(:))
            incomplete_windows = incomplete_windows + 1;
        end

        session_id = session_id + 1;

        sample_idx = 0;
        measurement_idx = 0;

        next_window_idx = 0;
        g_active = false;

        g_parts(:) = 0;
        g_seen(:) = false;

        i = i + frame_bytes;
        continue;
    end

    % Ignore bytes before the first session.
    if session_id == 0
        i = i + 1;
        continue;
    end

    % --------------------------------------------------------
    % Check frame marker
    % --------------------------------------------------------

    if bytes(i+5) ~= marker
        skipped = skipped + 1;
        i = i + 1;
        continue;
    end

    frame_type = bytes(i+4);

    payload = bytes_to_u32_be(bytes(i:i+3));

    % --------------------------------------------------------
    % CIC sample
    % --------------------------------------------------------

    if frame_type == sample_type

        raw = payload;

        if raw >= 2^31
            raw = raw - 2^32;
        end

        n_samples = n_samples + 1;

        sample_rows(n_samples,:) = [ ...
            i, session_id, sample_idx, raw];

        sample_idx = sample_idx + 1;

        i = i + frame_bytes;
        continue;
    end

    % --------------------------------------------------------
    % Timing measurement
    % --------------------------------------------------------

    if frame_type == timing_type

        n_timing = n_timing + 1;

        timing_rows(n_timing,:) = [ ...
            i, session_id, measurement_idx, payload];

        measurement_idx = measurement_idx + 1;

        i = i + frame_bytes;
        continue;
    end

    % --------------------------------------------------------
    % Identify Goertzel frame
    % --------------------------------------------------------

    is_goertzel = true;

    if frame_type >= s1_low_base && ...
       frame_type < s1_low_base + num_bins

        part = 1;
        bin_idx = double(frame_type - s1_low_base);

    elseif frame_type >= s2_low_base && ...
           frame_type < s2_low_base + num_bins

        part = 3;
        bin_idx = double(frame_type - s2_low_base);

    elseif frame_type >= s1_high_base && ...
           frame_type < s1_high_base + num_bins

        part = 2;
        bin_idx = double(frame_type - s1_high_base);

    elseif frame_type >= s2_high_base && ...
           frame_type < s2_high_base + num_bins

        part = 4;
        bin_idx = double(frame_type - s2_high_base);

    else

        is_goertzel = false;

    end

    if ~is_goertzel

        skipped = skipped + 1;
        i = i + 1;
        continue;

    end

    % High fragments must contain only four data bits.
    if (part == 2 || part == 4) && payload > 15

        skipped = skipped + 1;
        i = i + frame_bytes;
        continue;

    end

    % --------------------------------------------------------
    % Start Goertzel observation
    %
    % B0 identifies the first frame of an observation.
    % --------------------------------------------------------

    if frame_type == s1_low_base

        if g_active && ~all(g_seen(:))
            incomplete_windows = incomplete_windows + 1;
        end

        g_active = true;

        g_window_idx = next_window_idx;
        next_window_idx = next_window_idx + 1;

        g_start_pos = i;

        g_parts(:) = 0;
        g_seen(:) = false;

    end

    % Ignore fragments without an active B0-started window.
    if ~g_active

        orphan_frames = orphan_frames + 1;

        i = i + frame_bytes;
        continue;

    end

    % --------------------------------------------------------
    % Store state fragment
    % --------------------------------------------------------

    col = bin_idx + 1;

    g_parts(part,col) = uint32(payload);
    g_seen(part,col) = true;

    % --------------------------------------------------------
    % Complete observation
    % --------------------------------------------------------

    if all(g_seen(:))

        for bi = 1:num_bins

            s1_low = double(g_parts(1,bi));
            s1_high = double(g_parts(2,bi));

            s2_low = double(g_parts(3,bi));
            s2_high = double(g_parts(4,bi));

            % Reassemble unsigned 36-bit values.
            s1_unsigned = s1_high*2^32 + s1_low;
            s2_unsigned = s2_high*2^32 + s2_low;

            % Convert to signed 36-bit two's complement.
            if s1_unsigned >= 2^35
                s1_signed = s1_unsigned - 2^36;
            else
                s1_signed = s1_unsigned;
            end

            if s2_unsigned >= 2^35
                s2_signed = s2_unsigned - 2^36;
            else
                s2_signed = s2_unsigned;
            end

            n_goertzel = n_goertzel + 1;

            goertzel_rows(n_goertzel,:) = [ ...
                g_start_pos, ...
                session_id, ...
                g_window_idx, ...
                bi-1, ...
                goertzel_bins(bi), ...
                s1_signed, ...
                s2_signed];

        end

        g_active = false;
        g_parts(:) = 0;
        g_seen(:) = false;

    end

    i = i + frame_bytes;

end

%% ---- Check Incomplete Final Observation ----

if g_active && ~all(g_seen(:))
    incomplete_windows = incomplete_windows + 1;
end

%% ---- Return Decoded Tables ----

T = array2table( ...
    sample_rows(1:n_samples,:), ...
    'VariableNames',sample_names);

timing = array2table( ...
    timing_rows(1:n_timing,:), ...
    'VariableNames',timing_names);

goertzel = array2table( ...
    goertzel_rows(1:n_goertzel,:), ...
    'VariableNames',goertzel_names);

%% ---- Parsing Summary ----

fprintf('\n');
fprintf('============================================\n');
fprintf('FPGA DATA PARSER\n');
fprintf('============================================\n');

fprintf('Sessions             : %d\n',session_id);
fprintf('CIC samples          : %d\n',n_samples);
fprintf('Timing measurements  : %d\n',n_timing);
fprintf('Goertzel observations: %d\n',n_goertzel/num_bins);
fprintf('Goertzel state pairs : %d\n',n_goertzel);

fprintf('Incomplete Goertzel windows: %d\n', ...
    incomplete_windows);

if skipped > 0
    warning('Skipped %d unrecognized or malformed bytes.', ...
        skipped);
end

if orphan_frames > 0
    warning('Ignored %d Goertzel fragments without a window start.', ...
        orphan_frames);
end

if incomplete_windows > 0
    warning('%d incomplete Goertzel observations excluded.', ...
        incomplete_windows);
end

if session_id == 0
    warning('No FPGA session header found.');
end

end

%% ---- Unsigned 32-bit Big-Endian Conversion ----

function value = bytes_to_u32_be(b)

    b = uint32(b(:));

    u = bitor(bitshift(b(1),24), ...
              bitshift(b(2),16));

    u = bitor(u,bitshift(b(3),8));
    u = bitor(u,b(4));

    value = double(u);

end
