//! Tempo blockchain funding — per-role wallets and on-chain USDC transfers.
//!
//! Each role's wallet lives alongside its config in `.bees/roles/<role>/`:
//!   .bees/roles/founder/
//!     config.json
//!     prompt.md
//!     wallet.key       — private key (hex, mode 0600)
//!     wallet.address   — cached address (derived from key)
//!
//! The investor funds role wallets by approving funding requests.
//! The founder distributes to other roles from its own wallet.
//!
//! Key generation and address derivation are done natively using Zig's
//! stdlib secp256k1 and keccak256 — no external dependencies.

const std = @import("std");
const Io = std.Io;
const fs = @import("fs.zig");

const Secp256k1 = std.crypto.ecc.Secp256k1;
const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Default TIP-20 token on Tempo mainnet: USDC.e (Bridged USDC via Stargate).
pub const DEFAULT_TOKEN: []const u8 = "0x20c000000000000000000000b9537d11c60e8b50";

/// ECDSA signature scheme: secp256k1 with SHA-256 for deterministic nonce (RFC 6979).
/// Messages are pre-hashed with keccak256 before signing (Ethereum convention).
const EcdsaScheme = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

// ── Native crypto ──────────────────────────────────────────────────────

/// Ethereum-style ECDSA signature: r (32 bytes) + s (32 bytes) + v (1 byte).
pub const EthSignature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8, // Recovery ID: 0 or 1 (add 27 for legacy Ethereum, or use EIP-155 chain_id encoding)
};

/// Sign a 32-byte message hash (typically keccak256) with a private key.
/// Returns (r, s, v) where v is the recovery ID (0 or 1).
/// Uses deterministic nonce generation (RFC 6979) via HMAC-SHA256.
pub fn ecdsaSign(privkey: [32]u8, msg_hash: [32]u8) !EthSignature {
    const Scalar = Secp256k1.scalar.Scalar;

    // Deterministic k via the Ecdsa scheme's internal machinery
    const kp = try EcdsaScheme.KeyPair.fromSecretKey(.{ .bytes = privkey });
    const sig = try kp.signPrehashed(msg_hash, null);

    // Recover the Y parity of R for the recovery ID.
    // Re-derive k and the R point using the same deterministic process.
    // The Zig stdlib doesn't expose k, so we recompute R from r and use
    // trial recovery to determine v.
    const r_scalar = try Scalar.fromBytes(sig.r, .big);
    const s_scalar = try Scalar.fromBytes(sig.s, .big);
    const z = reduceToScalar(msg_hash);

    // Try v=0 and v=1, see which recovers to our public key
    const pub_uncompressed = kp.public_key.toUncompressedSec1();
    var v: u8 = 0;
    while (v < 2) : (v += 1) {
        if (recoverPublicKey(r_scalar, s_scalar, z, v == 1)) |recovered| {
            if (std.mem.eql(u8, &recovered, &pub_uncompressed)) break;
        }
    }

    return .{ .r = sig.r, .s = sig.s, .v = v };
}

/// Verify a signature against a message hash and public key.
pub fn ecdsaVerify(sig_r: [32]u8, sig_s: [32]u8, msg_hash: [32]u8, pubkey_uncompressed: [65]u8) !void {
    const sig = EcdsaScheme.Signature{ .r = sig_r, .s = sig_s };
    const pk = try EcdsaScheme.PublicKey.fromSec1(&pubkey_uncompressed);
    try sig.verifyPrehashed(msg_hash, pk);
}

// Recover uncompressed public key from (r, s, z, is_odd_y).
fn recoverPublicKey(
    r: Secp256k1.scalar.Scalar,
    s: Secp256k1.scalar.Scalar,
    z: Secp256k1.scalar.Scalar,
    is_odd_y: bool,
) ?[65]u8 {
    // R point: x = r, y recovered from curve equation
    const r_fe = Secp256k1.Fe.fromBytes(r.toBytes(.big), .big) catch return null;
    const y = Secp256k1.recoverY(r_fe, is_odd_y) catch return null;

    const R = Secp256k1.fromAffineCoordinates(.{ .x = r_fe, .y = y }) catch return null;

    // P = r^-1 * (s*R - z*G)
    const r_inv = r.invert();
    const zr = r_inv.mul(z); // z/r
    const sr = r_inv.mul(s); // s/r

    // P = s/r * R - z/r * G
    const sR = R.mul(sr.toBytes(.big), .big) catch return null;
    const zG = Secp256k1.basePoint.mul(zr.toBytes(.big), .big) catch return null;
    const P = sR.sub(zG);

    P.rejectIdentity() catch return null;
    return P.toUncompressedSec1();
}

