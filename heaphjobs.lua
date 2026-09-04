--[[
    heaphjobs, the Heaph Point Board in game.

    The website (heaphpoints.com) condensed into one parchment window:
    Heaph Jobs (claim them), Public Jobs (help wanted, services, post your
    own, close your own), Ask Heaph (pitch a points event, request points),
    a search box, and an Account tab for your in-game key.

    Reading needs nothing. Claiming, posting and asking need the key.

    /heaphjobs               show or hide the window (/jobs and /pjobs work too)
    /heaphjobs refresh       fetch the board now
    /heaphjobs key <key>     set your in-game key (made on the website, Account tab)
    /heaphjobs alpha 0.8     board background opacity
    /heaphjobs size 900 700  board size
    /heaphjobs mogsize 72    sleeping moogle size
    /heaphjobs mogalpha 0.8  sleeping moogle opacity
    /heaphjobs reset         defaults, and bring everything back on screen
    /heaphjobs help

    Creation assisted by ADA. X-32 keeps the ledger.
]]
addon.name    = 'heaphjobs';
addon.author  = 'Heaph, with ADA';
addon.version = '2.1.2';
addon.desc    = "Heaph's Harem point board, in game.";
addon.link    = 'https://heaphpoints.com';

require 'common';
local chat     = require 'chat';
local imgui    = require 'imgui';
local json     = require 'json';
local settings = require 'settings';
local ffi      = require 'ffi';
local d3d      = require 'd3d8';
local socket   = require('socket');
local ssl      = require('socket.ssl');
local C        = ffi.C;
local d3d8dev  = d3d.get_device();

local HOST         = 'heaphpoints.com';
local REFRESH_SECS = 120;
local MAX_REPLY    = 2 * 1024 * 1024;   -- nobody's job board is two megabytes
local CA_FILE      = addon.path .. '/assets/cacert.pem';

-- server-side limits, mirrored so the boxes stop where the site would cut
local LIM = { title = 80, detail = 600, note = 1000, helper = 20, when = 24, key = 48, search = 60 };

local defaults = T{ visible = true, key = '', alpha = 0.95, w = 1000, h = 780, locked = false, mogsize = 72, mogalpha = 1.0 };
local st = T{
    settings = settings.load(defaults),
    data     = nil,     -- /api/board
    me       = nil,     -- /api/me member, when a key is set and accepted
    key_bad  = false,   -- the key was refused or revoked
    err      = nil,     -- last board fetch error
    fetched  = 0,       -- os.time() of the last fetch request
    loaded   = os.time(),
    tex      = T{},
    msg      = nil,     -- { text, good, at }
    search   = T{ '' },
    ui       = T{},     -- input buffers and per-card state
};

