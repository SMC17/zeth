const std = @import("std");

const BigInt = std.math.big.int.Managed;

pub const PairingError = error{
    InvalidInputLength,
    InvalidPoint,
};

const field_modulus_dec = "21888242871839275222246405745257275088696311157297823662689037894645226208583";
const curve_order_dec = "21888242871839275222246405745257275088548364400416034343698204186575808495617";

const fq12_mod_coeffs = [_]i32{ 82, 0, 0, 0, 0, 0, -18, 0, 0, 0, 0, 0 };
const ate_loop_count: u128 = 29_793_968_203_157_093_288;
const log_ate_loop_count: usize = 63;

const Fq2 = struct {
    c0: BigInt,
    c1: BigInt,
};

const Fq12 = struct {
    c: [12]BigInt,
};

const G1 = struct {
    x: BigInt,
    y: BigInt,
    inf: bool,
};

const G2 = struct {
    x: Fq2,
    y: Fq2,
    inf: bool,
};

const G12 = struct {
    x: Fq12,
    y: Fq12,
    inf: bool,
};

fn biZero(a: std.mem.Allocator) !BigInt {
    return try BigInt.initSet(a, 0);
}

fn biOne(a: std.mem.Allocator) !BigInt {
    return try BigInt.initSet(a, 1);
}

fn biFromU64(a: std.mem.Allocator, n: u64) !BigInt {
    return try BigInt.initSet(a, n);
}

fn biFromDecimal(a: std.mem.Allocator, s: []const u8) !BigInt {
    var v = try BigInt.init(a);
    errdefer v.deinit();
    try v.setString(10, s);
    return v;
}

fn biFromBytesBE(a: std.mem.Allocator, bytes: []const u8) !BigInt {
    var out = try biZero(a);
    var mul256 = try biFromU64(a, 256);
    for (bytes) |b| {
        var t = try BigInt.init(a);
        try BigInt.mul(&t, &out, &mul256);
        var bb = try biFromU64(a, b);
        var next = try BigInt.init(a);
        try BigInt.add(&next, &t, &bb);
        out = next;
    }
    return out;
}

fn biClone(a: std.mem.Allocator, src: BigInt) !BigInt {
    var out = try BigInt.init(a);
    errdefer out.deinit();
    try out.copy(src.toConst());
    return out;
}

fn biEq(x: BigInt, y: BigInt) bool {
    return BigInt.order(x, y) == .eq;
}

fn biLt(x: BigInt, y: BigInt) bool {
    return BigInt.order(x, y) == .lt;
}

fn biIsZero(x: BigInt) bool {
    return x.eqlZero();
}

fn biMod(a: std.mem.Allocator, x: BigInt, m: BigInt) !BigInt {
    var q = try BigInt.init(a);
    var r = try BigInt.init(a);
    try BigInt.divTrunc(&q, &r, &x, &m);
    if (BigInt.order(r, try biZero(a)) == .lt) {
        var t = try BigInt.init(a);
        try BigInt.add(&t, &r, &m);
        return t;
    }
    return r;
}

fn biAddMod(a: std.mem.Allocator, x: BigInt, y: BigInt, p: BigInt) !BigInt {
    var s = try BigInt.init(a);
    try BigInt.add(&s, &x, &y);
    return try biMod(a, s, p);
}

fn biSubMod(a: std.mem.Allocator, x: BigInt, y: BigInt, p: BigInt) !BigInt {
    var d = try BigInt.init(a);
    try BigInt.sub(&d, &x, &y);
    return try biMod(a, d, p);
}

fn biMulMod(a: std.mem.Allocator, x: BigInt, y: BigInt, p: BigInt) !BigInt {
    var m = try BigInt.init(a);
    try BigInt.mul(&m, &x, &y);
    return try biMod(a, m, p);
}