fn reduceToScalar(bytes: [32]u8) Secp256k1.scalar.Scalar {
    var buf: [48]u8 = .{0} ** 48;
    @memcpy(buf[16..48], &bytes);
    return Secp256k1.scalar.Scalar.fromBytes48(buf, .big);
}

/// Derive an Ethereum/Tempo address from a 32-byte private key.
/// Returns a 42-char hex string "0x..." or error.
pub fn deriveAddressFromKey(privkey: [32]u8) ![42]u8 {
    // Multiply base point by private key to get public key
    const point = try Secp256k1.basePoint.mul(privkey, .big);

    // Get uncompressed SEC1 encoding: 04 || x (32 bytes) || y (32 bytes)
    const uncompressed = point.toUncompressedSec1();

    // Keccak256 hash of the 64-byte public key (skip the 04 prefix)
    var hash: [32]u8 = undefined;
    Keccak256.hash(uncompressed[1..65], &hash, .{});

    // Address is the last 20 bytes of the hash, hex-encoded with 0x prefix
    var addr: [42]u8 = undefined;
    addr[0] = '0';
    addr[1] = 'x';
    for (hash[12..32], 0..) |byte, i| {
        addr[2 + i * 2] = hexChar(byte >> 4);
        addr[2 + i * 2 + 1] = hexChar(byte & 0x0f);
    }
    return addr;
}

/// Parse a hex private key string (0x-prefixed or bare) into 32 bytes.
pub fn parseHexKey(hex_str: []const u8) ![32]u8 {
    const raw = if (hex_str.len >= 2 and hex_str[0] == '0' and hex_str[1] == 'x')
        hex_str[2..]
    else
        hex_str;

    if (raw.len != 64) return error.InvalidKeyLength;

    var bytes: [32]u8 = undefined;
    for (0..32) |i| {
        bytes[i] = @as(u8, try hexVal(raw[i * 2])) << 4 | @as(u8, try hexVal(raw[i * 2 + 1]));
    }
    return bytes;
}

// ── Wallet management ──────────────────────────────────────────────────

/// Generate a new random private key for a role and store it in
/// .bees/roles/<role>/wallet.key. No-op if the key file already exists.
/// Returns the hex private key string (0x-prefixed, 66 chars).
pub fn ensureWallet(allocator: std.mem.Allocator, roles_dir: []const u8, role: []const u8) ![]const u8 {
    const key_path = try walletKeyPath(allocator, roles_dir, role);
    defer allocator.free(key_path);

    // Return existing key if present
    if (fs.readFileAlloc(allocator, key_path, 256)) |raw| {
        return std.mem.trim(u8, raw, &std.ascii.whitespace);
    } else |_| {}

    // Ensure role directory exists
    const role_dir = try std.fs.path.join(allocator, &.{ roles_dir, role });
    defer allocator.free(role_dir);
    fs.makePath(role_dir) catch {};

    // Generate 32 random bytes via Linux getrandom syscall
    var entropy: [32]u8 = undefined;
    const ret = std.os.linux.getrandom(&entropy, entropy.len, 0);
    if (ret != entropy.len) return error.RandomFailed;

    var hex_buf: [66]u8 = undefined;
    hex_buf[0] = '0';
    hex_buf[1] = 'x';
    for (entropy, 0..) |byte, i| {
        hex_buf[2 + i * 2] = hexChar(byte >> 4);
        hex_buf[2 + i * 2 + 1] = hexChar(byte & 0x0f);
    }

    // Write key file
    const f = try fs.createFile(key_path, .{});
    try fs.writeFile(f, &hex_buf);
    fs.closeFile(f);
    setFileMode(key_path);

    // Derive and cache the address immediately
    const addr = try deriveAddressFromKey(entropy);
    const addr_path = try walletAddrPath(allocator, roles_dir, role);
    defer allocator.free(addr_path);
    if (fs.createFile(addr_path, .{})) |af| {
        fs.writeFile(af, &addr) catch {};
        fs.closeFile(af);
    } else |_| {}

    return try allocator.dupe(u8, &hex_buf);
}

/// Load a role's private key from .bees/roles/<role>/wallet.key.
/// Returns null if no key exists for this role.
pub fn loadKey(allocator: std.mem.Allocator, roles_dir: []const u8, role: []const u8) ?[]const u8 {
    const key_path = walletKeyPath(allocator, roles_dir, role) catch return null;
    defer allocator.free(key_path);
    const raw = fs.readFileAlloc(allocator, key_path, 256) catch return null;
    return std.mem.trim(u8, raw, &std.ascii.whitespace);
}