-- ---------------------------------------------------------------- palette (the website's :root)
local function rgb(hex, a)
    return { bit.rshift(hex, 16) / 255, bit.band(bit.rshift(hex, 8), 0xFF) / 255, bit.band(hex, 0xFF) / 255, a or 1 };
end
local PAL = {
    paper = rgb(0xEFE4CE), paper2 = rgb(0xE6D8BC), ink = rgb(0x2F2417), ink2 = rgb(0x5D4A30), soft = rgb(0x7A6238),
    brown = rgb(0x6F5331), line = rgb(0xB89C72), gold = rgb(0xBA9050), gold2 = rgb(0xDEC28A), gold3 = rgb(0x8A6A34),
    navy = rgb(0x26324F), navy2 = rgb(0x3B5374), red = rgb(0x8F3120), green = rgb(0x3D6B3F), amber = rgb(0x96702A),
    cream = rgb(0xF2E4C2),
};
local function u32(c) return imgui.GetColorU32(c); end
local function say(text, good) st.msg = { text = tostring(text), good = good, at = os.time() }; end
local function S(v) return tostring(v == nil and '' or v); end
local function N(v) return tonumber(v) or 0; end
-- points can be halves; print 2.5 as 2.5 and 60 as 60
local function pts(v) local n = N(v); if (n == math.floor(n)) then return ('%d'):format(n); end return ('%.1f'):format(n); end

-- buttons keep the site's look: cream lettering on navy, gold when pressed
local function btn(label, size)
    imgui.PushStyleColor(ImGuiCol_Text, PAL.cream);
    local r = size and imgui.Button(label, size) or imgui.Button(label);
    imgui.PopStyleColor();
    return r;
end
local function sbtn(label)
    imgui.PushStyleColor(ImGuiCol_Text, PAL.cream);
    local r = imgui.SmallButton(label);
    imgui.PopStyleColor();
    return r;
end
local function tip(text) if (imgui.IsItemHovered()) then imgui.SetTooltip(text); end end

-- ---------------------------------------------------------------- textures
local function load_texture(name)
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileA(d3d8dev, string.format('%s/assets/%s', addon.path, name), ptr);
    if (res ~= C.S_OK) then return nil; end
    local t = ffi.new('IDirect3DTexture8*', ptr[0]);
    d3d.gc_safe_release(t);
    return t;
end
local function tex_id(t) return tonumber(ffi.cast('uint32_t', t)); end

pcall(ffi.cdef, [[ int16_t GetKeyState(int32_t vkey); ]]);
local function shift_held()
    local ok, r = pcall(function () return bit.band(ffi.C.GetKeyState(0x10), 0x8000) ~= 0; end);
    return ok and r;
end

local function file_exists(p) local f = io.open(p, 'rb'); if (f) then f:close(); return true; end return false; end

-- ---------------------------------------------------------------- HTTPS, non-blocking, one request at a time
-- LuaSocket + LuaSec, both bundled with Ashita, driven from a coroutine that
-- advances a few small steps per frame and yields. The game never waits on
-- the network. The board's certificate is checked against the bundled CA
-- file and the name on it must be ours, so the key only ever goes to Heaph.
local queue, current = {}, nil;
local dns = { ip = nil, at = 0 };
local resize_to, reposition_to = nil, nil;

-- one lookup per hour, cached, because getaddrinfo does not yield
local function resolve()
    if (dns.ip and os.time() - dns.at < 3600) then return dns.ip; end
    local ip = socket.dns.toip(HOST);
    if (not ip) then error('could not look up ' .. HOST); end
    dns.ip, dns.at = ip, os.time();
    return ip;
end

local function dechunk(body)
    local out, pos, done = {}, 1, false;
    while true do
        local s, e, hex = body:find('^%s*(%x+)[^\r\n]*\r\n', pos);
        if (not s) then break; end
        local n = tonumber(hex, 16);
        if (n == nil) then break; end
        if (n == 0) then done = true; break; end
        out[#out + 1] = body:sub(e + 1, e + n);
        pos = e + n + 3;
    end
    if (not done) then return nil; end
    return table.concat(out);
end

-- the certificate must carry our host name; chain validity alone would accept any real site.
-- LuaSec returns extensions keyed by name; older builds return a list. Both are read.
local function name_ok(alt)
    return alt == HOST or alt == '*.' .. HOST;
end
local function check_name(s)
    local cert = s:getpeercertificate();
    if (not cert) then error('tls: no certificate'); end
    local found = false;
    local exts = cert:extensions() or {};
    for k, ext in pairs(exts) do
        if (type(ext) == 'table' and (k == 'subjectAltName' or ext.name == 'subjectAltName' or ext.oid == '2.5.29.17')) then
            for _, alt in ipairs(ext.dNSName or {}) do
                if (name_ok(alt)) then found = true; end
            end
            if (not found) then
                for _, v in pairs(ext) do
                    if (type(v) == 'table') then for _, alt in ipairs(v) do if (name_ok(alt)) then found = true; end end
                    elseif (type(v) == 'string' and name_ok(v)) then found = true; end
                end
            end
        end
    end
    if (not found) then
        -- no usable SAN: accept a matching common name
        for _, part in ipairs(cert:subject() or {}) do
            if (type(part) == 'table' and (part.name == 'commonName' or part.oid == '2.5.4.3') and name_ok(part.value)) then found = true; end
        end
    end
    if (not found) then error('tls: certificate is not for ' .. HOST); end
end

local function request_steps(job)
    local phase_start = os.time();
    local function tick(limit, what)
        if (os.time() - phase_start > limit) then error(what .. ' timed out'); end
        coroutine.yield();
    end
    local ip = resolve();
    local tcp = socket.tcp();
    tcp:settimeout(0);
    job.sock = tcp;
    local ok, err = tcp:connect(ip, 443);
    if (not ok and err ~= 'timeout' and err ~= 'Operation already in progress') then dns.ip = nil; error('connect: ' .. tostring(err)); end
    while true do
        local _, w = socket.select(nil, { tcp }, 0);
        if (w and #w > 0) then break; end
        local okt, et = pcall(tick, 8, 'connect');
        if (not okt) then dns.ip = nil; error(et); end
    end
    if (not file_exists(CA_FILE)) then error('assets/cacert.pem is missing; the board cannot be verified'); end
    local s, werr = ssl.wrap(tcp, {
        mode = 'client', protocol = 'any',
        options = { 'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1', 'no_tlsv1_1' },
        verify = { 'peer', 'fail_if_no_peer_cert' }, cafile = CA_FILE,
    });
    if (not s) then error('tls: ' .. tostring(werr)); end
    job.sock = s;
    if (s.sni) then s:sni(HOST); end
    s:settimeout(0);
    phase_start = os.time();
    while true do
        local hok, herr = s:dohandshake();
        if (hok) then break; end
        if (herr ~= 'wantread' and herr ~= 'wantwrite' and herr ~= 'timeout') then error('tls: ' .. tostring(herr)); end
        tick(10, 'handshake');
    end
    check_name(s);
    local payload = job.body and json.encode(job.body) or '';
    local hdr = ('%s %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: X-32 heaphjobs addon\r\nAccept: application/json\r\nConnection: close\r\n'):format(job.method, job.path, HOST);
    if (job.with_key and st.settings.key ~= '') then hdr = hdr .. 'X-Api-Key: ' .. st.settings.key .. '\r\n'; end
    if (job.body) then hdr = hdr .. 'Content-Type: application/json\r\nContent-Length: ' .. #payload .. '\r\n'; end
    local req = hdr .. '\r\n' .. payload;
    local sent = 0;
    phase_start = os.time();
    while (sent < #req) do
        local n, serr, last = s:send(req, sent + 1);
        if (n) then sent = n;
        elseif (serr == 'timeout' or serr == 'wantwrite' or serr == 'wantread') then sent = last or sent; tick(8, 'send');
        else error('send: ' .. tostring(serr)); end
    end
    local parts, total = {}, 0;
    phase_start = os.time();
    while true do
        local data, rerr, partial = s:receive(16384);
        local got = data or partial;
        if (got and #got > 0) then
            parts[#parts + 1] = got; total = total + #got;
            if (total > MAX_REPLY) then error('reply too big'); end
        end
        if (not data) then
            if (rerr == 'closed') then break; end
            if (rerr ~= 'timeout' and rerr ~= 'wantread' and rerr ~= 'wantwrite') then error('read: ' .. tostring(rerr)); end
            tick(20, 'read');
        end
    end
    s:close();
    job.sock = nil;
    local raw = table.concat(parts);
    local he = raw:find('\r\n\r\n', 1, true);
    if (not he) then error('bad reply'); end
    local headers, resp = raw:sub(1, he), raw:sub(he + 4);
    local status = tonumber(headers:match('^HTTP/%d%.%d (%d+)')) or 0;
    local lower = headers:lower();
    if (lower:find('transfer%-encoding:%s*chunked')) then
        resp = dechunk(resp);
        if (not resp) then error('reply cut short'); end
    else
        local want = tonumber(lower:match('content%-length:%s*(%d+)'));
        if (want and want ~= #resp) then error('reply cut short'); end
    end
    return status, resp;
end

-- api('GET', '/api/board', nil, cb, with_key). One of each method+path waits at a time.
local function api(method, path, body, cb, with_key)
    local base = path:match('^[^?]*');
    for _, q in ipairs(queue) do
        if (q.method == method and q.base == base) then return; end
    end
    if (current and current.job.method == method and current.job.base == base and method == 'GET') then return; end
    if (#queue >= 8) then return; end
    if (with_key == nil) then with_key = (method ~= 'GET'); end
    queue[#queue + 1] = { method = method, path = path, base = base, body = body, cb = cb, with_key = with_key };
end

local function close_sock(job)
    if (job and job.sock) then pcall(function () job.sock:close(); end); job.sock = nil; end
end

local function finish(job, ok, arg)
    if (job.cb) then
        local okc, ec = pcall(job.cb, ok, arg);
        if (not okc) then say('addon error: ' .. tostring(ec), false); end
    end
end

local function pump()
    if (current == nil) then
        if (#queue == 0) then return; end
        local job = table.remove(queue, 1);
        current = { job = job, co = coroutine.create(function () return request_steps(job); end) };
    end
    for _ = 1, 4 do
        local ok, status, resp = coroutine.resume(current.co);
        if (not ok) then
            local job = current.job; current = nil;
            close_sock(job);
            local e = tostring(status):gsub('^.-:%d+: ', '');
            finish(job, false, e);
            return;
        end
        if (coroutine.status(current.co) == 'dead') then
            local job = current.job; current = nil;
            local ok2, data = pcall(json.decode, resp or '');
            if (not ok2 or type(data) ~= 'table') then
                finish(job, false, status == 200 and 'bad reply from the board' or ('board answered ' .. tostring(status)));
                return;
            end
            if (status == 200) then finish(job, true, data);
            elseif (status == 401) then
                st.key_bad = true; st.me = nil;
                finish(job, false, 'Your in-game key is not valid any more. Make a new one on the website.');
            else finish(job, false, S(data.error ~= nil and data.error or ('board answered ' .. tostring(status)))); end
            return;
        end
    end
end

-- X: the board goes to sleep. Nothing new is fetched and nothing is drawn but the
-- moogle. A request already on the wire is allowed to finish so a post is never lost.
local function sleep_board()
    st.settings.visible = false; settings.save();
    queue = {};
    st.ui.settings_open = false;
end
local function wake_board()
    st.settings.visible = true; settings.save();
    st.fetched = 0;
end

-- ---------------------------------------------------------------- data
local function refresh()
    st.fetched = os.time();
    api('GET', '/api/board?addon=' .. os.time(), nil, function (ok, d)
        if (ok) then st.data = d; st.err = nil; else st.err = S(d); end
    end, false);
    if (st.settings.key ~= '') then
        api('GET', '/api/me?addon=' .. os.time(), nil, function (ok, d)
            if (ok and d.member) then st.me = d.member; st.key_bad = false;
            elseif (ok) then st.me = nil; st.key_bad = true;
            end
        end, true);
    else
        st.me = nil; st.key_bad = false;
    end
end

local function valid_key(k) return #k == LIM.key and k:match('^%x+$') ~= nil; end
local function set_key(k)
    k = S(k):gsub('%s', '');
    if (k ~= '' and not valid_key(k)) then return false; end
    st.settings.key = k; st.key_bad = false; st.me = nil; st.ui.key_in = nil;
    settings.save();
    refresh();
    return true;
end

-- ---------------------------------------------------------------- helpers
local UTC_DIFF = os.difftime(os.time(), os.time(os.date('!*t', os.time())));
local function iso_to_local(iso)
    if (type(iso) ~= 'string') then return nil; end
    local y, mo, d, h, mi, s = iso:match('^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)');
    if (not y) then return nil; end
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false }) + UTC_DIFF;
end
local function when_text(iso)
    local t = iso_to_local(iso);
    if (not t) then return ''; end
    local out = os.date('%a %b %d, %I:%M %p', t):gsub(' 0(%d)', ' %1');
    return out;
end
-- "2026-09-05 20:00" on your clock, to ISO in UTC
local function local_to_iso(text)
    local y, mo, d, h, mi = S(text):match('^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s+(%d%d?):(%d%d)%s*$');
    if (not y) then return nil; end
    local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = 0 });
    if (not t) then return nil; end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', t);
end
local function commas(n)
    local s = tostring(math.floor(N(n)));
    while true do
        local k; s, k = s:gsub('^(-?%d+)(%d%d%d)', '%1,%2');
        if (k == 0) then break; end
    end
    return s;
end
local function reward_text(j)
    if (j.reward_type == 'free') then return 'Free', PAL.green; end
    if (j.reward_type == 'points') then return pts(j.amount) .. ' Heaph Points', PAL.gold3; end
    return commas(j.amount) .. ' gil', PAL.amber;
end
local function matches(q, ...)
    if (q == nil or q == '') then return true; end
    q = q:lower();
    for i = 1, select('#', ...) do
        local s = select(i, ...);
        if (type(s) == 'string' and s:lower():find(q, 1, true)) then return true; end
    end
    return false;
end
local function buf(key, init)
    if (st.ui[key] == nil) then st.ui[key] = { init or '' }; end
    return st.ui[key];
end
local function ibuf(key, init)
    if (st.ui[key] == nil) then st.ui[key] = { init or 0 }; end
    return st.ui[key];
end
local function signed_in() return st.settings.key ~= '' and st.me ~= nil; end
local function display_size() local io_ = imgui.GetIO(); return io_.DisplaySize.x, io_.DisplaySize.y; end

-- ---------------------------------------------------------------- drawing bits
local function heading(text)
    imgui.Spacing();
    imgui.TextColored(PAL.brown, string.upper(text));
    local px, py = imgui.GetCursorScreenPos();
    local w = imgui.GetContentRegionAvail();
    imgui.GetWindowDrawList():AddLine({ px, py + 1 }, { px + w, py + 1 }, u32(PAL.line), 1);
    imgui.Dummy({ 0, 5 });
end

local function banner(kind, title, detail, points)
    title = S(title);
    if (title == '') then return; end
    detail = S(detail);
    local p = S(points);
    if (p == '0') then p = ''; end
    local bg = kind == 'active' and rgb(0x2F5E3A) or rgb(0x7A3527);
    local px, py = imgui.GetCursorScreenPos();
    local w = imgui.GetContentRegionAvail();
    local h = detail ~= '' and 62 or 46;
    local dl = imgui.GetWindowDrawList();
    dl:AddRectFilled({ px, py }, { px + w, py + h }, u32(bg), 2);
    dl:AddRect({ px + 3, py + 3 }, { px + w - 3, py + h - 3 }, u32(rgb(0xDEC28A, 0.45)), 2);
    imgui.SetCursorScreenPos({ px + 10, py + 6 });
    imgui.TextColored(PAL.gold2, kind == 'active' and 'ACTIVE JOB RIGHT NOW' or 'UPCOMING EVENT');
    imgui.SetCursorScreenPos({ px + 10, py + 22 });
    imgui.TextColored(PAL.cream, title);
    if (p ~= '') then imgui.SameLine(); imgui.TextColored(PAL.gold2, '  ' .. p .. ' pts'); end
    if (detail ~= '') then
        imgui.SetCursorScreenPos({ px + 10, py + 40 });
        imgui.PushTextWrapPos(px + w - 12);
        imgui.TextColored(rgb(0xE6DCC0), detail);
        imgui.PopTextWrapPos();
    end
    imgui.SetCursorScreenPos({ px, py + h + 6 });
end

-- a card: body(w) drawn on a bordered parchment box. The box uses last frame's
-- height so it can be painted before the text instead of over it.
local function card(id, body, tint)
    local px, py = imgui.GetCursorScreenPos();
    local w = imgui.GetContentRegionAvail();
    local dl = imgui.GetWindowDrawList();
    local hk = 'card_h_' .. id;
    local hh = st.ui[hk];
    if (hh) then
        dl:AddRectFilled({ px, py }, { px + w, py + hh }, u32(tint or rgb(0xFFFFFF, 0.18)), 0);
        dl:AddRect({ px, py }, { px + w, py + hh }, u32(rgb(0xB89C72, 0.55)), 0);
    end
    imgui.PushID(id);
    imgui.Dummy({ 0, 4 });
    imgui.Indent(8);
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + w - 24);
    local okb, eb = pcall(body, w);
    imgui.PopTextWrapPos();
    if (not okb) then imgui.TextColored(PAL.red, 'card error: ' .. tostring(eb)); end
    imgui.Unindent(8);
    imgui.Dummy({ 0, 4 });
    imgui.PopID();
    local _, endY = imgui.GetCursorScreenPos();
    st.ui[hk] = endY - py;
    imgui.Dummy({ 0, 4 });
end

-- title on the left, wrapped short of the reward column on the right
local function title_row(w, title, right, rcol)
    local x0 = imgui.GetCursorPosX();
    local y0 = imgui.GetCursorPosY();
    imgui.SetCursorPosX(x0 + math.max(w - 150, 200));
    imgui.TextColored(rcol, S(right));
    imgui.SetCursorPos({ x0, y0 });
    imgui.PushTextWrapPos(x0 + math.max(w - 160, 190));
    imgui.TextColored(PAL.brown, S(title));
    imgui.PopTextWrapPos();
end

-- after any input: a gold frame while it has the keyboard
local function focus_ring()
    if (imgui.IsItemActive()) then
        local x0, y0 = imgui.GetItemRectMin();
        local x1, y1 = imgui.GetItemRectMax();
        imgui.GetWindowDrawList():AddRect({ x0 - 1, y0 - 1 }, { x1 + 1, y1 + 1 }, u32(PAL.gold), 2, 0, 2);
    end
end
local function counter(key, limit)
    local n = #buf(key)[1];
    if (n > 0) then imgui.SameLine(); imgui.TextColored(n >= limit and PAL.red or PAL.soft, ('%d/%d'):format(n, limit)); end
end
local function field(label, key, hint, width, limit, init)
    limit = limit or LIM.title;
    imgui.TextColored(PAL.soft, label);
    counter(key, limit);
    imgui.SetNextItemWidth(width or -1);
    imgui.InputTextWithHint('##' .. key, hint or '', buf(key, init), limit + 1);
    focus_ring();
end
local function area(label, key, hint, h, limit)
    limit = limit or LIM.detail;
    imgui.TextColored(PAL.soft, label);
    counter(key, limit);
    imgui.InputTextMultiline('##' .. key, buf(key), limit + 1, { -1, h or 84 });
    focus_ring();
    if (buf(key)[1] == '' and hint) then imgui.TextColored(rgb(0x7A6238, 0.7), '  ' .. hint); end
end
local function combo(label, key, items, init)
    local b = ibuf(key, init or 1);
    imgui.TextColored(PAL.soft, label);
    imgui.SetNextItemWidth(260);
    if (imgui.BeginCombo('##' .. key, items[b[1]] or items[1])) then
        for i, it in ipairs(items) do
            if (imgui.Selectable(it, i == b[1])) then b[1] = i; end
        end
        imgui.EndCombo();
    end
    return b[1];
end
local function num(label, key, init, width)
    local b = ibuf(key, init or 1);
    imgui.TextColored(PAL.soft, label);
    imgui.SetNextItemWidth(width or 140);
    imgui.InputInt('##' .. key, b);
    if (b[1] < 0) then b[1] = 0; end
    return b[1];
end
local function need_key()
    if (st.key_bad) then
        imgui.TextColored(PAL.red, 'Your in-game key was refused. Make a new one on the website (Account tab) and set it under Account here.');
    elseif (st.settings.key ~= '') then
        imgui.TextColored(PAL.soft, 'Checking your key with the board...');
    else
        imgui.TextColored(PAL.red, 'Set your in-game key first (Account tab) to do this from in game.');
    end
end

-- ---------------------------------------------------------------- tabs
local function tab_heaph()
    local d = st.data; if (d == nil) then return; end
    local c = d.config or {};
    local q = st.search[1];
    local dcA = S(c.dc_active_title);
    banner('active', dcA ~= '' and dcA or c.active_title, dcA ~= '' and c.dc_active_detail or c.active_detail, c.active_points);
    local dcE = S(c.dc_event_title);
    local evTitle = dcE ~= '' and dcE or c.event_title;
    local evTime = dcE ~= '' and c.dc_event_time or c.event_time;
    local evDetail = S(dcE ~= '' and c.dc_event_detail or c.event_detail);
    local when = when_text(evTime);
    banner('event', evTitle, when .. ((when ~= '' and evDetail ~= '') and '  |  ' or '') .. evDetail, c.event_points);
    heading('Heaph Jobs');
    imgui.TextColored(PAL.soft, 'Jobs Heaph wants done. Claim one when you have done it and he rules on the points.');
    local shown = 0;
    for _, b in ipairs(d.bounties or {}) do
        if (matches(q, b.title, b.detail)) then
            shown = shown + 1;
            card('b' .. S(b.id), function (w)
                if (N(b.priority) == 1) then imgui.TextColored(PAL.red, 'PRIORITY'); end
                title_row(w, b.title, pts(b.reward) .. ' pts', PAL.gold3);
                if (S(b.detail) ~= '') then imgui.TextColored(PAL.ink2, S(b.detail)); end
                local chips = {};
                if (N(b.slots) > 0) then chips[#chips + 1] = pts(b.slots) .. ' places'; end
                if (N(b.repeatable) == 1) then chips[#chips + 1] = 'repeatable'; end
                chips[#chips + 1] = 'rank ' .. S(b.rank ~= nil and b.rank or 'B');
                imgui.TextColored(PAL.soft, table.concat(chips, '   |   '));
                local key = 'claim' .. S(b.id);
                if (st.ui[key .. '_open']) then
                    field('What you did', key, 'Came to Periqia on Tuesday and stayed the whole run.', nil, LIM.note);
                    if (btn('Send the claim')) then
                        local note = buf(key)[1];
                        if (#note < 4) then say('Say what you did first.', false);
                        else
                            api('POST', '/api/claim', { bountyId = b.id, note = note }, function (ok, r)
                                if (ok) then say('Claim sent for "' .. S(b.title) .. '". Heaph will rule on it.', true); st.ui[key .. '_open'] = nil; st.ui[key] = nil; refresh();
                                else say(r, false); end
                            end);
                        end
                    end
                    imgui.SameLine();
                    if (btn('Never mind')) then st.ui[key .. '_open'] = nil; end
                else
                    if (btn('I did this, claim it')) then
                        if (signed_in()) then st.ui[key .. '_open'] = true; else say('Set your in-game key on the Account tab first.', false); end
                    end
                end
            end, N(b.priority) == 1 and rgb(0x26324F, 0.10) or nil);
        end
    end
    if (shown == 0) then imgui.TextColored(PAL.soft, q ~= '' and ('Nothing matches "' .. q .. '".') or 'The board is empty.'); end
end

local function pub_card(j, done)
    card('p' .. S(j.id), function (w)
        local reward, rcol = reward_text(j);
        imgui.TextColored(PAL.soft, j.type == 'service' and 'SERVICE' or 'HELP WANTED');
        title_row(w, j.title, reward .. ((j.type == 'service' and j.reward_type ~= 'free') and ' asked' or ''), rcol);
        if (S(j.detail) ~= '') then imgui.TextColored(PAL.ink2, S(j.detail)); end
        local by = S(j.poster ~= nil and j.poster or '?');
        if (S(j.when_at) ~= '') then by = by .. '   |   ' .. when_text(j.when_at); end
        if (done and S(j.helper_name) ~= '') then by = by .. '   |   done by ' .. S(j.helper_name); end
        imgui.TextColored(PAL.soft, by);
        if (not done and st.me and (st.me.id == j.member_id or st.me.isAdmin)) then
            local key = 'close' .. S(j.id);
            if (j.type == 'service') then
                if (btn('Take it down')) then
                    api('POST', '/api/pjobs/close', { id = j.id, action = 'cancel' }, function (ok, r) say(ok and S(r.did) or r, ok); refresh(); end);
                end
            elseif (st.ui[key .. '_open']) then
                field('Who helped? Character name', key, 'Tensho', 240, LIM.helper);
                if (btn('Mark done, pay them')) then
                    api('POST', '/api/pjobs/close', { id = j.id, action = 'done', helper = buf(key)[1] }, function (ok, r)
                        say(ok and S(r.did) or r, ok); if (ok) then st.ui[key .. '_open'] = nil; end refresh(); end);
                end
                imgui.SameLine();
                if (btn('Back')) then st.ui[key .. '_open'] = nil; end
            else
                if (btn('Done, who helped?')) then st.ui[key .. '_open'] = true; end
                imgui.SameLine();
                if (btn('Cancel it')) then
                    api('POST', '/api/pjobs/close', { id = j.id, action = 'cancel' }, function (ok, r) say(ok and S(r.did) or r, ok); refresh(); end);
                end
            end
        end
    end);
end

local function tab_public()
    local d = st.data; if (d == nil) then return; end
    local pj = d.pjobs or { open = {}, done = {} };
    local q = st.search[1];
    local helps, svcs = {}, {};
    for _, j in ipairs(pj.open or {}) do
        if (matches(q, j.title, j.detail, j.poster)) then
            if (j.type == 'service') then svcs[#svcs + 1] = j; else helps[#helps + 1] = j; end
        end
    end
    heading('Help wanted');
    if (#helps == 0) then imgui.TextColored(PAL.soft, q ~= '' and ('Nothing matches "' .. q .. '".') or 'Nobody needs a hand right now.'); end
    for _, j in ipairs(helps) do pub_card(j, false); end
    heading('Services offered');
    if (#svcs == 0) then imgui.TextColored(PAL.soft, q ~= '' and ('Nothing matches "' .. q .. '".') or 'No services on offer. TH4? Teleports? Crafting?'); end
    for _, j in ipairs(svcs) do pub_card(j, false); end
    if (pj.done and #pj.done > 0 and q == '') then
        heading('Recently done');
        for i, j in ipairs(pj.done) do if (i <= 3) then pub_card(j, true); end end
    end
end

local function tab_post()
    if (not signed_in()) then need_key(); return; end
    local me = st.me;
    local slots = N(me.pjSlots) > 0 and N(me.pjSlots) or 1;
    imgui.TextColored(PAL.soft, ('You have %s Heaph Points on hand, %d open post slot%s (one more for every 50 earned).'):format(pts(me.points), slots, slots == 1 and '' or 's'));
    local which = combo('What are you posting', 'post_kind', { 'I need help (with a bounty)', 'I offer a service (TH4, teleports, crafting)' });
    if (which == 1) then
        imgui.TextColored(PAL.ink2, 'Heaph Points come off your balance now and go to whoever you name when you mark it done. Cancel and they come back. Gil stays between you and your helper.');
        field('What do you need', 'h_title', 'Need a hand with LB2');
        local rt = combo('Bounty', 'h_rt', { 'Heaph Points', 'Gil, paid in game' });
        if (st.ui.h_rt_last ~= rt) then st.ui.h_rt_last = rt; st.ui.h_amt = nil; end
        local amt = num('How much', 'h_amt', rt == 1 and math.max(1, math.min(2, math.floor(N(me.points)))) or 10000);
        field('When (optional, your clock, like 2026-09-05 20:00)', 'h_when', '', 260, LIM.when);
        area('Details', 'h_detail', 'Where, what jobs help, how long.');
        if (btn('Post the request')) then
            local when = buf('h_when')[1];
            local iso = when ~= '' and local_to_iso(when) or '';
            if (when ~= '' and not iso) then say('Write the time as 2026-09-05 20:00', false);
            else
                api('POST', '/api/pjobs', { type = 'help', title = buf('h_title')[1], detail = buf('h_detail')[1], reward_type = rt == 1 and 'points' or 'gil', amount = amt, when_at = iso }, function (ok, r)
                    if (ok) then say('Posted under Help wanted.', true); st.ui.h_title = nil; st.ui.h_detail = nil; st.ui.h_when = nil; refresh(); else say(r, false); end
                end);
            end
        end
    else
        imgui.TextColored(PAL.ink2, 'Tell the shell what you offer and what you ask. Nothing is held by the site; settle it in game. Take it down whenever you like.');
        field('What you offer', 's_title', 'TH4 help on NM camps');
        local rt = combo('You ask', 's_rt', { 'Gil', 'Heaph Points', 'Free' });
        if (st.ui.s_rt_last ~= rt) then st.ui.s_rt_last = rt; st.ui.s_amt = nil; end
        local amt = 0;
        if (rt ~= 3) then amt = num('How much', 's_amt', rt == 1 and 10000 or 2); end
        field('When (optional, your clock, like 2026-09-05 20:00)', 's_when', '', 260, LIM.when);
        area('Details', 's_detail', 'When you are usually on, what to bring, how to reach you.');
        if (btn('Post the service')) then
            local when = buf('s_when')[1];
            local iso = when ~= '' and local_to_iso(when) or '';
            if (when ~= '' and not iso) then say('Write the time as 2026-09-05 20:00', false);
            else
                api('POST', '/api/pjobs', { type = 'service', title = buf('s_title')[1], detail = buf('s_detail')[1], reward_type = ({ 'gil', 'points', 'free' })[rt], amount = amt, when_at = iso }, function (ok, r)
                    if (ok) then say('Posted under Services offered.', true); st.ui.s_title = nil; st.ui.s_detail = nil; st.ui.s_when = nil; refresh(); else say(r, false); end
                end);
            end
        end
    end
end

local function tab_ask()
    if (not signed_in()) then need_key(); return; end
    heading('Ask Heaph for a points event');
    imgui.TextColored(PAL.ink2, 'Pitch an event or job for Heaph to run. He sets the final Heaph Points, posts it on Heaph Jobs, and X-32 announces it.');
    field('Event or job', 'e_title', 'EXP party in Bibiki Bay, Saturday night');
    local p = num('Points suggested', 'e_pts', 5);
    area('Detail', 'e_detail', 'Where, when, what to bring, who is in already.');
    if (btn('Send it to Heaph')) then
        api('POST', '/api/jobrequest', { title = buf('e_title')[1], detail = buf('e_detail')[1], reward = p }, function (ok, r)
            if (ok) then say('Sent to Heaph. It shows on Heaph Jobs once he prices it.', true); st.ui.e_title = nil; st.ui.e_detail = nil; else say(r, false); end
        end);
    end
    heading('Request points');
    imgui.TextColored(PAL.ink2, 'Did something for Heaph that is not on the board? Say what, and what you think it is worth.');
    area('What you did', 'r_note', 'Crafted the sushi for the whole Dynamis run.', 84, LIM.note);
    local asked = num('Points asked', 'r_asked', 5);
    if (btn('Send the request')) then
        api('POST', '/api/claim', { note = buf('r_note')[1], asked = asked }, function (ok, r)
            if (ok) then say('Request sent. Heaph will rule on it.', true); st.ui.r_note = nil; else say(r, false); end
        end);
    end
end

local function tab_account()
    heading('Your in-game key');
    imgui.TextColored(PAL.ink2, 'On heaphpoints.com, open the Account tab and press "Make in-game key". Paste it here, or type /heaphjobs key <key> in chat. Making a new key on the website replaces the old one everywhere.');
    imgui.SetNextItemWidth(440);
    local kb = buf('key_in', st.settings.key);
    imgui.InputText('##keyin', kb, LIM.key + 1, ImGuiInputTextFlags_Password);
    focus_ring();
    imgui.SameLine();
    if (btn('Save key')) then
        if (set_key(kb[1])) then say('Key saved. Checking it with the board...', true);
        else say('That does not look like a key. It is 48 letters and digits from the website Account tab.', false); end
    end
    imgui.SameLine();
    if (btn('Forget key')) then st.settings.key = ''; st.ui.key_in = nil; st.me = nil; st.key_bad = false; settings.save(); say('Key forgotten on this character. Revoke it on the website if you want it dead everywhere.', true); end
    imgui.Spacing();
    if (st.me) then
        local slots = N(st.me.pjSlots) > 0 and N(st.me.pjSlots) or 1;
        imgui.TextColored(PAL.brown, ('Signed in as %s'):format(S(st.me.name)));
        imgui.TextColored(PAL.ink2, ('%s Heaph Points on hand   |   %s earned   |   %s deeds   |   %d open post slot%s'):format(pts(st.me.points), pts(st.me.earned), pts(st.me.helped), slots, slots == 1 and '' or 's'));
    elseif (st.key_bad) then
        imgui.TextColored(PAL.red, 'This key was refused or revoked. Make a new one on the website and paste it above.');
    elseif (st.settings.key ~= '') then
        imgui.TextColored(PAL.soft, 'Checking the key...');
    else
        imgui.TextColored(PAL.soft, 'No key set. You can still read everything; posting and claiming need the key.');
    end
    imgui.TextColored(PAL.soft, 'The key is saved per character in Game\\config\\addons\\heaphjobs. Anyone with your key can post and claim as you, so keep it to yourself.');
    heading('Window');
    imgui.TextColored(PAL.ink2, 'Opacity, size, the sleeping moogle and the position lock live under the Settings button in the title bar.');
    if (btn('Open settings')) then st.ui.settings_open = true; end
    heading('About');
    imgui.TextColored(PAL.ink2, 'Reads heaphpoints.com every two minutes and sends only what you post. The board only moves while Shift is held. X puts it to sleep; click the moogle or type /heaphjobs to wake it. While a text box has the keyboard, click outside it to give the keys back to the game.');
    imgui.TextColored(PAL.soft, 'heaphjobs ' .. addon.version .. '. Creation assisted by ADA. Bugs to Heaph; compliments to X-32.');
end

-- ---------------------------------------------------------------- windows
local function draw_settings()
    if (not st.ui.settings_open) then return; end
    local sw, sh = display_size();
    imgui.SetNextWindowSize({ 360, 0 }, ImGuiCond_Always);
    if (imgui.Begin('Board settings##heaphjobs_settings', true, bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_AlwaysAutoResize))) then
        local ab = st.ui.alpha_slider or { st.settings.alpha or 0.95 }; st.ui.alpha_slider = ab;
        imgui.TextColored(PAL.brown, 'Background opacity');
        imgui.SetNextItemWidth(-1);
        if (imgui.SliderFloat('##s_alpha', ab, 0.15, 1.0, '%.2f')) then st.settings.alpha = ab[1]; st.size_dirty = os.time(); end
        local wb = st.ui.w_slider or { st.settings.w or 1000 }; st.ui.w_slider = wb;
        local hb = st.ui.h_slider or { st.settings.h or 780 }; st.ui.h_slider = hb;
        imgui.TextColored(PAL.brown, 'Width');
        imgui.SetNextItemWidth(-1);
        if (imgui.SliderInt('##s_w', wb, 560, math.max(560, math.floor(sw)), '%d px')) then resize_to = { wb[1], hb[1] }; end
        imgui.TextColored(PAL.brown, 'Height');
        imgui.SetNextItemWidth(-1);
        if (imgui.SliderInt('##s_h', hb, 360, math.max(360, math.floor(sh)), '%d px')) then resize_to = { wb[1], hb[1] }; end
        imgui.TextColored(PAL.soft, 'Or drag the gold corner grip on the board.');
        imgui.Spacing();
        imgui.TextColored(PAL.brown, 'Sleeping moogle');
        local mb = st.ui.mog_size or { st.settings.mogsize or 72 }; st.ui.mog_size = mb;
        imgui.TextColored(PAL.soft, 'Size');
        imgui.SetNextItemWidth(-1);
        if (imgui.SliderInt('##s_mogsize', mb, 32, 200, '%d px')) then st.settings.mogsize = mb[1]; st.size_dirty = os.time(); end
        local mab = st.ui.mog_alpha or { st.settings.mogalpha or 1.0 }; st.ui.mog_alpha = mab;
        imgui.TextColored(PAL.soft, 'Opacity (full while hovered)');
        imgui.SetNextItemWidth(-1);
        if (imgui.SliderFloat('##s_mogalpha', mab, 0.15, 1.0, '%.2f')) then st.settings.mogalpha = mab[1]; st.size_dirty = os.time(); end
        imgui.TextColored(PAL.soft, 'Shift-drag him to move. Reset sends him home.');
        imgui.Spacing();
        local lb = { st.settings.locked or false };
        if (imgui.Checkbox('Lock position (never moves)', lb)) then st.settings.locked = lb[1]; settings.save(); end
        imgui.TextColored(PAL.soft, 'Unlocked: hold Shift and drag to move.');
        imgui.Spacing();
        if (btn('Reset to defaults')) then
            st.settings.alpha, st.settings.w, st.settings.h, st.settings.locked = 0.95, 1000, 780, false;
            st.settings.mogx, st.settings.mogy = nil, nil;
            st.settings.mogsize, st.settings.mogalpha = 72, 1.0;
            st.ui.alpha_slider, st.ui.w_slider, st.ui.h_slider, st.ui.mog_size, st.ui.mog_alpha = nil, nil, nil, nil, nil;
            resize_to = { 1000, 780 }; reposition_to = { 60, 60 }; settings.save();
        end
        imgui.SameLine();
        if (btn('Close')) then st.ui.settings_open = false; end
    end
    imgui.End();
end

local function draw_moogle()
    local size = math.max(32, math.min(200, N(st.settings.mogsize) > 0 and N(st.settings.mogsize) or 72));
    local ma = math.max(0.15, math.min(1, N(st.settings.mogalpha) > 0 and N(st.settings.mogalpha) or 1));
    local sw, sh = display_size();
    if (st.settings.mogx == nil) then
        st.settings.mogx, st.settings.mogy = sw - size - 16, sh - size - 48;
    end
    -- never off screen, whatever monitor he was last seen on
    st.settings.mogx = math.max(0, math.min(sw - size, st.settings.mogx));
    st.settings.mogy = math.max(0, math.min(sh - size, st.settings.mogy));
    local moving = shift_held() and not st.settings.locked;
    imgui.SetNextWindowPos({ st.settings.mogx, st.settings.mogy }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ size, size }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_Alpha, 1.0);              -- the global style dims windows; not this one
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    local flags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoMove);
    if (imgui.Begin('##heaphjobs_moogle', true, flags)) then
        local wx, wy = imgui.GetWindowPos();
        -- painted on the screen-level list, which no window setting can fade
        local okfg, fg = pcall(imgui.GetForegroundDrawList);
        local dl = (okfg and fg) or imgui.GetWindowDrawList();
        imgui.InvisibleButton('##mog', { size, size });
        local hovered = imgui.IsItemHovered();
        local active = imgui.IsItemActive();
        if (active and moving) then
            local mx, my = imgui.GetMousePos();
            if (st.ui.mog_drag) then
                st.settings.mogx = st.settings.mogx + (mx - st.ui.mog_drag[1]);
                st.settings.mogy = st.settings.mogy + (my - st.ui.mog_drag[2]);
                st.size_dirty = os.time();
            end
            st.ui.mog_drag = { mx, my };
        else
            if (st.ui.mog_drag) then st.ui.mog_drag = nil; settings.save(); end
            if (imgui.IsItemClicked(0) and not moving) then wake_board(); end
        end
        local cx, cy, r = wx + size / 2, wy + size / 2, size / 2;
        dl:AddCircleFilled({ cx + 1, cy + 2 }, r - 1, u32(rgb(0x000000, 0.35 * ma)), 32);
        if (hovered) then dl:AddCircle({ cx, cy }, r + 1, u32(PAL.gold2), 32, 2); end
        if (active and moving) then dl:AddRect({ wx, wy }, { wx + size, wy + size }, u32(PAL.gold), 4, 0, 1); end
        if (st.tex.icon ~= nil) then
            dl:AddImage(tex_id(st.tex.icon), { wx, wy }, { wx + size, wy + size }, { 0, 0 }, { 1, 1 }, u32(rgb(0xFFFFFF, hovered and 1 or ma)));
        else
            dl:AddCircleFilled({ cx, cy }, r, u32(rgb(0x26324F, ma)), 32);
        end
        if (hovered and not active) then imgui.SetTooltip(st.settings.locked and 'Heaph Point Board. Click to open.' or 'Heaph Point Board. Click to open, Shift-drag to move me.'); end
    end
    imgui.End();
    imgui.PopStyleVar(3);
end

local function draw_window()
    if (not st.settings.visible) then draw_moogle(); return; end
    local a = math.max(0.15, math.min(1, N(st.settings.alpha) > 0 and N(st.settings.alpha) or 0.95));
    if (reposition_to) then imgui.SetNextWindowPos(reposition_to, ImGuiCond_Always); reposition_to = nil; end
    if (resize_to) then imgui.SetNextWindowSize(resize_to, ImGuiCond_Always); resize_to = nil;
    else imgui.SetNextWindowSize({ st.settings.w or 1000, st.settings.h or 780 }, ImGuiCond_FirstUseEver); end
    imgui.SetNextWindowSizeConstraints({ 560, 360 }, { 4000, 4000 });
    imgui.PushStyleColor(ImGuiCol_WindowBg, rgb(0xEFE4CE, a));
    imgui.PushStyleColor(ImGuiCol_Border, PAL.gold);
    imgui.PushStyleColor(ImGuiCol_Text, PAL.ink);
    imgui.PushStyleColor(ImGuiCol_Button, PAL.navy);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, PAL.navy2);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, PAL.gold3);
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg, PAL.paper2);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab, PAL.line);
    imgui.PushStyleColor(ImGuiCol_ChildBg, { 0, 0, 0, 0 });
    imgui.PushStyleColor(ImGuiCol_FrameBg, rgb(0xFFFFFF, 0.45));
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, rgb(0xFFFFFF, 0.65));
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, rgb(0xFFF3C4, 0.95));
    imgui.PushStyleColor(ImGuiCol_Tab, PAL.navy);
    imgui.PushStyleColor(ImGuiCol_TabHovered, PAL.navy2);
    imgui.PushStyleColor(ImGuiCol_TabSelected, rgb(0x8A6A34));
    imgui.PushStyleColor(ImGuiCol_PopupBg, PAL.paper);
    imgui.PushStyleColor(ImGuiCol_Header, rgb(0xDEC28A, 0.5));
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, rgb(0xDEC28A, 0.7));
    imgui.PushStyleColor(ImGuiCol_HeaderActive, PAL.gold2);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 12, 10 });
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 1);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 6, 5 });
    local pushed = 19;
    -- the board only moves while Shift is held, so clicks in the lists never drag it around
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse);
    if (st.settings.locked or not shift_held()) then flags = bit.bor(flags, ImGuiWindowFlags_NoMove); end
    if (imgui.Begin('Heaph Point Board##heaphjobs', true, flags)) then
        local wx, wy = imgui.GetWindowPos();
        local ww, wh = imgui.GetWindowSize();
        if (math.floor(ww) ~= st.settings.w or math.floor(wh) ~= st.settings.h) then
            st.settings.w, st.settings.h = math.floor(ww), math.floor(wh);
            st.ui.w_slider, st.ui.h_slider = nil, nil;
            st.size_dirty = os.time();
        end
        local dl = imgui.GetWindowDrawList();
        if (st.tex.paper ~= nil) then
            dl:AddImage(tex_id(st.tex.paper), { wx, wy }, { wx + ww, wy + wh }, { 0, 0 }, { 1, 1 }, u32(rgb(0xFFFFFF, 0.9 * a)));
        end
        dl:AddRectFilled({ wx, wy }, { wx + ww, wy + 34 }, u32(rgb(0x26324F, math.max(a, 0.6))), 0);
        dl:AddLine({ wx, wy + 34 }, { wx + ww, wy + 34 }, u32(PAL.gold), 2);
        -- a resize grip in the corner, so people know the window stretches
        dl:AddTriangleFilled({ wx + ww - 4, wy + wh - 18 }, { wx + ww - 4, wy + wh - 4 }, { wx + ww - 18, wy + wh - 4 }, u32(rgb(0x8A6A34, 0.8)));

        imgui.SetCursorPos({ 14, 9 });
        imgui.TextColored(PAL.gold2, "HEAPH'S HAREM   -   POINT BOARD");
        if (st.me) then imgui.SameLine(); imgui.TextColored(PAL.cream, ('   %s   |   %s pts'):format(S(st.me.name), pts(st.me.points))); end
        imgui.SameLine(ww - 120);
        if (sbtn('Settings')) then st.ui.settings_open = not st.ui.settings_open; end
        tip('Opacity, size, the moogle, position lock.');
        imgui.SameLine();
        if (sbtn(' X ')) then sleep_board(); end
        tip('Sleep. Click the moogle, or type /heaphjobs, to wake the board.');
        -- tool row under the title: search on the left, refresh on the right
        imgui.SetCursorPos({ 12, 44 });
        imgui.TextColored(PAL.soft, 'Search');
        imgui.SameLine();
        imgui.SetNextItemWidth(300);
        imgui.InputTextWithHint('##search', 'title, detail or poster', st.search, LIM.search + 1);
        focus_ring();
        if (st.search[1] ~= '') then
            imgui.SameLine();
            if (sbtn('clear')) then st.search[1] = ''; end
        end
        imgui.SameLine(ww - 90);
        if (sbtn('Refresh')) then refresh(); end
        imgui.SetCursorPos({ 12, 74 });

        do  -- the band behind the tabs
            local bx, by = imgui.GetCursorScreenPos();
            local bw = imgui.GetContentRegionAvail();
            dl:AddRectFilled({ bx - 12, by - 2 }, { bx + bw + 12, by + 26 }, u32(rgb(0x1F2A44, math.max(a, 0.6))), 0);
            dl:AddLine({ bx - 12, by + 26 }, { bx + bw + 12, by + 26 }, u32(PAL.gold), 1);
        end
        imgui.PushStyleColor(ImGuiCol_Text, PAL.cream);
        local tabs_open = imgui.BeginTabBar('##heaphjobs_tabs');
        imgui.PopStyleColor();
        if (tabs_open) then
            local tabs = {
                { 'Heaph Jobs', tab_heaph }, { 'Public Jobs', tab_public }, { 'Post a job', tab_post }, { 'Ask Heaph', tab_ask }, { 'Account', tab_account },
            };
            for _, t in ipairs(tabs) do
                imgui.PushStyleColor(ImGuiCol_Text, PAL.cream);
                local on = imgui.BeginTabItem(t[1]);
                imgui.PopStyleColor();
                if (on) then
                    imgui.Dummy({ 0, 2 });
                    imgui.BeginChild('##body_' .. t[1], { 0, -26 }, 0, 0);
                    if (st.data == nil and t[2] ~= tab_account) then
                        imgui.TextColored(PAL.soft, st.err and ('Could not reach the board: ' .. S(st.err)) or 'Fetching the board...');
                    else
                        local okt, et = pcall(t[2]);
                        if (not okt) then imgui.TextColored(PAL.red, 'tab error: ' .. tostring(et)); end
                    end
                    imgui.EndChild();
                    imgui.EndTabItem();
                end
            end
            imgui.EndTabBar();
        end
        -- status line
        if (st.msg and os.time() - st.msg.at < 10) then
            imgui.TextColored(st.msg.good and PAL.green or PAL.red, st.msg.text);
        else
            local when = st.fetched > 0 and ('updated ' .. (os.date('%I:%M %p', st.fetched):gsub('^0', ''))) or 'fetching...';
            local hint = (os.time() - st.loaded < 180) and '   |   Shift-drag to move, drag the corner to resize' or '';
            imgui.TextColored(PAL.soft, 'heaphpoints.com   |   ' .. when .. (current and '   |   working...' or '') .. (st.err and ('   |   ' .. S(st.err)) or '') .. hint);
        end
        if (st.tex.icon ~= nil) then
            local s = 96;
            dl:AddImage(tex_id(st.tex.icon), { wx + ww - s - 8, wy + wh - s - 30 }, { wx + ww - 8, wy + wh - 30 }, { 0, 0 }, { 1, 1 }, u32(rgb(0xFFFFFF, 1)));
        end
    end
    imgui.End();
    draw_settings();
    imgui.PopStyleVar(4);
    imgui.PopStyleColor(pushed);
