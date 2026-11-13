local M = {}

local ops = {
    mov = "copy value",
    movabs = "copy 64-bit immediate",
    lea = "compute address, no memory access",
    add = "add",
    sub = "subtract",
    adc = "add with carry",
    sbb = "subtract with borrow",
    imul = "signed multiply",
    imul3 = "signed multiply",
    mul = "multiply",
    idiv = "signed divide",
    div = "unsigned divide",
    neg = "negate",
    ["not"] = "bitwise not",
    inc = "add 1",
    dec = "subtract 1",
    ["and"] = "bitwise and",
    ["or"] = "bitwise or",
    xor = "bitwise xor",
    shl = "shift left",
    sal = "shift left",
    shr = "logical shift right",
    sar = "arithmetic shift right (keeps sign)",
    rol = "rotate left",
    ror = "rotate right",
    cmp = "compare, sets flags",
    test = "bitwise and, sets flags only",
    bt = "test bit, sets carry",
    call = "call function",
    ret = "return",
    jmp = "jump",
    push = "push onto stack",
    pop = "pop from stack",
    nop = "do nothing (padding)",
    leave = "tear down stack frame",
    endbr64 = "valid indirect branch target",
    cltq = "sign-extend eax to rax",
    cdqe = "sign-extend eax to rax",
    cltd = "sign-extend eax into edx:eax",
    cqto = "sign-extend rax into rdx:rax",
    cwtl = "sign-extend ax to eax",
    xchg = "swap values",
    cmpxchg = "compare and swap",
    xadd = "exchange and add",
    lock = "make next instruction atomic",
    bswap = "reverse byte order",
    bsf = "index of lowest set bit",
    bsr = "index of highest set bit",
    popcnt = "count set bits",
    lzcnt = "count leading zeros",
    tzcnt = "count trailing zeros",
    ud2 = "trap (unreachable)",
    hlt = "halt",
    movzx = "zero-extend",
    movsx = "sign-extend",
    movsxd = "sign-extend 32 to 64-bit",
    movsd = "copy double",
    movss = "copy float",
    movaps = "copy 128-bit",
    movapd = "copy 128-bit",
    movups = "copy 128-bit",
    movupd = "copy 128-bit",
    movdqa = "copy 128-bit",
    movdqu = "copy 128-bit",
    movo = "copy 128-bit",
    movou = "copy 128-bit",
    addsd = "add doubles",
    subsd = "subtract doubles",
    mulsd = "multiply doubles",
    divsd = "divide doubles",
    sqrtsd = "square root of double",
    minsd = "min of doubles",
    maxsd = "max of doubles",
    addss = "add floats",
    subss = "subtract floats",
    mulss = "multiply floats",
    divss = "divide floats",
    sqrtss = "square root of float",
    minss = "min of floats",
    maxss = "max of floats",
    ucomisd = "compare doubles, sets flags",
    comisd = "compare doubles, sets flags",
    ucomiss = "compare floats, sets flags",
    comiss = "compare floats, sets flags",
    cvtsi2sd = "int to double",
    cvtsi2ss = "int to float",
    cvttsd2si = "double to int (truncate)",
    cvttss2si = "float to int (truncate)",
    cvtsd2si = "double to int (round)",
    cvtss2si = "float to int (round)",
    cvtsd2ss = "double to float",
    cvtss2sd = "float to double",
    cvtsq2sd = "int64 to double",
    cvtsl2sd = "int32 to double",
    cvtsq2ss = "int64 to float",
    cvtsl2ss = "int32 to float",
    cvttsd2sq = "double to int64 (truncate)",
    cvttsd2sl = "double to int32 (truncate)",
    cvttss2sq = "float to int64 (truncate)",
    cvttss2sl = "float to int32 (truncate)",
    pxor = "bitwise xor 128-bit (often zeroing)",
    xorps = "bitwise xor 128-bit (often zeroing)",
    xorpd = "bitwise xor 128-bit (often zeroing)",
    andps = "bitwise and 128-bit",
    andpd = "bitwise and 128-bit",
    andnpd = "bitwise and-not 128-bit",
    orpd = "bitwise or 128-bit",

    ldr = "load 32-bit",
    ldrb = "load 8-bit, zero-extend",
    ldrh = "load 16-bit, zero-extend",
    ldrsb = "load 8-bit, sign-extend",
    ldrsh = "load 16-bit, sign-extend",
    ldrd = "load two words",
    ldur = "load (unscaled offset)",
    str = "store 32-bit",
    strb = "store 8-bit",
    strh = "store 16-bit",
    strd = "store two words",
    stur = "store (unscaled offset)",
    ldp = "load pair",
    stp = "store pair",
    ldm = "load multiple",
    ldmia = "load multiple",
    ldmdb = "load multiple (decrement before)",
    stm = "store multiple",
    stmia = "store multiple",
    stmdb = "store multiple (decrement before)",
    ldrex = "load exclusive (atomic start)",
    strex = "store exclusive (atomic end)",
    b = "branch",
    bl = "call function",
    bx = "branch to register (return if lr)",
    blx = "call via register",
    br = "branch to register",
    blr = "call via register",
    cbz = "branch if zero",
    cbnz = "branch if not zero",
    tbz = "branch if bit is zero",
    tbnz = "branch if bit is set",
    tbb = "jump table (byte offsets)",
    tbh = "jump table (halfword offsets)",
    rsb = "reverse subtract",
    sbc = "subtract with carry",
    mla = "multiply-add",
    mls = "multiply-subtract",
    madd = "multiply-add",
    msub = "multiply-subtract",
    umull = "unsigned 32x32 to 64-bit multiply",
    smull = "signed 32x32 to 64-bit multiply",
    umlal = "unsigned 64-bit multiply-accumulate",
    smlal = "signed 64-bit multiply-accumulate",
    udiv = "unsigned divide",
    sdiv = "signed divide",
    lsl = "shift left",
    lsr = "logical shift right",
    asr = "arithmetic shift right (keeps sign)",
    orr = "bitwise or",
    eor = "bitwise xor",
    bic = "bit clear (and not)",
    orn = "bitwise or-not",
    mvn = "bitwise not",
    movw = "load low 16 bits",
    movt = "set high 16 bits",
    movd = "copy value",
    cmn = "compare with negative, sets flags",
    tst = "bitwise and, sets flags only",
    teq = "bitwise xor, sets flags only",
    ubfx = "extract unsigned bitfield",
    sbfx = "extract signed bitfield",
    bfi = "insert bitfield",
    bfc = "clear bitfield",
    uxtb = "zero-extend 8-bit",
    uxth = "zero-extend 16-bit",
    sxtb = "sign-extend 8-bit",
    sxth = "sign-extend 16-bit",
    clz = "count leading zeros",
    rev = "reverse byte order",
    rbit = "reverse bit order",
    adr = "load address",
    adrp = "load address of 4KB page",
    csel = "conditional select",
    cset = "set 1 if condition, else 0",
    usat = "unsigned saturate",
    ssat = "signed saturate",
    dmb = "memory barrier",
    dsb = "data sync barrier",
    isb = "instruction sync barrier",
    cpsid = "disable interrupts",
    cpsie = "enable interrupts",
    wfi = "wait for interrupt",
    svc = "supervisor call",
    bkpt = "breakpoint",
    vldr = "load fp register",
    vstr = "store fp register",
    vmov = "copy fp value",
    vadd = "fp add",
    vsub = "fp subtract",
    vmul = "fp multiply",
    vdiv = "fp divide",
    vneg = "fp negate",
    vabs = "fp absolute value",
    vsqrt = "fp square root",
    vcmp = "fp compare",
    vcmpe = "fp compare",
    vmrs = "copy fp flags to cpu flags",
    vcvt = "fp convert",
    vmla = "fp multiply-add",
    vmls = "fp multiply-subtract",
    vfma = "fp fused multiply-add",
    vfms = "fp fused multiply-subtract",
    vpush = "push fp registers",
    vpop = "pop fp registers",
    vldm = "load multiple fp registers",
    vstm = "store multiple fp registers",
}

