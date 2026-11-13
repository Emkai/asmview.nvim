local M = {}

local x86_cc = {
    e = "if equal", z = "if zero", ne = "if not equal", nz = "if not zero", eq = "if equal",
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
    p = "if parity", pe = "if parity", ps = "if parity", np = "if no parity", po = "if no parity", pc = "if no parity",
}

local arm_cc = {
    eq = "if equal", ne = "if not equal",
    cs = "if unsigned >=", hs = "if unsigned >=", cc = "if unsigned <", lo = "if unsigned <",
    mi = "if negative", pl = "if not negative", vs = "if overflow", vc = "if no overflow",
    hi = "if unsigned >", ls = "if unsigned <=",
    ge = "if signed >=", lt = "if signed <", gt = "if signed >", le = "if signed <=", al = "always",
}

local bits = { b = "8", w = "16", l = "32", q = "64" }

local fixed = {
    nop = "do nothing (padding)",
    pcalign = "alignment padding",
    leave = "tear down stack frame",
    endbr64 = "valid indirect branch target",
    cltq = "sign-extend eax into rax",
    cdqe = "sign-extend eax into rax",
    cltd = "sign-extend eax into edx:eax",
    cdq = "sign-extend eax into edx:eax",
    cqto = "sign-extend rax into rdx:rax",
    cqo = "sign-extend rax into rdx:rax",
    cwtl = "sign-extend ax into eax",
    ud2 = "trap (unreachable)",
    hlt = "halt",
    lock = "make next instruction atomic",
    dmb = "memory barrier",
    dsb = "wait for memory accesses to finish",
    isb = "flush instruction pipeline",
    cpsid = "disable interrupts",
    cpsie = "enable interrupts",
    wfi = "sleep until interrupt",
    wfe = "sleep until event",
    bkpt = "breakpoint",
    svc = "supervisor call",
    vmrs = "copy fp compare flags to cpu flags",
    tbb = "jump via byte offset table",
    tbh = "jump via halfword offset table",
}

local function t(o)
    return o and o.text or "?"
end

local function opnd(kind, text, extra)
    return vim.tbl_extend("force", { kind = kind, text = text }, extra or {})
end