fn biMulSmallMod(a: std.mem.Allocator, x: BigInt, n: i32, p: BigInt) !BigInt {
    const absn: u64 = @intCast(if (n < 0) -n else n);
    const s = try biFromU64(a, absn);
    const v = try biMulMod(a, x, s, p);
    if (n < 0) {
        return try biSubMod(a, try biZero(a), v, p);
    }
    return v;
}

fn biPowMod(a: std.mem.Allocator, base_in: BigInt, exp_in: BigInt, p: BigInt) !BigInt {
    var q = try BigInt.init(a);
    var rem = try BigInt.init(a);
    try BigInt.divTrunc(&q, &rem, &base_in, &p);
    var base = rem;
    var exp = try biClone(a, exp_in);
    var out = try biOne(a);

    while (!exp.eqlZero()) {
        if (exp.isOdd()) {
            var prod = try BigInt.init(a);
            try BigInt.mul(&prod, &out, &base);
            try BigInt.divTrunc(&q, &rem, &prod, &p);
            out = try biClone(a, rem);
        }

        var sq = try BigInt.init(a);
        try BigInt.mul(&sq, &base, &base);
        try BigInt.divTrunc(&q, &rem, &sq, &p);
        base = try biClone(a, rem);

        var shifted = try BigInt.init(a);
        try BigInt.shiftRight(&shifted, &exp, 1);
        exp = shifted;
    }

    return out;
}

fn biInvMod(a: std.mem.Allocator, x: BigInt, p: BigInt) !BigInt {
    var two = try biFromU64(a, 2);
    var e = try BigInt.init(a);
    try BigInt.sub(&e, &p, &two);
    return try biPowMod(a, x, e, p);
}

fn fq2Zero(a: std.mem.Allocator) !Fq2 {
    return .{ .c0 = try biZero(a), .c1 = try biZero(a) };
}

fn fq2One(a: std.mem.Allocator) !Fq2 {
    return .{ .c0 = try biOne(a), .c1 = try biZero(a) };
}

fn fq2Const(a: std.mem.Allocator, c0: u64, c1: u64) !Fq2 {
    return .{ .c0 = try biFromU64(a, c0), .c1 = try biFromU64(a, c1) };
}

fn fq2Eq(x: Fq2, y: Fq2) bool {
    return biEq(x.c0, y.c0) and biEq(x.c1, y.c1);
}

fn fq2IsZero(x: Fq2) bool {
    return biIsZero(x.c0) and biIsZero(x.c1);
}

fn fq2Neg(a: std.mem.Allocator, x: Fq2, p: BigInt) !Fq2 {
    return .{
        .c0 = try biSubMod(a, try biZero(a), x.c0, p),
        .c1 = try biSubMod(a, try biZero(a), x.c1, p),
    };
}

fn fq2Add(a: std.mem.Allocator, x: Fq2, y: Fq2, p: BigInt) !Fq2 {
    return .{
        .c0 = try biAddMod(a, x.c0, y.c0, p),
        .c1 = try biAddMod(a, x.c1, y.c1, p),
    };
}

fn fq2Sub(a: std.mem.Allocator, x: Fq2, y: Fq2, p: BigInt) !Fq2 {
    return .{
        .c0 = try biSubMod(a, x.c0, y.c0, p),
        .c1 = try biSubMod(a, x.c1, y.c1, p),
    };
}

fn fq2Mul(a: std.mem.Allocator, x: Fq2, y: Fq2, p: BigInt) !Fq2 {
    const ac = try biMulMod(a, x.c0, y.c0, p);
    const bd = try biMulMod(a, x.c1, y.c1, p);
    const ad = try biMulMod(a, x.c0, y.c1, p);
    const bc = try biMulMod(a, x.c1, y.c0, p);
    return .{
        .c0 = try biSubMod(a, ac, bd, p),
        .c1 = try biAddMod(a, ad, bc, p),
    };
}

fn fq2Square(a: std.mem.Allocator, x: Fq2, p: BigInt) !Fq2 {
    return try fq2Mul(a, x, x, p);
}