/// Get a role's wallet address. Reads cached .address file first,
/// falls back to native derivation from the private key.
pub fn getAddress(
    io: Io,
    allocator: std.mem.Allocator,
    roles_dir: []const u8,
    role: []const u8,
) ?[]const u8 {
    _ = io; // No longer needed — derivation is native

    // Try cached address file
    const addr_path = walletAddrPath(allocator, roles_dir, role) catch return null;
    defer allocator.free(addr_path);
    if (fs.readFileAlloc(allocator, addr_path, 256)) |raw| {
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 42 and trimmed[0] == '0' and trimmed[1] == 'x') return trimmed;
        allocator.free(raw);
    } else |_| {}

    // Derive natively from private key
    const key_hex = loadKey(allocator, roles_dir, role) orelse return null;
    const key_bytes = parseHexKey(key_hex) catch return null;
    const addr = deriveAddressFromKey(key_bytes) catch return null;

    // Cache for future lookups
    if (fs.createFile(addr_path, .{})) |f| {
        fs.writeFile(f, &addr) catch {};
        fs.closeFile(f);
    } else |_| {}

    return allocator.dupe(u8, &addr) catch null;
}

// ── Transfers (still uses tempo CLI) ───────────────────────────────────

/// Execute an on-chain transfer. If private_key is null, uses the default
/// (investor) wallet from `tempo wallet login`. Otherwise uses the specified key.
/// Returns the transaction hash on success, or null on failure.
pub fn transfer(
    io: Io,
    allocator: std.mem.Allocator,
    amount: []const u8,
    token: []const u8,
    to: []const u8,
    private_key: ?[]const u8,
) !?[]const u8 {
    var argv_buf: [10][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = tempoPath();
    argc += 1;
    argv_buf[argc] = "wallet";
    argc += 1;
    argv_buf[argc] = "transfer";
    argc += 1;
    argv_buf[argc] = amount;
    argc += 1;
    argv_buf[argc] = token;
    argc += 1;
    argv_buf[argc] = to;
    argc += 1;
    if (private_key) |pk| {
        argv_buf[argc] = "--private-key";
        argc += 1;
        argv_buf[argc] = pk;
        argc += 1;
    }
    argv_buf[argc] = "-t";
    argc += 1;

    var child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_buf: [4096]u8 = undefined;
    var stdout_len: usize = 0;
    if (child.stdout) |stdout| {
        while (stdout_len < stdout_buf.len) {
            var iov = [1][]u8{stdout_buf[stdout_len..]};
            const n = io.vtable.netRead(io.userdata, stdout.handle, &iov) catch break;
            if (n == 0) break;
            stdout_len += n;
        }
    }

    // Drain stderr to avoid pipe deadlock
    var stderr_buf: [4096]u8 = undefined;
    var stderr_len: usize = 0;
    if (child.stderr) |stderr| {
        while (stderr_len < stderr_buf.len) {
            var iov = [1][]u8{stderr_buf[stderr_len..]};
            const n = io.vtable.netRead(io.userdata, stderr.handle, &iov) catch break;
            if (n == 0) break;
            stderr_len += n;
        }
    }

    const term = try child.wait(io);
    const exit_code: i16 = switch (term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    if (exit_code != 0) return null;

    const stdout_data = stdout_buf[0..stdout_len];
    const tx_hash = extractJsonField(stdout_data, "tx_hash") orelse
        extractQuotedValue(stdout_data, "tx_hash:") orelse
        extractTxHash(stdout_data);

    if (tx_hash) |hash| {
        return try allocator.dupe(u8, hash);
    }
    return null;
}

/// Check a wallet's balance via `tempo wallet whoami`.
pub fn getBalance(
    io: Io,
    allocator: std.mem.Allocator,
    private_key: ?[]const u8,
) !?[]const u8 {
    var argv_buf: [6][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = tempoPath();
    argc += 1;
    argv_buf[argc] = "wallet";
    argc += 1;
    argv_buf[argc] = "whoami";
    argc += 1;
    if (private_key) |pk| {
        argv_buf[argc] = "--private-key";
        argc += 1;
        argv_buf[argc] = pk;
        argc += 1;
    }
    argv_buf[argc] = "-t";
    argc += 1;

    var child = try std.process.spawn(io, .{
        .argv = argv_buf[0..argc],
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var stdout_buf: [8192]u8 = undefined;
    var stdout_len: usize = 0;
    if (child.stdout) |stdout| {
        while (stdout_len < stdout_buf.len) {
            var iov = [1][]u8{stdout_buf[stdout_len..]};
            const n = io.vtable.netRead(io.userdata, stdout.handle, &iov) catch break;
            if (n == 0) break;
            stdout_len += n;
        }
    }

    const term = try child.wait(io);
    const exit_code: i16 = switch (term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    if (exit_code != 0) return null;
    if (stdout_len == 0) return null;

    return try allocator.dupe(u8, stdout_buf[0..stdout_len]);
}

// ── Helpers ────────────────────────────────────────────────────────────

fn walletKeyPath(allocator: std.mem.Allocator, roles_dir: []const u8, role: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ roles_dir, role, "wallet.key" });
}

fn walletAddrPath(allocator: std.mem.Allocator, roles_dir: []const u8, role: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ roles_dir, role, "wallet.address" });
}

fn hexChar(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
}

fn hexVal(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHexChar,
    };
}

fn setFileMode(path: []const u8) void {
    const path_z = std.posix.toPosixPath(path) catch return;
    _ = std.c.chmod(&path_z, 0o600);
}

/// Resolve the tempo CLI binary path.
fn tempoPath() []const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(entry)), 0);
        if (std.mem.startsWith(u8, s, "HOME=")) {
            const home = s["HOME=".len..];
            const suffix = "/.tempo/bin/tempo";
            if (home.len + suffix.len < tempo_path_buf.len) {
                @memcpy(tempo_path_buf[0..home.len], home);
                @memcpy(tempo_path_buf[home.len..][0..suffix.len], suffix);
                const full = tempo_path_buf[0 .. home.len + suffix.len];
                if (fs.access(full)) return full;
            }
        }
    }
    return "tempo";
}