local function mem(disp, base, idx, scale)
    disp = (disp or ""):gsub("^(%-?%d+)%+(.+)$", "%2+%1")
    local terms = {}
    if base and base ~= "" then
        table.insert(terms, base)
    end
    if idx and idx ~= "" then
        table.insert(terms, idx .. ((scale and scale ~= "" and scale ~= "1") and "*" .. scale or ""))
    end
    local addr = table.concat(terms, "+")
    if disp ~= "" and disp ~= "0" then
        if addr == "" then
            addr = disp
        elseif disp:match("^%-") then
            addr = addr .. disp
        else
            addr = addr .. "+" .. disp
        end
    end
    if addr == "" then
        addr = "0"
    end
    return opnd("mem", "[" .. addr .. "]", { addr = addr, base = base ~= "" and base or nil, global = #terms == 0 })
end

local function att_operand(o)
    o = o:gsub("@%w+", "")
    local c = o:sub(1, 1)
    if c == "*" then
        return opnd("indirect", "address in " .. att_operand(o:sub(2)).text)
    elseif c == "$" then
        local v = o:sub(2)
        return opnd("imm", v:match("^[%a_.]") and "address of " .. v or v)
    elseif c == "%" then
        return opnd("reg", o:sub(2))
    end
    local disp, inner = o:match("^(.-)%((.*)%)$")
    if disp then
        local p = vim.split(inner, ",")
        local base = vim.trim(p[1] or ""):gsub("^%%", "")
        if base == "rip" or base == "eip" then
            base = ""
        end
        return mem(disp, base, vim.trim(p[2] or ""):gsub("^%%", ""), vim.trim(p[3] or ""))
    end
    return opnd("label", o)
end

local function go_operand(o)
    if o:sub(1, 1) == "$" then
        local v = o:sub(2)
        local sym = v:match("^(.-)%(SB%)$")
        return opnd("imm", sym and "address of " .. sym or v)
    end
    local disp, base, rest = o:match("^(.-)%((%w+)%)(.*)$")
    if disp then
        local idx, scale = rest:match("^%((%w+)%*(%d+)%)$")
        if base == "SB" then
            base = ""
        end
        return mem(disp, base, idx, scale)
    end
    if o:match("^%u[%u%d]*$") then
        return opnd("reg", o)
    end
    return opnd("label", o)
end

local arm_regs = { sp = true, lr = true, pc = true, fp = true, ip = true, wzr = true, xzr = true }

local function arm_operand(o)
    local c = o:sub(1, 1)
    if c == "#" then
        return opnd("imm", o:sub(2))
    elseif c == "=" then
        return opnd("literal", o:sub(2))
    elseif c == "{" then
        return opnd("list", (o:sub(2, -2):gsub("%s*,%s*", ", ")))
    elseif c == "[" then
        local wb = o:sub(-1) == "!"
        local inner = o:match("^%[(.*)%]")
        local p = vim.tbl_map(vim.trim, vim.split(inner, ","))
        local addr = p[1]
        for i = 2, #p do
            local sh, n = p[i]:match("^(%a%a%a)%s+#?(%S+)$")
            local v = p[i]:gsub("^#", "")
            if sh then
                addr = addr .. "<<" .. n
            elseif v:match("^%-") then
                addr = addr .. v
            elseif v ~= "0" then
                addr = addr .. "+" .. v
            end
        end
        return opnd("mem", "[" .. addr .. "]", { addr = addr, base = p[1], writeback = wb })
    end
    local lo = o:lower()
    if lo:match("^[rswxdqvh]%d+$") or arm_regs[lo] then
        return opnd("reg", o)
    end
    if o:match("^%-?%d") then
        return opnd("imm", o)
    end
    return opnd("label", o)
end

local function split(s)
    local out, depth, cur = {}, 0, ""
    for ch in s:gmatch(".") do
        if ch:match("[%(%[{]") then
            depth = depth + 1
        elseif ch:match("[%)%]}]") then
            depth = depth - 1
        end
        if ch == "," and depth == 0 then
            table.insert(out, vim.trim(cur))
            cur = ""
        else
            cur = cur .. ch
        end
    end
    if vim.trim(cur) ~= "" then
        table.insert(out, vim.trim(cur))
    end
    return out
end

local function operands(rest, dialect)
    local raw = split(rest)
    local out = {}
    if dialect == "arm" then
        for _, r in ipairs(raw) do
            local sh, n = r:lower():match("^(%a%a%a)%s+#?(%S+)$")
            local sym = ({ lsl = "<<", lsr = ">>", asr = ">>", ror = "ror " })[sh or ""]
            if sym and #out > 0 then
                out[#out].text = "(" .. out[#out].text .. " " .. sym .. " " .. n .. ")"
            else
                table.insert(out, arm_operand(r))
            end
        end
        return out
    end
    local conv = dialect == "go" and go_operand or att_operand
    for i = #raw, 1, -1 do
        table.insert(out, conv(raw[i]))
    end
    return out
end

local function store_in(s, dst, a)
    if dst and a and dst.text ~= a.text then
        return s .. ", store in " .. dst.text
    end
    return s
end

local function binary(verb)
    return function(o, d)
        local dst, a, b = o[1], o[1], o[2]
        if #o >= 3 then
            a, b = o[2], o[3]
        end
        return store_in(verb(t(a), t(b), a, b, d), dst, a)
    end
end

local function bitwise(word)
    return binary(function(a, b, _, _, d)
        if word ~= "and" and a == b and d.zeroing then
            return "set " .. a .. " to 0"
        end
        return "bitwise " .. word .. " " .. a .. " with " .. b
    end)
end

local function unary(verb)
    return function(o)
        if #o == 1 then
            return verb(t(o[1]))
        end
        return verb(t(o[2])) .. ", store in " .. t(o[1])
    end
end

local function size_word(d)
    return d.size and bits[d.size] .. "-bit " or ""
end

local function movlike(o, d)
    local dst, src = o[1], o[2]
    if not src then
        return
    end
    if dst.kind == "mem" then
        return "store " .. (src.kind == "imm" and size_word(d) or "") .. t(src) .. " into " .. t(dst)
    elseif src.kind == "mem" then
        return "load " .. t(src) .. " into " .. t(dst)
    elseif src.kind == "imm" or src.kind == "literal" then
        return "set " .. t(dst) .. " to " .. t(src)
    elseif src.text == dst.text and d.size == "l" then
        return "clear upper 32 bits of " .. t(dst)
    end
    return "copy " .. t(src) .. " into " .. t(dst)
end

local function regs_and_mem(o)
    local regs, m, rest = {}, nil, {}
    for _, x in ipairs(o) do
        if m then
            table.insert(rest, x)
        elseif x.kind == "mem" or x.kind == "literal" or x.kind == "label" then
            m = x
        else
            table.insert(regs, x.text)
        end
    end
    return table.concat(regs, ", "), m, rest
end

local function writeback(m, rest)
    if rest[1] and m and m.base then
        return ", then add " .. rest[1].text .. " to " .. m.base
    elseif m and m.writeback then
        return ", update " .. m.base
    end
    return ""
end

local function load(word)
    return function(o)
        local regs, m, rest = regs_and_mem(o)
        if not m then
            return
        end
        local src = m.kind == "literal" and m.text or m.kind == "label" and "[" .. m.text .. "]" or m.text
        return "load " .. word .. src .. " into " .. regs .. writeback(m, rest)
    end
end

local function store(word)
    return function(o)
        local regs, m, rest = regs_and_mem(o)
        if not m then
            return
        end
        return "store " .. word .. regs .. " into " .. m.text .. writeback(m, rest)
    end
end

local function target(o)
    local x = o[#o]
    if not x then
        return "?"
    end
    if x.kind == "mem" and x.global then
        return x.addr
    end
    if x.kind == "reg" then
        return "address in " .. x.text
    end
    return x.text
end

local function jump(o, d)
    return "jump to " .. target(o) .. (d.cc and " " .. d.cc or "")
end

local function call(o)
    local x = target(o)
    return x:match("^address in") and "call function at " .. x or "call " .. x
end

local function compare(o, d)
    return "compare " .. t(o[1]) .. " with " .. t(o[2])
end

local function test(o)
    if o[2] and o[1].text == o[2].text then
        return "check whether " .. t(o[1]) .. " is 0"
    end
    return "test bits of " .. t(o[1]) .. " against " .. t(o[2])
end

local function extend(kind, from)
    return function(o)
        local dst, src = o[1], o[2]
        local what = kind .. "-extend" .. (from and " " .. from .. "-bit" or "")
        if src.kind == "mem" then
            return "load " .. t(src) .. ", " .. what .. " into " .. t(dst)
        end
        return what .. " " .. t(src) .. " into " .. t(dst)
    end
end

local function convert(from, to)
    return function(o)
        return "convert " .. t(o[2]) .. " from " .. from .. " to " .. to .. ", store in " .. t(o[1])
    end
end

local acc = {
    b = { "al", "ax", "ah" },
    w = { "ax", "dx:ax", "dx" },
    l = { "eax", "edx:eax", "edx" },
    q = { "rax", "rdx:rax", "rdx" },
}

local function reg_size(o)
    local r = o[1] and o[1].kind == "reg" and o[1].text:lower() or ""
    return r:match("^r") and "q" or r:match("^e") and "l" or "q"
end

local function muldiv(kind, signed)
    return function(o, d)
        if #o >= 2 then
            return binary(function(a, b)
                return kind == "mul" and "multiply " .. a .. " by " .. b or "divide " .. a .. " by " .. b
            end)(o, d)
        end
        local r = acc[d.size or reg_size(o)]
        local sign = signed and "signed " or "unsigned "
        if kind == "mul" then
            return sign .. "multiply " .. r[1] .. " by " .. t(o[1]) .. ", result in " .. r[2]
        end
        return sign .. "divide " .. r[2] .. " by " .. t(o[1]) .. ", quotient in " .. r[1] .. ", remainder in " .. r[3]
    end
end

local function stack(push)
    return function(o)
        local list = o[1] and o[1].text or "?"
        if push then
            return "save " .. list .. " on stack"
        end
        local regs = vim.tbl_filter(function(r)
            return r ~= "pc"
        end, vim.split(list, ", "))
        if #regs < #vim.split(list, ", ") then
            return (#regs > 0 and "restore " .. table.concat(regs, ", ") .. " from stack and " or "") .. "return"
        end
        return "restore " .. list .. " from stack"
    end
end

local arith = {
    add = function(a, b) return "add " .. b .. " to " .. a end,
    sub = function(a, b) return "subtract " .. b .. " from " .. a end,
    mul = function(a, b) return "multiply " .. a .. " by " .. b end,
    div = function(a, b) return "divide " .. a .. " by " .. b end,
    min = function(a, b) return "min of " .. a .. " and " .. b end,
    max = function(a, b) return "max of " .. a .. " and " .. b end,
}

local function typed(fn, ty)
    return function(o, d)
        local s = fn(o, d)
        local note = ty or ({ f32 = "float", f64 = "double" })[d.types or ""]
        return s and note and s .. " (" .. note .. ")" or s
    end
end

local T = {
    mov = movlike, movabs = movlike, movd = movlike, vmov = movlike, fmov = movlike,
    movsd = movlike, movss = movlike, movaps = movlike, movapd = movlike, movups = movlike,
    movupd = movlike, movdqa = movlike, movdqu = movlike, movo = movlike, movou = movlike,
    lea = function(o)
        local m = o[2]
        if m and m.kind == "mem" and m.global then
            return "load address of " .. m.addr .. " into " .. t(o[1])
        end
        return "compute " .. (m and m.addr or "?") .. ", store in " .. t(o[1])
    end,
    adr = function(o) return "load address of " .. t(o[2]) .. " into " .. t(o[1]) end,
    adrp = function(o) return "load page address of " .. t(o[2]) .. " into " .. t(o[1]) end,
    add = binary(arith.add),
    sub = binary(arith.sub),
    rsb = binary(function(a, b) return "subtract " .. a .. " from " .. b end),
    adc = binary(function(a, b) return "add " .. b .. " and carry to " .. a end),
    sbb = binary(function(a, b) return "subtract " .. b .. " and borrow from " .. a end),
    sbc = binary(function(a, b) return "subtract " .. b .. " and borrow from " .. a end),
    imul = muldiv("mul", true),
    imul3 = binary(arith.mul),
    mul = muldiv("mul", false),
    idiv = muldiv("div", true),
    div = muldiv("div", false),
    sdiv = binary(function(a, b) return "signed divide " .. a .. " by " .. b end),
    udiv = binary(function(a, b) return "unsigned divide " .. a .. " by " .. b end),
    ["and"] = bitwise("and"),
    ["or"] = bitwise("or"),
    orr = bitwise("or"),
    xor = bitwise("xor"),
    eor = bitwise("xor"),
    pxor = bitwise("xor"),
    xorps = bitwise("xor"),
    xorpd = bitwise("xor"),
    andps = bitwise("and"),
    andpd = bitwise("and"),
    orpd = bitwise("or"),
    andnpd = binary(function(a, b) return "bitwise and not " .. a .. " with " .. b end),
    bic = binary(function(a, b) return "clear bits of " .. a .. " that are set in " .. b end),
    orn = binary(function(a, b) return "bitwise or " .. a .. " with not " .. b end),
    shl = binary(function(a, b) return "shift " .. a .. " left by " .. b end),
    shr = binary(function(a, b) return "shift " .. a .. " right by " .. b end),
    sar = binary(function(a, b) return "shift " .. a .. " right by " .. b .. ", keep sign" end),
    rol = binary(function(a, b) return "rotate " .. a .. " left by " .. b end),
    ror = binary(function(a, b) return "rotate " .. a .. " right by " .. b end),
    inc = unary(function(x) return "add 1 to " .. x end),
    dec = unary(function(x) return "subtract 1 from " .. x end),
    neg = unary(function(x) return "negate " .. x end),
    ["not"] = unary(function(x) return "flip all bits of " .. x end),
    mvn = unary(function(x) return "flip all bits of " .. x end),
    bswap = unary(function(x) return "reverse byte order of " .. x end),
    rev = unary(function(x) return "reverse byte order of " .. x end),
    rbit = unary(function(x) return "reverse bit order of " .. x end),
    clz = unary(function(x) return "count leading zeros of " .. x end),
    lzcnt = unary(function(x) return "count leading zeros of " .. x end),
    tzcnt = unary(function(x) return "count trailing zeros of " .. x end),
    popcnt = unary(function(x) return "count set bits of " .. x end),
    bsf = unary(function(x) return "find lowest set bit of " .. x end),
    bsr = unary(function(x) return "find highest set bit of " .. x end),
    cmp = compare,
    cmn = function(o) return "compare " .. t(o[1]) .. " with -" .. t(o[2]) end,
    test = test,
    tst = test,
    teq = function(o) return "check whether " .. t(o[1]) .. " equals " .. t(o[2]) end,
    bt = function(o) return "copy bit " .. t(o[2]) .. " of " .. t(o[1]) .. " into carry flag" end,
    jmp = jump,
    j = jump,
    b = jump,
    br = jump,
    call = call,
    bl = call,
    blx = call,
    blr = call,
    ret = function() return "return" end,
    bx = function(o)
        local r = t(o[1]):lower()
        return r == "lr" and "return" or "jump to address in " .. t(o[1])
    end,
    cbz = function(o) return "jump to " .. t(o[2]) .. " if " .. t(o[1]) .. " is 0" end,
    cbnz = function(o) return "jump to " .. t(o[2]) .. " if " .. t(o[1]) .. " is not 0" end,
    tbz = function(o) return "jump to " .. t(o[3]) .. " if bit " .. t(o[2]) .. " of " .. t(o[1]) .. " is 0" end,
    tbnz = function(o) return "jump to " .. t(o[3]) .. " if bit " .. t(o[2]) .. " of " .. t(o[1]) .. " is 1" end,
    set = function(o, d) return "set " .. t(o[1]) .. " to 1 " .. d.cc .. ", else 0" end,
    cmov = function(o, d) return "copy " .. t(o[2]) .. " into " .. t(o[1]) .. " " .. d.cc end,
    cset = function(o) return "set " .. t(o[1]) .. " to 1 " .. (arm_cc[t(o[2]):lower()] or t(o[2])) .. ", else 0" end,
    csel = function(o)
        return "set " .. t(o[1]) .. " to " .. t(o[2]) .. " " .. (arm_cc[t(o[4]):lower()] or t(o[4])) .. ", else " .. t(o[3])
    end,
    push = function(o) return o[1] and o[1].kind == "list" and stack(true)(o) or "push " .. t(o[1]) .. " onto stack" end,
    pop = function(o) return o[1] and o[1].kind == "list" and stack(false)(o) or "pop stack into " .. t(o[1]) end,
    vpush = stack(true),
    vpop = stack(false),
    xchg = function(o) return "swap " .. t(o[1]) .. " and " .. t(o[2]) end,
    cmpxchg = function(o) return "if accumulator equals " .. t(o[1]) .. ", store " .. t(o[2]) .. " into it" end,
    xadd = function(o) return "add " .. t(o[2]) .. " to " .. t(o[1]) .. ", old value into " .. t(o[2]) end,
    movzx = extend("zero"),
    movsx = extend("sign"),
    movsxd = extend("sign", "32"),
    uxtb = extend("zero", "8"),
    uxth = extend("zero", "16"),
    sxtb = extend("sign", "8"),
    sxth = extend("sign", "16"),
    movx = function(o, d) return extend(d.kind, d.from)(o) .. " (" .. d.to .. "-bit)" end,
    movw = function(o) return "set " .. t(o[1]) .. " to " .. t(o[2]) end,
    movt = function(o) return "set top 16 bits of " .. t(o[1]) .. " to " .. t(o[2]) end,
    movk = function(o) return "set 16 bits of " .. t(o[1]) .. " to " .. t(o[2]) end,
    mla = function(o) return "multiply " .. t(o[2]) .. " by " .. t(o[3]) .. ", add " .. t(o[4]) .. ", store in " .. t(o[1]) end,
    madd = function(o) return "multiply " .. t(o[2]) .. " by " .. t(o[3]) .. ", add " .. t(o[4]) .. ", store in " .. t(o[1]) end,
    mls = function(o) return "subtract " .. t(o[2]) .. "*" .. t(o[3]) .. " from " .. t(o[4]) .. ", store in " .. t(o[1]) end,
    msub = function(o) return "subtract " .. t(o[2]) .. "*" .. t(o[3]) .. " from " .. t(o[4]) .. ", store in " .. t(o[1]) end,
    umull = function(o) return "unsigned multiply " .. t(o[3]) .. " by " .. t(o[4]) .. ", 64-bit result in " .. t(o[2]) .. ":" .. t(o[1]) end,
    smull = function(o) return "signed multiply " .. t(o[3]) .. " by " .. t(o[4]) .. ", 64-bit result in " .. t(o[2]) .. ":" .. t(o[1]) end,
    umlal = function(o) return "unsigned multiply " .. t(o[3]) .. " by " .. t(o[4]) .. ", add to " .. t(o[2]) .. ":" .. t(o[1]) end,
    smlal = function(o) return "signed multiply " .. t(o[3]) .. " by " .. t(o[4]) .. ", add to " .. t(o[2]) .. ":" .. t(o[1]) end,
    lsl = binary(function(a, b) return "shift " .. a .. " left by " .. b end),
    lsr = binary(function(a, b) return "shift " .. a .. " right by " .. b end),
    asr = binary(function(a, b) return "shift " .. a .. " right by " .. b .. ", keep sign" end),
    ubfx = function(o) return "extract " .. t(o[4]) .. " bits of " .. t(o[2]) .. " from bit " .. t(o[3]) .. " into " .. t(o[1]) end,
    sbfx = function(o) return "extract signed " .. t(o[4]) .. " bits of " .. t(o[2]) .. " from bit " .. t(o[3]) .. " into " .. t(o[1]) end,
    bfi = function(o) return "insert low " .. t(o[4]) .. " bits of " .. t(o[2]) .. " into " .. t(o[1]) .. " at bit " .. t(o[3]) end,
    bfc = function(o) return "clear " .. t(o[3]) .. " bits of " .. t(o[1]) .. " from bit " .. t(o[2]) end,
    usat = function(o) return "clamp " .. t(o[3]) .. " to unsigned " .. t(o[2]) .. "-bit, store in " .. t(o[1]) end,
    ssat = function(o) return "clamp " .. t(o[3]) .. " to signed " .. t(o[2]) .. "-bit, store in " .. t(o[1]) end,
    ldr = load(""), ldur = load(""), vldr = load(""), ldrex = load(""), ldrd = load(""), ldp = load(""),
    ldrb = load("byte "), ldrh = load("halfword "), ldrsb = load("signed byte "), ldrsh = load("signed halfword "),
    str = store(""), stur = store(""), vstr = store(""), strd = store(""), stp = store(""),
    strb = store("byte "), strh = store("halfword "),
    strex = function(o) return "try store " .. t(o[2]) .. " into " .. t(o[3]) .. ", status in " .. t(o[1]) end,
    ldm = function(o) return "load " .. t(o[2]) .. " from [" .. t(o[1]):gsub("!$", "") .. "]" end,
    stm = function(o) return "store " .. t(o[2]) .. " to [" .. t(o[1]):gsub("!$", "") .. "]" end,
    vldm = function(o) return "load " .. t(o[2]) .. " from [" .. t(o[1]):gsub("!$", "") .. "]" end,
    vstm = function(o) return "store " .. t(o[2]) .. " to [" .. t(o[1]):gsub("!$", "") .. "]" end,
    addsd = typed(binary(arith.add), "double"), subsd = typed(binary(arith.sub), "double"),
    mulsd = typed(binary(arith.mul), "double"), divsd = typed(binary(arith.div), "double"),
    minsd = typed(binary(arith.min), "double"), maxsd = typed(binary(arith.max), "double"),
    addss = typed(binary(arith.add), "float"), subss = typed(binary(arith.sub), "float"),
    mulss = typed(binary(arith.mul), "float"), divss = typed(binary(arith.div), "float"),
    minss = typed(binary(arith.min), "float"), maxss = typed(binary(arith.max), "float"),
    vadd = typed(binary(arith.add)), vsub = typed(binary(arith.sub)),
    vmul = typed(binary(arith.mul)), vdiv = typed(binary(arith.div)),
    fadd = binary(arith.add), fsub = binary(arith.sub), fmul = binary(arith.mul), fdiv = binary(arith.div),
    vneg = typed(unary(function(x) return "negate " .. x end)),
    vabs = typed(unary(function(x) return "absolute value of " .. x end)),
    vsqrt = typed(unary(function(x) return "square root of " .. x end)),
    sqrtsd = typed(unary(function(x) return "square root of " .. x end), "double"),
    sqrtss = typed(unary(function(x) return "square root of " .. x end), "float"),
    vmla = typed(function(o) return "multiply " .. t(o[2]) .. " by " .. t(o[3]) .. ", add to " .. t(o[1]) end),
    vmls = typed(function(o) return "multiply " .. t(o[2]) .. " by " .. t(o[3]) .. ", subtract from " .. t(o[1]) end),
    vfma = typed(function(o) return "multiply " .. t(o[2]) .. " by " .. t(o[3]) .. ", add to " .. t(o[1]) .. " (fused)" end),
    vfms = typed(function(o) return "multiply " .. t(o[2]) .. " by " .. t(o[3]) .. ", subtract from " .. t(o[1]) .. " (fused)" end),
    ucomisd = typed(compare, "double"), comisd = typed(compare, "double"),
    ucomiss = typed(compare, "float"), comiss = typed(compare, "float"),
    vcmp = typed(compare), vcmpe = typed(compare), fcmp = compare,
    vcvt = function(o, d)
        local to, from = (d.types or ""):match("^(%w+)%.(%w+)$")
        return "convert " .. t(o[2]) .. " from " .. (from or "?") .. " to " .. (to or "?") .. ", store in " .. t(o[1])
    end,
    cvtsi2sd = convert("int", "double"), cvtsi2ss = convert("int", "float"),
    cvtsq2sd = convert("int64", "double"), cvtsl2sd = convert("int32", "double"),
    cvtsq2ss = convert("int64", "float"), cvtsl2ss = convert("int32", "float"),
    cvttsd2si = convert("double", "int (truncate)"), cvttss2si = convert("float", "int (truncate)"),
    cvtsd2si = convert("double", "int (round)"), cvtss2si = convert("float", "int (round)"),
    cvttsd2sq = convert("double", "int64 (truncate)"), cvttsd2sl = convert("double", "int32 (truncate)"),
    cvttss2sq = convert("float", "int64 (truncate)"), cvttss2sl = convert("float", "int32 (truncate)"),
    cvtsd2ss = convert("double", "float"), cvtss2sd = convert("float", "double"),
    scvtf = convert("signed int", "float"), ucvtf = convert("unsigned int", "float"),
    fcvtzs = convert("float", "signed int (truncate)"), fcvtzu = convert("float", "unsigned int (truncate)"),
}

local function known(name)
    return T[name] or fixed[name]
end

local function decode_x86(op)
    if known(op) then
        return { name = op }
    end
    for _, prefix in ipairs({ "j", "set", "cmov" }) do
        local rest = op:match("^" .. prefix .. "(.+)$")
        if rest then
            local size
            if prefix == "cmov" then
                size, rest = rest:match("^([wlq]?)(.+)$")
            end
            if x86_cc[rest] then
                return { name = prefix, cc = x86_cc[rest], size = size ~= "" and size or nil }
            end
        end
    end
    local kind, from, to = op:match("^mov([sz])([bwl])([wlq])$")
    if not kind then
        from, to, kind = op:match("^mov([bwlq])([bwlq])([sz])x$")
    end
    if kind then
        return { name = "movx", kind = kind == "z" and "zero" or "sign", from = bits[from], to = bits[to] }
    end
    local base, size = op:match("^(.+)([bwlq])$")
    if base and known(base) then
        return { name = base, size = size }
    end
end

local function decode_arm(base, suffix)
    if base:match("^it[te]*$") then
        return { name = "it", n = #base - 1 }
    end
    local types = not suffix:match("^[nw]?$") and suffix or nil
    if base == "b" and arm_cc[suffix] then
        return { name = "b", cc = arm_cc[suffix] }
    end
    if known(base) then
        return { name = base, types = types }
    end
    local function try(name)
        if known(name) then
            return { name = name, types = types }
        end
        local stem = name:match("^(.+)s$")
        if stem and known(stem) then
            return { name = stem, types = types, flags = true }
        end
    end
    local stem, cc = base:match("^(.+)(%a%a)$")
    if stem and arm_cc[cc] then
        local d = try(stem)
        if d then
            d.cc = arm_cc[cc]
            return d
        end
    end
    return try(base)
end

local zeroing = { xor = true, eor = true, pxor = true, xorps = true, xorpd = true }

function M.dialect(lines)
    for _, l in ipairs(lines) do
        if l:find("%", 1, true) then
            return "att"
        end
    end
    return "arm"
end

function M.line(text, dialect)
    local s = vim.trim(text):gsub("^%d+%s+", "")
    if s == "" or s:match(":$") then
        return nil
    end
    local op, rest = s:match("^(%S+)%s*(.*)$")
    if not op then
        return nil
    end
    op = op:lower()
    if (op == "lock" or op == "rep" or op == "notrack") and rest ~= "" then
        local inner = M.line(rest, dialect)
        return inner and (op == "lock" and "atomically " or "") .. inner or fixed.lock
    end
    local d
    if dialect == "arm" then
        local base, suffix = op:match("^([^.]+)%.?(.*)$")
        d = decode_arm(base, suffix)
        if d and d.name == "it" then
            return "next " .. d.n .. " instr run " .. (arm_cc[rest:lower()] or rest) .. " (if-then)"
        end
    else
        d = decode_x86(op) or decode_arm(op:match("^([^.]+)%.?(.*)$"))
    end
    if not d then
        return nil
    end
    if fixed[d.name] then
        return fixed[d.name]
    end
    d.zeroing = zeroing[d.name]
    local ok, out = pcall(T[d.name], operands(rest, dialect), d)
    if not ok or not out then
        return nil
    end
    if d.cc and d.name ~= "b" and d.name ~= "j" and d.name ~= "set" and d.name ~= "cmov" then
        out = out .. " " .. d.cc
    end
    if d.flags then
        out = out .. ", set flags"
    end
    return out
end

return M