fn fq2Inv(a: std.mem.Allocator, x: Fq2, p: BigInt) !Fq2 {
    const t0 = try biMulMod(a, x.c0, x.c0, p);
    const t1 = try biMulMod(a, x.c1, x.c1, p);
    const den = try biAddMod(a, t0, t1, p);
    const den_inv = try biInvMod(a, den, p);
    return .{
        .c0 = try biMulMod(a, x.c0, den_inv, p),
        .c1 = try biMulMod(a, try biSubMod(a, try biZero(a), x.c1, p), den_inv, p),
    };
}

fn fq2Div(a: std.mem.Allocator, x: Fq2, y: Fq2, p: BigInt) !Fq2 {
    return try fq2Mul(a, x, try fq2Inv(a, y, p), p);
}

fn fq12Zero(a: std.mem.Allocator) !Fq12 {
    var c: [12]BigInt = undefined;
    for (0..12) |i| c[i] = try biZero(a);
    return .{ .c = c };
}

fn fq12One(a: std.mem.Allocator) !Fq12 {
    var c: [12]BigInt = undefined;
    for (0..12) |i| c[i] = try biZero(a);
    c[0] = try biOne(a);
    return .{ .c = c };
}

fn fq12Eq(x: Fq12, y: Fq12) bool {
    for (0..12) |i| {
        if (!biEq(x.c[i], y.c[i])) return false;
    }
    return true;
}

fn fq12Neg(a: std.mem.Allocator, x: Fq12, p: BigInt) !Fq12 {
    var out: [12]BigInt = undefined;
    for (0..12) |i| out[i] = try biSubMod(a, try biZero(a), x.c[i], p);
    return .{ .c = out };
}

fn fq12Add(a: std.mem.Allocator, x: Fq12, y: Fq12, p: BigInt) !Fq12 {
    var out: [12]BigInt = undefined;
    for (0..12) |i| out[i] = try biAddMod(a, x.c[i], y.c[i], p);
    return .{ .c = out };
}

fn fq12Sub(a: std.mem.Allocator, x: Fq12, y: Fq12, p: BigInt) !Fq12 {
    var out: [12]BigInt = undefined;
    for (0..12) |i| out[i] = try biSubMod(a, x.c[i], y.c[i], p);
    return .{ .c = out };
}

fn fq12Mul(a: std.mem.Allocator, x: Fq12, y: Fq12, p: BigInt) !Fq12 {
    var b: [23]BigInt = undefined;
    for (0..23) |i| b[i] = try biZero(a);

    for (0..12) |i| {
        for (0..12) |j| {
            const prod = try biMulMod(a, x.c[i], y.c[j], p);
            b[i + j] = try biAddMod(a, b[i + j], prod, p);
        }
    }

    var k: isize = 22;
    while (k >= 12) : (k -= 1) {
        const top = b[@intCast(k)];
        if (biIsZero(top)) continue;

        const exp: usize = @intCast(k - 12);
        for (0..12) |i| {
            const coeff = fq12_mod_coeffs[i];
            if (coeff == 0) continue;
            const term = try biMulSmallMod(a, top, coeff, p);
            b[exp + i] = try biSubMod(a, b[exp + i], term, p);
        }
    }

    var out: [12]BigInt = undefined;
    for (0..12) |i| out[i] = b[i];
    return .{ .c = out };
}

fn fq12Square(a: std.mem.Allocator, x: Fq12, p: BigInt) !Fq12 {
    return try fq12Mul(a, x, x, p);
}

fn fq12Pow(a: std.mem.Allocator, base_in: Fq12, exp_in: BigInt, p: BigInt) !Fq12 {
    var exp = try biClone(a, exp_in);
    var base = base_in;
    var out = try fq12One(a);

    while (!exp.eqlZero()) {
        if (exp.isOdd()) out = try fq12Mul(a, out, base, p);
        base = try fq12Square(a, base, p);
        var shifted = try BigInt.init(a);
        try BigInt.shiftRight(&shifted, &exp, 1);
        exp = shifted;
    }
    return out;
}