end

-- ---------------------------------------------------------------- events
ashita.events.register('load', 'heaphjobs_load', function ()
    st.tex.paper = load_texture('paper_tex.jpg');
    st.tex.icon = load_texture('moogle_icon.png');
    if (st.settings.visible) then refresh(); end
end);

ashita.events.register('unload', 'heaphjobs_unload', function ()
    if (current) then close_sock(current.job); current = nil; end
    queue = {};
end);

ashita.events.register('d3d_present', 'heaphjobs_present', function ()
    if (st.size_dirty and os.time() - st.size_dirty >= 1) then st.size_dirty = nil; settings.save(); end
    if (not st.settings.visible) then
        if (current) then pump(); end            -- let a post already on the wire finish
        draw_moogle();
        return;
    end
    if (os.time() - st.fetched >= REFRESH_SECS) then refresh(); end
    pump();
    draw_window();
end);

ashita.events.register('command', 'heaphjobs_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/heaphjobs', '/jobs', '/pjobs')) then return; end
    e.blocked = true;
    local function out(text) print(chat.header(addon.name):append(chat.message(text))); end
    if (#args >= 2 and args[2]:any('refresh', 'r')) then
        refresh(); out('Refreshing the board.'); return;
    end
    if (#args >= 3 and args[2]:any('key')) then
        if (set_key(args[3])) then out('Key saved. Checking it with the board.'); else out('That does not look like a key. It is 48 letters and digits from the website Account tab.'); end
        return;
    end
    if (#args >= 3 and args[2]:any('alpha', 'opacity')) then
        st.settings.alpha = math.max(0.15, math.min(1, tonumber(args[3]) or 0.95));
        st.ui.alpha_slider = nil; settings.save();
        out(('Opacity %.2f.'):format(st.settings.alpha)); return;
    end
    if (#args >= 4 and args[2]:any('size')) then
        local w, h = tonumber(args[3]), tonumber(args[4]);
        if (w and h) then resize_to = { math.max(560, w), math.max(360, h) }; out(('Size %dx%d.'):format(w, h)); end
        return;
    end
    if (#args >= 3 and args[2]:any('mogsize')) then
        st.settings.mogsize = math.max(32, math.min(200, tonumber(args[3]) or 72)); st.ui.mog_size = nil; settings.save();
        out(('Moogle size %d.'):format(st.settings.mogsize)); return;
    end
    if (#args >= 3 and args[2]:any('mogalpha')) then
        st.settings.mogalpha = math.max(0.15, math.min(1, tonumber(args[3]) or 1)); st.ui.mog_alpha = nil; settings.save();
        out(('Moogle opacity %.2f.'):format(st.settings.mogalpha)); return;
    end
    if (#args >= 2 and args[2]:any('reset')) then
        st.settings.alpha, st.settings.w, st.settings.h, st.settings.locked = 0.95, 1000, 780, false;
        st.settings.mogx, st.settings.mogy, st.settings.mogsize, st.settings.mogalpha = nil, nil, 72, 1.0;
        st.ui.alpha_slider, st.ui.w_slider, st.ui.h_slider, st.ui.mog_size, st.ui.mog_alpha = nil, nil, nil, nil, nil;
        resize_to = { 1000, 780 }; reposition_to = { 60, 60 };
        st.settings.visible = true; st.fetched = 0; settings.save();
        out('Back to defaults, board and moogle on screen.'); return;
    end
    if (#args >= 2 and args[2]:any('help')) then
        out('/heaphjobs toggles the board. refresh, key <key>, alpha 0.8, size 900 700, mogsize 72, mogalpha 0.8, reset. Shift-drag moves the board and the moogle; drag the corner to resize.');
        return;
    end
    if (st.settings.visible) then sleep_board(); else wake_board(); end
end);

-- a character switch loads that character's settings; forget the previous one's session
settings.register('settings', 'heaphjobs_settings', function (s)
    if (s ~= nil) then st.settings = s; end
    st.me = nil; st.key_bad = false; st.fetched = 0;
    st.ui.key_in, st.ui.alpha_slider, st.ui.w_slider, st.ui.h_slider, st.ui.mog_size, st.ui.mog_alpha = nil, nil, nil, nil, nil, nil;
    settings.save();
end);