var tempo_path_buf: [256]u8 = undefined;

/// Extract a JSON string value: "key":"value"
pub fn extractJsonField(data: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, data, needle) orelse return null;

    const after_key = data[key_pos + needle.len ..];
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const after_colon = after_key[colon + 1 ..];
    const open = std.mem.indexOfScalar(u8, after_colon, '"') orelse return null;
    const val_start = after_colon[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, val_start, '"') orelse return null;
    return val_start[0..close];
}

/// Extract a quoted value after a key in TOML/toon format: `key: "value"`.
fn extractQuotedValue(data: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, data, key) orelse return null;
    const after_key = data[key_pos + key.len ..];
    const open = std.mem.indexOfScalar(u8, after_key, '"') orelse return null;
    const val_start = after_key[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, val_start, '"') orelse return null;
    return val_start[0..close];
}

/// Fallback: extract a tx hash (0x + 64 hex chars) from raw output.
fn extractTxHash(data: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + 2 < data.len) {
        if (data[pos] == '0' and data[pos + 1] == 'x') {
            var end = pos + 2;
            while (end < data.len and end - pos < 66) : (end += 1) {
                const c = data[end];
                if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) break;
            }
            if (end - pos == 66) return data[pos..end];
        }
        pos += 1;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "deriveAddressFromKey known vector" {
    // Well-known test: private key 1 → known Ethereum address
    var privkey: [32]u8 = .{0} ** 32;
    privkey[31] = 1; // Private key = 1

    const addr = try deriveAddressFromKey(privkey);
    // Private key 1 should produce address 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
    try std.testing.expectEqualStrings("0x7e5f4552091a69125d5dfcb7b8c2659029395bdf", &addr);
}

test "parseHexKey with 0x prefix" {
    const hex = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const bytes = try parseHexKey(hex);
    var expected: [32]u8 = .{0} ** 32;
    expected[31] = 1;
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "ecdsaSign produces valid recoverable signature" {
    // Private key 1
    var privkey: [32]u8 = .{0} ** 32;
    privkey[31] = 1;

    // Hash some message with keccak256
    var msg_hash: [32]u8 = undefined;
    Keccak256.hash("hello tempo", &msg_hash, .{});

    // Sign
    const sig = try ecdsaSign(privkey, msg_hash);

    // Verify: v should be 0 or 1
    try std.testing.expect(sig.v <= 1);

    // Verify the signature against the public key
    const point = try Secp256k1.basePoint.mul(privkey, .big);
    const pubkey = point.toUncompressedSec1();
    try ecdsaVerify(sig.r, sig.s, msg_hash, pubkey);
}

test "ecdsaSign recovery ID matches public key" {
    // Private key 2
    var privkey: [32]u8 = .{0} ** 32;
    privkey[31] = 2;

    var msg_hash: [32]u8 = undefined;
    Keccak256.hash("test transaction", &msg_hash, .{});

    const sig = try ecdsaSign(privkey, msg_hash);

    // Recover public key using the v value
    const r_scalar = try Secp256k1.scalar.Scalar.fromBytes(sig.r, .big);
    const s_scalar = try Secp256k1.scalar.Scalar.fromBytes(sig.s, .big);
    const z = reduceToScalar(msg_hash);

    const recovered = recoverPublicKey(r_scalar, s_scalar, z, sig.v == 1);
    try std.testing.expect(recovered != null);

    // Should match the actual public key
    const point = try Secp256k1.basePoint.mul(privkey, .big);
    const expected = point.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &expected, &recovered.?);
}

test "parseHexKey without prefix" {
    const hex = "0000000000000000000000000000000000000000000000000000000000000001";
    const bytes = try parseHexKey(hex);
    var expected: [32]u8 = .{0} ** 32;
    expected[31] = 1;
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}
