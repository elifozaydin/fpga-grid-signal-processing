function [T, stats] = parser(inputData)
% Decode six-byte FPGA transport frames and track framing/sequence integrity.
% Frame: [20-bit sequence, 12-bit payload] [00] [A3].
% Session header: 55 AA 55 AA D4 06.

%% ---- Load Binary Data ----

if ischar(inputData) || isstring(inputData)
    fid = fopen(char(inputData), 'rb');
    assert(fid >= 0, 'Could not open file: %s', char(inputData));
    bytes = fread(fid, inf, '*uint8');
    fclose(fid);
else
    bytes = uint8(inputData(:));
end

%% ---- Packet Definitions ----

header = uint8([hex2dec('55'), hex2dec('AA'), ...
                hex2dec('55'), hex2dec('AA'), ...
                hex2dec('D4'), hex2dec('06')]);
frame_bytes = 6;
marker = uint8(hex2dec('A3'));
sample_type = uint8(hex2dec('00'));
sequence_modulus = 2^20;
L = numel(bytes);

names = {'packet_pos','session_id','sample_idx', ...
         'sequence','payload','sequence_delta'};
rows = zeros(floor(L/frame_bytes), numel(names));

n_samples = 0;
session_id = 0;
sample_idx = 0;
previous_sequence = NaN;
missing_samples = 0;
duplicate_frames = 0;
sequence_discontinuities = 0;
skipped_bytes = 0;
leading_bytes = 0;
i = 1;

%% ---- Decode FPGA Frames ----

while i + frame_bytes - 1 <= L

    if isequal(bytes(i:i+5).', header)
        session_id = session_id + 1;
        sample_idx = 0;
        previous_sequence = NaN;
        i = i + frame_bytes;
        continue;
    end

    if session_id == 0
        leading_bytes = leading_bytes + 1;
        i = i + 1;
        continue;
    end

    if bytes(i+4) ~= sample_type || bytes(i+5) ~= marker
        skipped_bytes = skipped_bytes + 1;
        i = i + 1;
        continue;
    end

    word = bytes_to_u32_be(bytes(i:i+3));
    sequence = floor(word / 4096);
    payload = mod(word, 4096);
    delta = NaN;

    if ~isnan(previous_sequence)
        delta = mod(sequence - previous_sequence, sequence_modulus);
        if delta == 0
            duplicate_frames = duplicate_frames + 1;
        elseif delta <= sequence_modulus/2
            missing_samples = missing_samples + delta - 1;
        else
            sequence_discontinuities = sequence_discontinuities + 1;
        end
    end

    n_samples = n_samples + 1;
    rows(n_samples,:) = [i, session_id, sample_idx, ...
                         sequence, payload, delta];

    previous_sequence = sequence;
    sample_idx = sample_idx + 1;
    i = i + frame_bytes;
end

%% ---- Return Decoded Data ----

T = array2table(rows(1:n_samples,:), 'VariableNames', names);

stats = struct( ...
    'sessions', session_id, ...
    'samples', n_samples, ...
    'total_bytes', L, ...
    'leading_bytes', leading_bytes, ...
    'skipped_bytes', skipped_bytes, ...
    'trailing_bytes', max(0, L-i+1), ...
    'missing_samples_between_frames', missing_samples, ...
    'duplicate_frames', duplicate_frames, ...
    'ambiguous_or_backward_jumps', sequence_discontinuities);

%% ---- Parsing Summary ----

fprintf('\n============================================\n');
fprintf('FPGA TRANSPORT INTEGRITY\n');
fprintf('============================================\n');
fprintf('Acquisition sessions          : %d\n', stats.sessions);
fprintf('Received sample frames        : %d\n', stats.samples);
fprintf('Missing samples (internal)    : %d\n', ...
    stats.missing_samples_between_frames);
fprintf('Duplicate sequence values     : %d\n', stats.duplicate_frames);
fprintf('Ambiguous/backward jumps      : %d\n', ...
    stats.ambiguous_or_backward_jumps);
fprintf('Skipped / desynchronized bytes: %d\n', stats.skipped_bytes);
fprintf('Leading bytes                 : %d\n', stats.leading_bytes);
fprintf('Trailing bytes                : %d\n', stats.trailing_bytes);

if session_id == 0
    warning('No FPGA acquisition header found.');
end
if skipped_bytes > 0 || sequence_discontinuities > 0
    warning('Framing or sequence discontinuities detected.');
end
end

%% ---- Unsigned 32-Bit Big-Endian Conversion ----

function value = bytes_to_u32_be(b)
    b = uint32(b(:));
    u = bitor(bitshift(b(1),24), bitshift(b(2),16));
    u = bitor(u, bitshift(b(3),8));
    u = bitor(u, b(4));
    value = double(u);
end
