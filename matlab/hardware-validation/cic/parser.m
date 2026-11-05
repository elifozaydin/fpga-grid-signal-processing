function [T, timing] = parser(inputData)
%% ============================================================
%  CIC Decimator – FPGA Data Parser
%
%  Overview
%  --------
%  Decode CIC samples and FPGA timing measurements recorded
%  by the ESP32 over SPI. Sampling-rate calculations are
%  handled separately by the hardware-validation scripts.
%
%  Packet Format
%  -------------
%  Session header : 55 AA 55 AA D4 06
%  Sample frame   : [signed 32-bit CIC sample] [00] [A3]
%  Timing frame   : [unsigned 32-bit cycles]   [80] [A3]
%  Byte order     : Big-endian
%
%  Timing frames report FPGA clock cycles across 1024 CIC
%  output intervals. They are not counted as CIC samples.
%% =============================================================

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

marker = uint8(hex2dec('A3'));
sample_type = uint8(hex2dec('00'));
timing_type = uint8(hex2dec('80'));
frame_bytes = 6;

sample_names = {'packet_pos', 'session_id', 'sample_idx', 'cic_raw'};
timing_names = {'packet_pos', 'session_id', 'measurement_idx', 'clock_cycles'};

L = numel(bytes);
sample_rows = zeros(floor(L/frame_bytes), numel(sample_names));
timing_rows = zeros(floor(L/frame_bytes), numel(timing_names));

n_samples = 0;
n_timing = 0;
session_id = 0;
sample_idx = 0;
measurement_idx = 0;
skipped = 0;
i = 1;

%% ---- Decode FPGA Frames ----

while i + frame_bytes - 1 <= L

    % Start a new acquisition session.
    if isequal(bytes(i:i+5).', header)
        session_id = session_id + 1;
        sample_idx = 0;
        measurement_idx = 0;
        i = i + frame_bytes;
        continue;
    end

    % Ignore data before the first session header.
    if session_id == 0
        i = i + 1;
        continue;
    end

    frame_type = bytes(i+4);

    if bytes(i+5) ~= marker || ...
            (frame_type ~= sample_type && frame_type ~= timing_type)
        skipped = skipped + 1;
        i = i + 1;
        continue;
    end

    if frame_type == sample_type
        % Signed 32-bit CIC output.
        raw = bytes_to_u32_be(bytes(i:i+3));
        if raw >= 2147483648
            raw = raw - 4294967296;
        end

        n_samples = n_samples + 1;
        sample_rows(n_samples,:) = [i, session_id, sample_idx, raw];
        sample_idx = sample_idx + 1;

    else
        % Unsigned 32-bit elapsed FPGA clock cycles.
        cycles = bytes_to_u32_be(bytes(i:i+3));

        n_timing = n_timing + 1;
        timing_rows(n_timing,:) = [ ...
            i, session_id, measurement_idx, cycles];
        measurement_idx = measurement_idx + 1;
    end

    i = i + frame_bytes;
end

%% ---- Return Decoded Tables ----

if session_id == 0
    warning('No FPGA session header found.');
elseif skipped > 0
    warning('Skipped %d unrecognized bytes.', skipped);
end

T = array2table(sample_rows(1:n_samples,:), ...
    'VariableNames', sample_names);

timing = array2table(timing_rows(1:n_timing,:), ...
    'VariableNames', timing_names);
end

%% ---- Unsigned 32-Bit Big-Endian Conversion ----

function value = bytes_to_u32_be(b)
    b = uint32(b(:));
    u = bitor(bitshift(b(1),24), bitshift(b(2),16));
    u = bitor(u, bitshift(b(3),8));
    u = bitor(u, b(4));
    value = double(u);
end