local x86_cc = {
    e = "if equal", z = "if zero", ne = "if not equal", nz = "if not zero",
    eq = "if equal",
    a = "if unsigned >", nbe = "if unsigned >", hi = "if unsigned >",
    ae = "if unsigned >=", nb = "if unsigned >=", nc = "if unsigned >=", cc = "if unsigned >=",
    b = "if unsigned <", nae = "if unsigned <", c = "if unsigned <", cs = "if unsigned <",
    be = "if unsigned <=", na = "if unsigned <=", ls = "if unsigned <=",
    g = "if signed >", nle = "if signed >", gt = "if signed >",
    ge = "if signed >=", nl = "if signed >=",
    l = "if signed <", nge = "if signed <", lt = "if signed <",
    le = "if signed <=", ng = "if signed <=",
    s = "if negative", mi = "if negative", ns = "if not negative", pl = "if not negative",
    o = "if overflow", os = "if overflow", no = "if no overflow", oc = "if no overflow",
    p = "if parity", pe = "if parity", ps = "if parity",
    np = "if no parity", po = "if no parity", pc = "if no parity",
}

local arm_cc = {
    eq = "if equal", ne = "if not equal",
    cs = "if unsigned >=", hs = "if unsigned >=", cc = "if unsigned <", lo = "if unsigned <",
    mi = "if negative", pl = "if not negative", vs = "if overflow", vc = "if no overflow",
    hi = "if unsigned >", ls = "if unsigned <=",
    ge = "if signed >=", lt = "if signed <", gt = "if signed >", le = "if signed <=",
    al = "always",
}