const Poly13 = [13]BigInt;

fn poly13Zero(a: std.mem.Allocator) !Poly13 {
    var out: Poly13 = undefined;
    for (0..13) |i| out[i] = try biZero(a);
    return out;
}

fn polyDeg(poly: Poly13) usize {
    var i: isize = 12;
    while (i > 0) : (i -= 1) {
        if (!biIsZero(poly[@intCast(i)])) return @intCast(i);
    }
    return 0;
}

fn polyDiv(a: std.mem.Allocator, high_in: Poly13, low: Poly13, p: BigInt) !Poly13 {
    var quotient = try poly13Zero(a);
    var rem = high_in;
    const dl = polyDeg(low);
    if (dl == 0 and biIsZero(low[0])) return quotient;
    const low_lead_inv = try biInvMod(a, low[dl], p);

    while (true) {
        const dr = polyDeg(rem);
        if (dr < dl) break;
        if (dr == 0 and biIsZero(rem[0])) break;

        const idx = dr - dl;
        const coeff = try biMulMod(a, rem[dr], low_lead_inv, p);
        quotient[idx] = coeff;

        var j: usize = 0;
        while (j <= dl) : (j += 1) {
            const term = try biMulMod(a, coeff, low[j], p);
            rem[idx + j] = try biSubMod(a, rem[idx + j], term, p);
        }
    }

    return quotient;
}

fn fq12Inv(a: std.mem.Allocator, x: Fq12, p: BigInt) !Fq12 {
    var lm = try poly13Zero(a);
    var hm = try poly13Zero(a);
    lm[0] = try biOne(a);

    var low = try poly13Zero(a);
    for (0..12) |i| low[i] = x.c[i];

    var high = try poly13Zero(a);
    for (0..12) |i| {
        const coeff = fq12_mod_coeffs[i];
        if (coeff == 0) {
            high[i] = try biZero(a);
        } else {
            high[i] = try biMulSmallMod(a, try biOne(a), coeff, p);
        }
    }
    high[12] = try biOne(a);

    while (polyDeg(low) != 0) {
        const old_lm = lm;
        const old_low = low;
        const r = try polyDiv(a, high, low, p);
        var nm = hm;
        var new_poly = high;

        var i: usize = 0;
        while (i < 13) : (i += 1) {
            var j: usize = 0;
            while (j < 13 - i) : (j += 1) {
                const t1 = try biMulMod(a, lm[i], r[j], p);
                nm[i + j] = try biSubMod(a, nm[i + j], t1, p);
                const t2 = try biMulMod(a, low[i], r[j], p);
                new_poly[i + j] = try biSubMod(a, new_poly[i + j], t2, p);
            }
        }

        lm = nm;
        low = new_poly;
        hm = old_lm;
        high = old_low;
    }

    const inv0 = try biInvMod(a, low[0], p);
    var out: [12]BigInt = undefined;
    for (0..12) |i| out[i] = try biMulMod(a, lm[i], inv0, p);
    return .{ .c = out };
}

fn fq12Div(a: std.mem.Allocator, x: Fq12, y: Fq12, p: BigInt) !Fq12 {
    return try fq12Mul(a, x, try fq12Inv(a, y, p), p);
}

fn g1Inf(a: std.mem.Allocator) !G1 {
    return .{ .x = try biZero(a), .y = try biZero(a), .inf = true };
}

fn g2Inf(a: std.mem.Allocator) !G2 {
    return .{ .x = try fq2Zero(a), .y = try fq2Zero(a), .inf = true };
}

fn g12Inf(a: std.mem.Allocator) !G12 {
    return .{ .x = try fq12Zero(a), .y = try fq12Zero(a), .inf = true };
}

