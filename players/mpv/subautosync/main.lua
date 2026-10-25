-- subautosync for mpv: press Ctrl+y to auto-sync the current external subtitle.
-- اضغط Ctrl+y لمزامنة الترجمة الخارجية الحالية تلقائياً.
--
-- Install: copy this folder (with subautosync.py inside it) to your mpv "scripts" folder:
--   Windows: %APPDATA%\mpv\scripts\subautosync\
--   macOS / Linux: ~/.config/mpv/scripts/subautosync/
-- Options (optional) in script-opts/subautosync.conf:
--   python=python3        (Windows: python)
--   lang=ar               (en / ar)
--   auto=yes              (also sync automatically whenever an external subtitle is selected)

local mp = require "mp"
local utils = require "mp.utils"
local options = require "mp.options"

local opts = { python = "", lang = "en", auto = false, min_match = 0.45 }
options.read_options(opts, "subautosync")

local done = {}   -- subtitle files already handled in this session

local function python_exe()
    if opts.python ~= "" then return opts.python end
    local plat = mp.get_property("platform", "")
    if plat == "windows" or package.config:sub(1, 1) == "\\" then return "python" end
    return "python3"
end

local function script_path()
    local dir = mp.get_script_directory and mp.get_script_directory() or nil
    if not dir then
        local src = debug.getinfo(1, "S").source:gsub("^@", "")
        dir = src:match("^(.*)[/\\]") or "."
    end
    return utils.join_path(dir, "subautosync.py")
end

local function current_external_sub()
    for _, t in ipairs(mp.get_property_native("track-list", {})) do
        if t.type == "sub" and t.selected and t.external and t["external-filename"] then
            return t
        end
    end
    return nil
end

local function msg(ar, en)
    mp.osd_message(opts.lang == "ar" and ar or en, 6)
end

local function sync(manual)
    local video = mp.get_property("path")
    local track = current_external_sub()
    if not video or not track then
        if manual then msg("لا توجد ترجمة خارجية مختارة", "No external subtitle selected") end
        return
    end
    local sub = track["external-filename"]
    if video:find("://") and not video:find("^file://") then
        if manual then msg("المزامنة تعمل مع الملفات المحلية فقط", "Auto-sync works with local files only") end
        return
    end
    if not manual and done[sub] then return end
    done[sub] = true
    msg("جارٍ مزامنة الترجمة…", "Syncing subtitle…")

    local out = sub:gsub("(%.[^.\\/]+)$", ".synced%1")
    if out == sub then out = sub .. ".synced.srt" end
    local args = { python_exe(), script_path(), video, sub, "-o", out, "--json",
                   "--lang", opts.lang, "--min-match", tostring(opts.min_match) }
    mp.command_native_async({ name = "subprocess", args = args, capture_stdout = true,
                              capture_stderr = true, playback_only = false },
        function(ok, res)
            if not ok or not res or res.status == nil or (res.status ~= 0 and res.status ~= 2) then
                local err = res and res.stderr or ""
                mp.msg.error("subautosync failed: " .. tostring(err))
                msg("تعذّر تشغيل subautosync.py (هل Python مثبت؟)",
                    "Could not run subautosync.py (is Python installed?)")
                return
            end
            local r = utils.parse_json(res.stdout or "") or {}
            if r.status == "synced" and r.output then
                -- make sure the user did not switch subtitles while we were working
                local now = current_external_sub()
                if now and now["external-filename"] == sub then
                    mp.commandv("sub-add", r.output, "select", "auto-synced")
                    mp.set_property_number("sub-delay", 0)
                    done[r.output] = true
                end
            end
            if manual or r.status == "synced" then
                mp.osd_message(r.message or "?", 6)
            end
            mp.msg.info((r.message or "") .. " | " .. (r.reference or ""))
        end)
end

mp.add_key_binding("Ctrl+y", "sync-subtitle", function() sync(true) end)

if opts.auto then
    mp.observe_property("current-tracks/sub/external-filename", "string", function(_, v)
        if v then sync(false) end
    end)
end