local x86_size = { b = "8-bit", w = "16-bit", l = "32-bit", q = "64-bit" }
local bits = { b = "8", w = "16", l = "32", q = "64" }

local function join(...)
    return table.concat(vim.tbl_filter(function(s)
        return s and s ~= ""
    end, { ... }), ", ")
end

local function x86(op)
    for _, prefix in ipairs({ "j", "set", "cmov" }) do
        local rest = op:match("^" .. prefix .. "(.+)$")
        if rest then
            local size
            if prefix == "cmov" then
                size, rest = rest:match("^([wlq]?)(.+)$")
            end
            if x86_cc[rest] then
                local what = ({ j = "jump", set = "set 1", cmov = "copy" })[prefix]
                return join(what .. " " .. x86_cc[rest], x86_size[size])
            end
        end
    end
    local kind, from, to = op:match("^mov([sz])([bwl])([wlq])$")
    if not kind then
        from, to, kind = op:match("^mov([bwlq])([bwlq])([sz])x$")
    end
    if kind then
        return (kind == "z" and "zero" or "sign") .. "-extend " .. bits[from] .. " to " .. bits[to] .. "-bit"
    end
    local base, size = op:match("^(.+)([bwlq])$")
    if base and ops[base] then
        return join(ops[base], x86_size[size])
    end
end

local function arm(base, suffix)
    if base:match("^it[te]*$") then
        return "if-then: next " .. #base - 1 .. " instr conditional"
    end
    if base == "b" and arm_cc[suffix] then
        return "branch " .. arm_cc[suffix]
    end
    local function try(name)
        if ops[name] then
            return ops[name]
        end
        local stem = name:match("^(.+)s$")
        if stem and ops[stem] then
            return join(ops[stem], "sets flags")
        end
    end
    local stem, cc = base:match("^(.+)(%a%a)$")
    if stem and arm_cc[cc] then
        local d = try(stem)
        if d then
            return d .. " " .. arm_cc[cc]
        end
    end
    return try(base)
end

function M.line(text)
    local s = vim.trim(text):gsub("^%d+%s+", "")
    if s == "" or s:match(":$") then
        return
    end
    local op = s:match("^%S+")
    if not op then
        return
    end
    op = op:lower()
    local base, suffix = op:match("^([^.]+)%.?(.*)$")
    if base == "b" and arm_cc[suffix] then
        return "branch " .. arm_cc[suffix]
    end
    if base == "vcvt" then
        local to, from = suffix:match("^(%w+)%.(%w+)$")
        if to then
            return "fp convert " .. from .. " to " .. to
        end
    end
    if base == "pop" and s:lower():match("pc%s*}") then
        return "pop from stack and return"
    end
    if ops[base] then
        local types = suffix:match("^[nw]$") and "" or suffix:gsub("%.", " ")
        return join(ops[base], types)
    end
    return x86(base) or arm(base, suffix)
end

return M