fn g1Neg(a: std.mem.Allocator, p1: G1, p: BigInt) !G1 {
    if (p1.inf) return p1;
    return .{ .x = p1.x, .y = try biSubMod(a, try biZero(a), p1.y, p), .inf = false };
}

fn isOnCurveG1(a: std.mem.Allocator, p1: G1, p: BigInt) !bool {
    if (p1.inf) return true;
    const y2 = try biMulMod(a, p1.y, p1.y, p);
    const x2 = try biMulMod(a, p1.x, p1.x, p);
    const x3 = try biMulMod(a, x2, p1.x, p);
    const rhs = try biAddMod(a, x3, try biFromU64(a, 3), p);
    return biEq(y2, rhs);
}

fn isOnCurveG2(a: std.mem.Allocator, p2: G2, b2: Fq2, p: BigInt) !bool {
    if (p2.inf) return true;
    const y2 = try fq2Square(a, p2.y, p);
    const x2 = try fq2Square(a, p2.x, p);
    const x3 = try fq2Mul(a, x2, p2.x, p);
    const rhs = try fq2Add(a, x3, b2, p);
    return fq2Eq(y2, rhs);
}

fn g1Double(a: std.mem.Allocator, p1: G1, p: BigInt) !G1 {
    if (p1.inf) return p1;
    if (biIsZero(p1.y)) return try g1Inf(a);

    const three_x2 = try biMulSmallMod(a, try biMulMod(a, p1.x, p1.x, p), 3, p);
    const two_y = try biMulSmallMod(a, p1.y, 2, p);
    const m = try biMulMod(a, three_x2, try biInvMod(a, two_y, p), p);
    const x3 = try biSubMod(a, try biSubMod(a, try biMulMod(a, m, m, p), p1.x, p), p1.x, p);
    const y3 = try biSubMod(a, try biMulMod(a, m, try biSubMod(a, p1.x, x3, p), p), p1.y, p);
    return .{ .x = x3, .y = y3, .inf = false };
}

fn g1Add(a: std.mem.Allocator, p1: G1, p2: G1, p: BigInt) !G1 {
    if (p1.inf) return p2;
    if (p2.inf) return p1;

    if (biEq(p1.x, p2.x)) {
        if (biEq(p1.y, p2.y)) return try g1Double(a, p1, p);
        return try g1Inf(a);
    }

    const m = try biMulMod(a, try biSubMod(a, p2.y, p1.y, p), try biInvMod(a, try biSubMod(a, p2.x, p1.x, p), p), p);
    const x3 = try biSubMod(a, try biSubMod(a, try biMulMod(a, m, m, p), p1.x, p), p2.x, p);
    const y3 = try biSubMod(a, try biMulMod(a, m, try biSubMod(a, p1.x, x3, p), p), p1.y, p);
    return .{ .x = x3, .y = y3, .inf = false };
}

fn g2Double(a: std.mem.Allocator, p1: G2, p: BigInt) !G2 {
    if (p1.inf) return p1;
    if (fq2IsZero(p1.y)) return try g2Inf(a);

    const three = try fq2Const(a, 3, 0);
    const two = try fq2Const(a, 2, 0);
    const m = try fq2Mul(a, try fq2Mul(a, three, try fq2Square(a, p1.x, p), p), try fq2Inv(a, try fq2Mul(a, two, p1.y, p), p), p);
    const x3 = try fq2Sub(a, try fq2Sub(a, try fq2Square(a, m, p), p1.x, p), p1.x, p);
    const y3 = try fq2Sub(a, try fq2Mul(a, m, try fq2Sub(a, p1.x, x3, p), p), p1.y, p);
    return .{ .x = x3, .y = y3, .inf = false };
}

