// SPDX-License-Identifier: GPL-2.0-only
const std = @import("std");
const ipc_manifest = @import("ipc_manifest.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("pwd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

const bundle_id_error_none: u32 = 0;
const bundle_id_error_required: u32 = 1;
const bundle_id_error_invalid: u32 = 2;

const line_scan_no_newline: i64 = -1;
const line_scan_overflow: i64 = -2;
const line_scan_invalid_argument: i64 = -3;

const default_socket_suffix = "/Library/Caches/com.barut.OmniWM/ipc.sock";
const secret_suffix = ".secret";

fn setErrno(value: c_int) void {
    c.__error().* = value;
}

fn cStringLen(value: [*c]const u8) usize {
    var length: usize = 0;
    while (value[length] != 0) : (length += 1) {}
    return length;
}

fn cStringSlice(value: [*c]const u8) []const u8 {
    return value[0..cStringLen(value)];
}

fn writeCString(output: [*c]u8, output_capacity: usize, value: []const u8) i64 {
    if (output == null) {
        setErrno(c.EINVAL);
        return -1;
    }
    if (output_capacity <= value.len) {
        setErrno(c.ERANGE);
        return -1;
    }

    for (value, 0..) |byte, index| {
        output[index] = byte;
    }
    output[value.len] = 0;
    return @as(i64, @intCast(value.len));
}

fn trimASCIIWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;

    while (start < end and std.ascii.isWhitespace(value[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(value[end - 1])) : (end -= 1) {}

    return value[start..end];
}

fn buildDefaultSocketPath(
    home_path: ?[]const u8,
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    const home = home_path orelse "";
    const total_length = home.len + default_socket_suffix.len;

    if (output == null) {
        setErrno(c.EINVAL);
        return -1;
    }
    if (output_capacity <= total_length) {
        setErrno(c.ERANGE);
        return -1;
    }

    for (home, 0..) |byte, index| {
        output[index] = byte;
    }
    for (default_socket_suffix, 0..) |byte, index| {
        output[home.len + index] = byte;
    }
    output[total_length] = 0;
    return @as(i64, @intCast(total_length));
}

fn validatedWorkspaceNumber(candidate: []const u8) ?u64 {
    if (candidate.len == 0) {
        return null;
    }

    const parsed = std.fmt.parseUnsigned(u64, candidate, 10) catch return null;
    if (parsed == 0) {
        return null;
    }

    var buffer: [32]u8 = undefined;
    const normalized = std.fmt.bufPrint(&buffer, "{d}", .{parsed}) catch return null;
    if (!std.mem.eql(u8, normalized, candidate)) {
        return null;
    }

    return parsed;
}

fn isBundleIDCharacter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

fn bundleIDValidationCode(bundle_id: []const u8) u32 {
    const trimmed = trimASCIIWhitespace(bundle_id);
    if (trimmed.len == 0) {
        return bundle_id_error_required;
    }

    var saw_separator = false;
    for (trimmed, 0..) |byte, index| {
        if (isBundleIDCharacter(byte)) {
            saw_separator = false;
            continue;
        }

        if ((byte == '.' or byte == '-') and index > 0 and index + 1 < trimmed.len and !saw_separator) {
            saw_separator = true;
            continue;
        }

        return bundle_id_error_invalid;
    }

    if (saw_separator) {
        return bundle_id_error_invalid;
    }

    return bundle_id_error_none;
}

fn socketAddress(path: []const u8) ?c.sockaddr_un {
    var address = std.mem.zeroes(c.sockaddr_un);
    address.sun_family = c.AF_UNIX;

    const path_capacity = @sizeOf(@TypeOf(address.sun_path));
    if (path.len >= path_capacity) {
        setErrno(c.ENAMETOOLONG);
        return null;
    }

    for (path, 0..) |byte, index| {
        address.sun_path[index] = @as(@TypeOf(address.sun_path[0]), @intCast(byte));
    }

    return address;
}

fn configureSocket(fd: c_int, non_blocking: bool) void {
    const existing_flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (existing_flags >= 0) {
        const updated_flags = if (non_blocking) (existing_flags | c.O_NONBLOCK) else (existing_flags & ~@as(c_int, c.O_NONBLOCK));
        _ = c.fcntl(fd, c.F_SETFL, updated_flags);
    }

    const descriptor_flags = c.fcntl(fd, c.F_GETFD, @as(c_int, 0));
    if (descriptor_flags >= 0) {
        _ = c.fcntl(fd, c.F_SETFD, descriptor_flags | c.FD_CLOEXEC);
    }

    var no_sigpipe: c_int = 1;
    _ = c.setsockopt(
        fd,
        c.SOL_SOCKET,
        c.SO_NOSIGPIPE,
        &no_sigpipe,
        @sizeOf(c_int),
    );
}

fn isActiveSocket(path: []const u8) c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    defer _ = c.close(fd);

    var address = socketAddress(path) orelse return -1;
    const result = c.connect(
        fd,
        @ptrCast(&address),
        @sizeOf(c.sockaddr_un),
    );
    if (result == 0) {
        return 1;
    }

    switch (c.__error().*) {
        c.ECONNREFUSED, c.ENOENT => return 0,
        else => return -1,
    }
}

pub export fn omniwm_ipc_resolved_socket_path(
    override_path: [*c]const u8,
    home_path: [*c]const u8,
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    if (override_path != null) {
        const override_slice = cStringSlice(override_path);
        if (override_slice.len != 0) {
            return writeCString(output, output_capacity, override_slice);
        }
    }

    const explicit_home = if (home_path != null) cStringSlice(home_path) else null;
    return buildDefaultSocketPath(explicit_home, output, output_capacity);
}

pub export fn omniwm_ipc_secret_path(
    socket_path: [*c]const u8,
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    if (socket_path == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    const socket_path_slice = cStringSlice(socket_path);
    if (output == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    const total_length = socket_path_slice.len + secret_suffix.len;
    if (output_capacity <= total_length) {
        setErrno(c.ERANGE);
        return -1;
    }

    for (socket_path_slice, 0..) |byte, index| {
        output[index] = byte;
    }
    for (secret_suffix, 0..) |byte, index| {
        output[socket_path_slice.len + index] = byte;
    }
    output[total_length] = 0;
    return @as(i64, @intCast(total_length));
}

pub export fn omniwm_ipc_bundle_id_validation_code(bundle_id: [*c]const u8) u32 {
    if (bundle_id == null) {
        return bundle_id_error_required;
    }
    return bundleIDValidationCode(cStringSlice(bundle_id));
}

pub export fn omniwm_ipc_automation_manifest_json(
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    return writeCString(output, output_capacity, ipc_manifest.automation_manifest_json);
}

pub export fn omniwm_workspace_id_normalize(
    candidate: [*c]const u8,
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    if (candidate == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    const workspace_number = validatedWorkspaceNumber(cStringSlice(candidate)) orelse {
        setErrno(c.EINVAL);
        return -1;
    };
    var buffer: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, "{d}", .{workspace_number}) catch {
        setErrno(c.EINVAL);
        return -1;
    };
    return writeCString(output, output_capacity, rendered);
}

pub export fn omniwm_workspace_id_from_number(
    workspace_number: u64,
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    if (workspace_number == 0) {
        setErrno(c.EINVAL);
        return -1;
    }

    var buffer: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buffer, "{d}", .{workspace_number}) catch {
        setErrno(c.EINVAL);
        return -1;
    };
    return writeCString(output, output_capacity, rendered);
}

pub export fn omniwm_workspace_number_from_raw_id(
    raw_id: [*c]const u8,
    workspace_number: [*c]u64,
) u8 {
    if (raw_id == null or workspace_number == null) {
        return 0;
    }

    workspace_number.* = validatedWorkspaceNumber(cStringSlice(raw_id)) orelse return 0;
    return 1;
}

pub export fn omniwm_ipc_find_newline(
    bytes: [*c]const u8,
    byte_count: usize,
    max_line_bytes: usize,
) i64 {
    if (bytes == null and byte_count != 0) {
        return line_scan_invalid_argument;
    }

    var index: usize = 0;
    while (index < byte_count) : (index += 1) {
        if (bytes[index] == 0x0A) {
            if (index > max_line_bytes) {
                return line_scan_overflow;
            }
            return @as(i64, @intCast(index));
        }
    }

    if (byte_count > max_line_bytes) {
        return line_scan_overflow;
    }

    return line_scan_no_newline;
}

pub export fn omniwm_ipc_socket_connect(path: [*c]const u8) c_int {
    if (path == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    configureSocket(fd, false);

    var address = socketAddress(cStringSlice(path)) orelse {
        _ = c.close(fd);
        return -1;
    };

    const result = c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr_un));
    if (result != 0) {
        _ = c.close(fd);
        return -1;
    }

    return fd;
}

pub export fn omniwm_ipc_socket_make_listening(path: [*c]const u8) c_int {
    if (path == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    configureSocket(fd, true);

    var address = socketAddress(cStringSlice(path)) orelse {
        _ = c.close(fd);
        return -1;
    };

    if (c.bind(fd, @ptrCast(&address), @sizeOf(c.sockaddr_un)) != 0) {
        _ = c.close(fd);
        return -1;
    }

    if (c.chmod(path, 0o600) != 0) {
        _ = c.close(fd);
        return -1;
    }

    if (c.listen(fd, c.SOMAXCONN) != 0) {
        _ = c.close(fd);
        return -1;
    }

    return fd;
}

pub export fn omniwm_ipc_socket_remove_existing_if_needed(path: [*c]const u8) c_int {
    if (path == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    var file_status: c.struct_stat = undefined;
    if (c.lstat(path, &file_status) != 0) {
        if (c.__error().* == c.ENOENT) {
            return 0;
        }
        return -1;
    }

    const file_type = file_status.st_mode & c.S_IFMT;
    if (file_type != c.S_IFSOCK) {
        setErrno(c.EEXIST);
        return -1;
    }

    const active = isActiveSocket(cStringSlice(path));
    if (active > 0) {
        setErrno(c.EADDRINUSE);
        return -1;
    }
    if (active < 0) {
        return -1;
    }

    return c.unlink(path);
}

pub export fn omniwm_ipc_socket_is_active(path: [*c]const u8) c_int {
    if (path == null) {
        setErrno(c.EINVAL);
        return -1;
    }
    return isActiveSocket(cStringSlice(path));
}

pub export fn omniwm_ipc_socket_configure(fd: c_int, non_blocking: u8) c_int {
    if (fd < 0) {
        setErrno(c.EBADF);
        return -1;
    }
    configureSocket(fd, non_blocking != 0);
    return 0;
}

pub export fn omniwm_ipc_socket_is_current_user(fd: c_int) c_int {
    var effective_user_id: c.uid_t = 0;
    var group_id: c.gid_t = 0;
    if (c.getpeereid(fd, &effective_user_id, &group_id) != 0) {
        return -1;
    }
    return if (effective_user_id == c.geteuid()) 1 else 0;
}

fn validateSecretTokenFile(fd: c_int) c_int {
    var file_status: c.struct_stat = undefined;
    if (c.fstat(fd, &file_status) != 0) {
        return -1;
    }

    if ((file_status.st_mode & c.S_IFMT) != c.S_IFREG) {
        setErrno(c.EINVAL);
        return -1;
    }
    if (file_status.st_uid != c.geteuid()) {
        setErrno(c.EACCES);
        return -1;
    }
    if ((file_status.st_mode & 0o077) != 0) {
        setErrno(c.EACCES);
        return -1;
    }
    return 0;
}

pub export fn omniwm_ipc_write_secret_token(
    socket_path: [*c]const u8,
    token: [*c]const u8,
) c_int {
    if (socket_path == null or token == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    var secret_path_buffer: [512]u8 = undefined;
    const secret_length = omniwm_ipc_secret_path(socket_path, &secret_path_buffer, secret_path_buffer.len);
    if (secret_length < 0) {
        return -1;
    }

    if (c.unlink(@ptrCast(&secret_path_buffer)) != 0 and c.__error().* != c.ENOENT) {
        return -1;
    }

    const fd = c.open(
        @ptrCast(&secret_path_buffer),
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW,
        @as(c_int, 0o600),
    );
    if (fd < 0) {
        return -1;
    }
    defer _ = c.close(fd);

    if (validateSecretTokenFile(fd) != 0) {
        return -1;
    }

    const token_slice = cStringSlice(token);
    if (token_slice.len != 0) {
        if (c.write(fd, token_slice.ptr, token_slice.len) < 0) {
            return -1;
        }
    }

    var newline: [1]u8 = .{0x0A};
    if (c.write(fd, &newline, newline.len) < 0) {
        return -1;
    }

    if (c.fchmod(fd, 0o600) != 0) {
        return -1;
    }

    return 0;
}

pub export fn omniwm_ipc_read_secret_token_for_socket(
    socket_path: [*c]const u8,
    output: [*c]u8,
    output_capacity: usize,
) i64 {
    if (socket_path == null) {
        setErrno(c.EINVAL);
        return -1;
    }

    var secret_path_buffer: [512]u8 = undefined;
    if (omniwm_ipc_secret_path(socket_path, &secret_path_buffer, secret_path_buffer.len) < 0) {
        return -1;
    }

    const fd = c.open(@ptrCast(&secret_path_buffer), c.O_RDONLY | c.O_NOFOLLOW, @as(c_int, 0));
    if (fd < 0) {
        return -1;
    }
    defer _ = c.close(fd);

    if (validateSecretTokenFile(fd) != 0) {
        return -1;
    }

    var read_buffer: [1024]u8 = undefined;
    const read_count = c.read(fd, &read_buffer, read_buffer.len);
    if (read_count < 0) {
        return -1;
    }

    const trimmed = trimASCIIWhitespace(read_buffer[0..@as(usize, @intCast(read_count))]);
    if (trimmed.len == 0) {
        setErrno(c.ENOENT);
        return -1;
    }

    return writeCString(output, output_capacity, trimmed);
}

test "ipc bundle id validation matches expected cases" {
    try std.testing.expectEqual(bundle_id_error_none, bundleIDValidationCode("com.example.app"));
    try std.testing.expectEqual(bundle_id_error_none, bundleIDValidationCode("dentalplus-air"));
    try std.testing.expectEqual(bundle_id_error_required, bundleIDValidationCode("   "));
    try std.testing.expectEqual(bundle_id_error_invalid, bundleIDValidationCode("com/example/app"));
    try std.testing.expectEqual(bundle_id_error_invalid, bundleIDValidationCode("Dental Plus"));
}

test "workspace id normalization rejects leading zeroes and zero" {
    try std.testing.expect(validatedWorkspaceNumber("10") != null);
    try std.testing.expect(validatedWorkspaceNumber("01") == null);
    try std.testing.expect(validatedWorkspaceNumber("0") == null);
}

test "automation manifest json parses and exposes registry surfaces" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        ipc_manifest.automation_manifest_json,
        .{},
    );
    defer parsed.deinit();

    const object = parsed.value.object;
    try std.testing.expect(object.get("queryDescriptors") != null);
    try std.testing.expect(object.get("commandDescriptors") != null);
    try std.testing.expect(object.get("subscriptionDescriptors") != null);
}

test "newline scan returns positions and overflow" {
    try std.testing.expectEqual(@as(i64, 3), omniwm_ipc_find_newline("abc\n", 4, 8));
    try std.testing.expectEqual(line_scan_no_newline, omniwm_ipc_find_newline("abc", 3, 8));
    try std.testing.expectEqual(line_scan_overflow, omniwm_ipc_find_newline("abcdefghi", 9, 8));
}

test "socket path helpers build expected suffixes" {
    var buffer: [256]u8 = undefined;
    const resolved_length = omniwm_ipc_resolved_socket_path("/tmp/custom.sock", null, &buffer, buffer.len);
    try std.testing.expect(resolved_length > 0);
    try std.testing.expect(std.mem.eql(u8, buffer[0..@as(usize, @intCast(resolved_length))], "/tmp/custom.sock"));

    const secret_length = omniwm_ipc_secret_path("/tmp/custom.sock", &buffer, buffer.len);
    try std.testing.expect(secret_length > 0);
    try std.testing.expect(std.mem.eql(u8, buffer[0..@as(usize, @intCast(secret_length))], "/tmp/custom.sock.secret"));
}
