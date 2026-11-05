%% FPGA-to-ESP32 Synthetic Transport Validation
% Verify sequence continuity, packet framing, and 12-bit payload integrity
% from a single FPGA-generated pattern capture recorded by the ESP32.

clear; clc;

capture_file = "esp_capture.bin";

pattern = double([hex2dec('123'), hex2dec('FFF'), ...
                  hex2dec('000'), hex2dec('A55'), ...
                  hex2dec('5AA'), hex2dec('800'), ...
                  hex2dec('001'), hex2dec('DAD')]);

%% Decode capture and check payloads

[T, stats] = parser(capture_file);

expected_payload = pattern(mod(T.sequence, numel(pattern)) + 1);
payload_errors = nnz(T.payload ~= expected_payload(:));

%% Verify sequence and framing integrity

first_sequence_error = isempty(T) || T.sequence(1) ~= 0;

passed = stats.sessions == 1 && stats.samples > 0 && ...
    stats.missing_samples_between_frames == 0 && ...
    stats.duplicate_frames == 0 && ...
    stats.ambiguous_or_backward_jumps == 0 && ...
    stats.skipped_bytes == 0 && ...
    stats.leading_bytes == 0 && ...
    stats.trailing_bytes == 0 && ...
    ~first_sequence_error && payload_errors == 0;

%% Results

fprintf('\nFPGA TRANSPORT VALIDATION\n');
fprintf('-------------------------\n');
fprintf('Received frames:      %d\n', stats.samples);
fprintf('Missing frames:       %d\n', stats.missing_samples_between_frames);
fprintf('Duplicate sequences:  %d\n', stats.duplicate_frames);
fprintf('Backward jumps:       %d\n', stats.ambiguous_or_backward_jumps);
fprintf('Incorrect payloads:   %d\n', payload_errors);
fprintf('Framing errors:       %d skipped bytes\n', stats.skipped_bytes);
fprintf('Leading bytes:        %d\n', stats.leading_bytes);
fprintf('Trailing bytes:       %d\n', stats.trailing_bytes);
fprintf('First sequence error: %d\n', first_sequence_error);
fprintf('Result:               %s\n', string_for_result(passed));

function label = string_for_result(passed)
    if passed
        label = 'PASS';
    else
        label = 'FAIL';
    end
end