fn g2Add(a: std.mem.Allocator, p1: G2, p2: G2, p: BigInt) !G2 {
    if (p1.inf) return p2;
    if (p2.inf) return p1;

    if (fq2Eq(p1.x, p2.x)) {
        if (fq2Eq(p1.y, p2.y)) return try g2Double(a, p1, p);
        return try g2Inf(a);
    }

    const m = try fq2Mul(a, try fq2Sub(a, p2.y, p1.y, p), try fq2Inv(a, try fq2Sub(a, p2.x, p1.x, p), p), p);
    const x3 = try fq2Sub(a, try fq2Sub(a, try fq2Square(a, m, p), p1.x, p), p2.x, p);
    const y3 = try fq2Sub(a, try fq2Mul(a, m, try fq2Sub(a, p1.x, x3, p), p), p1.y, p);
    return .{ .x = x3, .y = y3, .inf = false };
}

fn g2Mul(a: std.mem.Allocator, base: G2, scalar_in: BigInt, p: BigInt) !G2 {
    var n = try biClone(a, scalar_in);
    var addend = base;
    var out = try g2Inf(a);

    while (!n.eqlZero()) {
        if (n.isOdd()) out = try g2Add(a, out, addend, p);
        addend = try g2Double(a, addend, p);
        var shifted = try BigInt.init(a);
        try BigInt.shiftRight(&shifted, &n, 1);
        n = shifted;
    }

    return out;
}

fn g12Double(a: std.mem.Allocator, p1: G12, p: BigInt) !G12 {
    if (p1.inf) return p1;
    const y_is_zero = fq12Eq(p1.y, try fq12Zero(a));
    if (y_is_zero) return try g12Inf(a);

    const three = blk: {
        var v = try fq12Zero(a);
        v.c[0] = try biFromU64(a, 3);
        break :blk v;
    };
    const two = blk: {
        var v = try fq12Zero(a);
        v.c[0] = try biFromU64(a, 2);
        break :blk v;
    };

    const num = try fq12Mul(a, three, try fq12Square(a, p1.x, p), p);
    const den = try fq12Mul(a, two, p1.y, p);
    const den_inv = try fq12Inv(a, den, p);
    const m = try fq12Mul(a, num, den_inv, p);

    const x3 = try fq12Sub(a, try fq12Sub(a, try fq12Square(a, m, p), p1.x, p), p1.x, p);
    const y3 = try fq12Sub(a, try fq12Mul(a, m, try fq12Sub(a, p1.x, x3, p), p), p1.y, p);
    return .{ .x = x3, .y = y3, .inf = false };
}

fn g12Add(a: std.mem.Allocator, p1: G12, p2: G12, p: BigInt) !G12 {
    if (p1.inf) return p2;
    if (p2.inf) return p1;

    if (fq12Eq(p1.x, p2.x)) {
        if (fq12Eq(p1.y, p2.y)) return try g12Double(a, p1, p);
        return try g12Inf(a);
    }

    const num = try fq12Sub(a, p2.y, p1.y, p);
    const den = try fq12Sub(a, p2.x, p1.x, p);
    const den_inv = try fq12Inv(a, den, p);

    const m = try fq12Mul(a, num, den_inv, p);
    const x3 = try fq12Sub(a, try fq12Sub(a, try fq12Square(a, m, p), p1.x, p), p2.x, p);
    const y3 = try fq12Sub(a, try fq12Mul(a, m, try fq12Sub(a, p1.x, x3, p), p), p1.y, p);
    return .{ .x = x3, .y = y3, .inf = false };
}

fn linefunc(a: std.mem.Allocator, p1: G12, p2: G12, t: G12, p: BigInt) !Fq12 {
    if (p1.inf or p2.inf or t.inf) return PairingError.InvalidPoint;

    const x1 = p1.x;
    const y1 = p1.y;
    const x2 = p2.x;
    const y2 = p2.y;
    const xt = t.x;
    const yt = t.y;

    if (!fq12Eq(x1, x2)) {
        const m = try fq12Div(a, try fq12Sub(a, y2, y1, p), try fq12Sub(a, x2, x1, p), p);
        return try fq12Sub(a, try fq12Mul(a, m, try fq12Sub(a, xt, x1, p), p), try fq12Sub(a, yt, y1, p), p);
    } else if (fq12Eq(y1, y2)) {
        const three = blk: {
            var v = try fq12Zero(a);
            v.c[0] = try biFromU64(a, 3);
            break :blk v;
        };
        const two = blk: {
            var v = try fq12Zero(a);
            v.c[0] = try biFromU64(a, 2);
            break :blk v;
        };
        const m = try fq12Div(a, try fq12Mul(a, three, try fq12Square(a, x1, p), p), try fq12Mul(a, two, y1, p), p);
        return try fq12Sub(a, try fq12Mul(a, m, try fq12Sub(a, xt, x1, p), p), try fq12Sub(a, yt, y1, p), p);
    } else {
        return try fq12Sub(a, xt, x1, p);
    }
}

fn castG1ToFq12(a: std.mem.Allocator, p1: G1) !G12 {
    if (p1.inf) return try g12Inf(a);
    var x = try fq12Zero(a);
    var y = try fq12Zero(a);
    x.c[0] = p1.x;
    y.c[0] = p1.y;
    return .{ .x = x, .y = y, .inf = false };
}

fn fq12W(a: std.mem.Allocator) !Fq12 {
    var w = try fq12Zero(a);
    w.c[1] = try biOne(a);
    return w;
}

fn twistG2ToFq12(a: std.mem.Allocator, q: G2, p: BigInt) !G12 {
    if (q.inf) return try g12Inf(a);

    const xcoeff0 = try biSubMod(a, q.x.c0, try biMulSmallMod(a, q.x.c1, 9, p), p);
    const xcoeff1 = q.x.c1;
    const ycoeff0 = try biSubMod(a, q.y.c0, try biMulSmallMod(a, q.y.c1, 9, p), p);
    const ycoeff1 = q.y.c1;

    var nx = try fq12Zero(a);
    var ny = try fq12Zero(a);
    nx.c[0] = xcoeff0;
    nx.c[6] = xcoeff1;
    ny.c[0] = ycoeff0;
    ny.c[6] = ycoeff1;

    const w = try fq12W(a);
    const two = try biFromU64(a, 2);
    const three = try biFromU64(a, 3);
    const w2 = try fq12Pow(a, w, two, p);
    const w3 = try fq12Pow(a, w, three, p);

    return .{
        .x = try fq12Mul(a, nx, w2, p),
        .y = try fq12Mul(a, ny, w3, p),
        .inf = false,
    };
}

fn finalExponent(a: std.mem.Allocator, p: BigInt, q: BigInt) !BigInt {
    var p12 = try biOne(a);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var next = try BigInt.init(a);
        try BigInt.mul(&next, &p12, &p);
        p12 = next;
    }
    var one = try biOne(a);
    var num = try BigInt.init(a);
    try BigInt.sub(&num, &p12, &one);
    var quotient = try BigInt.init(a);
    var rem = try BigInt.init(a);
    try BigInt.divTrunc(&quotient, &rem, &num, &q);
    return quotient;
}

fn millerLoop(a: std.mem.Allocator, q: G12, p_pt: G12, p: BigInt, final_exp: BigInt) !Fq12 {
    if (q.inf or p_pt.inf) return try fq12One(a);

    var r = q;
    var f = try fq12One(a);

    var i: isize = @intCast(log_ate_loop_count);
    while (i >= 0) : (i -= 1) {
        const l_rr = try linefunc(a, r, r, p_pt, p);
        f = try fq12Mul(a, try fq12Square(a, f, p), l_rr, p);
        r = try g12Double(a, r, p);

        const bit: u128 = (@as(u128, 1) << @intCast(i));
        if ((ate_loop_count & bit) != 0) {
            const l_rq = try linefunc(a, r, q, p_pt, p);
            f = try fq12Mul(a, f, l_rq, p);
            r = try g12Add(a, r, q, p);
        }
    }

    const q1 = G12{ .x = try fq12Pow(a, q.x, p, p), .y = try fq12Pow(a, q.y, p, p), .inf = false };
    const nQ2 = G12{
        .x = try fq12Pow(a, q1.x, p, p),
        .y = try fq12Neg(a, try fq12Pow(a, q1.y, p, p), p),
        .inf = false,
    };

    f = try fq12Mul(a, f, try linefunc(a, r, q1, p_pt, p), p);
    r = try g12Add(a, r, q1, p);
    f = try fq12Mul(a, f, try linefunc(a, r, nQ2, p_pt, p), p);

    return try fq12Pow(a, f, final_exp, p);
}

fn pairing(a: std.mem.Allocator, q2: G2, p1: G1, p: BigInt, b2: Fq2, final_exp: BigInt) !Fq12 {
    if (!(try isOnCurveG2(a, q2, b2, p))) return PairingError.InvalidPoint;
    if (!(try isOnCurveG1(a, p1, p))) return PairingError.InvalidPoint;
    const tq = try twistG2ToFq12(a, q2, p);
    const tp = try castG1ToFq12(a, p1);
    return try millerLoop(a, tq, tp, p, final_exp);
}

fn parseG1(a: std.mem.Allocator, bytes: []const u8, p: BigInt) !G1 {
    const x = try biFromBytesBE(a, bytes[0..32]);
    const y = try biFromBytesBE(a, bytes[32..64]);
    if (biIsZero(x) and biIsZero(y)) return try g1Inf(a);
    if (!biLt(x, p) or !biLt(y, p)) return PairingError.InvalidPoint;
    const pt = G1{ .x = x, .y = y, .inf = false };
    if (!(try isOnCurveG1(a, pt, p))) return PairingError.InvalidPoint;
    return pt;
}

fn parseG2(a: std.mem.Allocator, bytes: []const u8, p: BigInt, q: BigInt, b2: Fq2) !G2 {
    const x_im = try biFromBytesBE(a, bytes[0..32]);
    const x_re = try biFromBytesBE(a, bytes[32..64]);
    const y_im = try biFromBytesBE(a, bytes[64..96]);
    const y_re = try biFromBytesBE(a, bytes[96..128]);

    if (!biLt(x_im, p) or !biLt(x_re, p) or !biLt(y_im, p) or !biLt(y_re, p)) return PairingError.InvalidPoint;

    if (biIsZero(x_im) and biIsZero(x_re) and biIsZero(y_im) and biIsZero(y_re)) return try g2Inf(a);

    const pt = G2{
        .x = .{ .c0 = x_re, .c1 = x_im },
        .y = .{ .c0 = y_re, .c1 = y_im },
        .inf = false,
    };

    if (!(try isOnCurveG2(a, pt, b2, p))) return PairingError.InvalidPoint;

    // subgroup check: [q]P == infinity
    const sub = try g2Mul(a, pt, q, p);
    if (!sub.inf) return PairingError.InvalidPoint;

    return pt;
}

pub fn pairingCheck(allocator: std.mem.Allocator, input: []const u8) !bool {
    if (input.len % 192 != 0) return PairingError.InvalidInputLength;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try biFromDecimal(a, field_modulus_dec);
    const q = try biFromDecimal(a, curve_order_dec);

    const b2 = try fq2Div(a, try fq2Const(a, 3, 0), try fq2Const(a, 9, 1), p);
    const final_exp = try finalExponent(a, p, q);

    var acc = try fq12One(a);

    var i: usize = 0;
    while (i < input.len) : (i += 192) {
        const p1 = try parseG1(a, input[i .. i + 64], p);
        const q2 = try parseG2(a, input[i + 64 .. i + 192], p, q, b2);

        if (p1.inf or q2.inf) continue;

        const e = try pairing(a, q2, p1, p, b2, final_exp);
        acc = try fq12Mul(a, acc, e, p);
    }

    return fq12Eq(acc, try fq12One(a));
}
