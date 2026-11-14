-- quicklook: a Quick Look preview of a file, in a floating pane over the one you are in.
--
-- Install: link this directory into your plugins directory, then reload.
--
--   ln -s "$PWD/examples/plugins/quicklook" ~/.config/thurm/plugins/quicklook
--   thurm reload
--
-- Use:
--
--   cmd+y                                    asks for a file; it starts from the last file
--                                            the pane shows, or the pane's directory
--   thurm action run quicklook.preview '{"path":"report.pdf"}'
--   thurm.run("quicklook.preview", { path = "~/Desktop/shot.png" })      -- from Lua
--
-- A relative path is taken from the pane's directory. A file macOS has a Quick Look generator
-- for (images, PDFs, documents, fonts, ...) shows as the thumbnail Quick Look makes for it,
-- drawn with the kitty graphics protocol and fitted to the pane; any key closes it. A text file
-- opens as text, in `bat` when it is installed, else in `less`; `q` closes it.
--
-- Settings, in config.toml:
--
--   [plugins.settings]
--   quicklook = { key = "cmd+y", size = 1600 }   -- key = false binds none; size: pixels
--
-- Quick Look reads this Mac's files: for a remote host's pane, or a pane running ssh, it says
-- so rather than preview a local file of the same name.

local QLMANAGE = "/usr/bin/qlmanage"
-- A pane running one of these shows another machine.
local REMOTE_CLIENTS = { ssh = true, autossh = true, mosh = true, ["mosh-client"] = true }

local settings = thurm.settings
local size = math.tointeger(settings.size) or 1600

-- Stops with a reason for the user. The action shows it as a toast and returns it: an error
-- raised from an action reaches the user with this file's name and line in front, which is
-- for bugs.
local function fail(message)
  error({ refused = message }, 0)
end

local function is_file(path)
  -- io.open opens regular files only: a directory or a device is not one.
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function resolve(path, cwd)
  local home = os.getenv("HOME")
  if path == "~" or path:sub(1, 2) == "~/" then
    path = home .. path:sub(2)
  end
  if path:sub(1, 1) == "/" or not cwd then
    return path
  end
  return (cwd:gsub("/$", "")) .. "/" .. path
end

-- The last file the pane's screen names, as it is written there.
local function file_on_screen(pane, cwd)
  local ok, text = pcall(thurm.capture, pane)
  if not ok then
    return nil
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local tried = 0
  for i = #lines, 1, -1 do
    local words = {}
    for word in lines[i]:gmatch("[^%s\"'`]+") do
      words[#words + 1] = word
    end
    for j = #words, 1, -1 do
      -- `src/main.rs:12:5`, `(notes.txt).`, `file.pdf,`
      local word = words[j]:gsub("^[%(%[<]+", ""):gsub("[%)%]>,;:.]+$", ""):gsub(":%d+.*$", "")
      if word:find("[./]") and word ~= "." and word ~= ".." then
        if is_file(resolve(word, cwd)) then
          return word
        end
        tried = tried + 1
        if tried >= 200 then
          return nil
        end
      end
    end
  end
  return nil
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function show_text(pane, path, cwd)
  local bat = trim(thurm.exec("command -v bat").stdout)
  -- No quitting at once when the file fits the screen: the pane would close before you read it.
  local less = { "less", "-R", "-+F", "-+E", "--", path }
  local command = bat ~= "" and { bat, "--paging=always", "--", path } or less
  return thurm.open{
    command = command,
    env = { BAT_PAGER = "less -R -+F -+E" },
    cwd = cwd,
    float = true,
    target = pane,
  }
end

local function show_preview(pane, path, name)
  local tmp = thurm.exec({ "mktemp", "-d", "-t", "thurm-quicklook" })
  if not tmp.ok then
    fail("cannot make a temporary directory: " .. trim(tmp.stderr))
  end
  local dir = trim(tmp.stdout)
  -- -x: through quicklookd. Without it, qlmanage waits forever for a file it has no
  -- generator for; with it, it exits and writes nothing.
  local argv = { QLMANAGE, "-t", "-x", "-s", tostring(size), "-o", dir, path }
  local r = thurm.exec(argv, { timeout = 30 })
  local png = dir .. "/" .. name .. ".png"
  if not (r.ok and is_file(png)) then
    thurm.exec({ "rm", "-rf", dir })
    if r.timed_out then
      fail("Quick Look took too long on " .. name)
    end
    fail("no preview for " .. name)
  end
  -- The viewer deletes the PNG and the directory when it closes.
  return thurm.open{
    command = { "/bin/sh", thurm.dir .. "/view.sh", png, name },
    float = true,
    target = pane,
  }
end

local function preview(ctx, args)
  local pane = ctx.pane
  if not pane then
    fail("no pane of this Mac to preview for: Quick Look reads this Mac's files only")
  end
  if not is_file(QLMANAGE) then
    fail("qlmanage is missing: Quick Look needs macOS")
  end
  local info = thurm.info(pane)
  local fg = info.foreground and info.foreground.name
  if fg and REMOTE_CLIENTS[fg] then
    fail("the pane runs " .. fg .. ", and Quick Look previews this Mac's files only")
  end
  local cwd = info.cwd

  local path = type(args) == "table" and args.path or nil
  if not path then
    local default = file_on_screen(pane, cwd) or (cwd and (cwd:gsub("/$", "")) .. "/") or ""
    path = thurm.ui.input{ title = "Quick Look", placeholder = "A file", value = default }
    if not path or trim(path) == "" then
      return nil
    end
    path = trim(path)
  end
  if path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "~" and not cwd then
    fail("the pane's directory is unknown: give the full path of " .. path)
  end
  path = resolve(path, cwd)
  local name = path:match("([^/]+)/*$") or path

  local kind = thurm.exec({ "file", "-b", "--mime", "--", path })
  local mime = trim(kind.stdout)
  if not kind.ok or mime:find("^cannot open") then
    fail("no such file: " .. path)
  end
  if mime:find("^inode/directory") then
    fail(name .. " is a directory")
  end
  if not is_file(path) then
    fail(name .. " is not a regular file")
  end

  -- Text as text; an SVG or RTF file reads better as Quick Look draws it.
  local textual = mime:find("^inode/x%-empty")
    or not (mime:find("charset=binary") or mime:find("^image/") or mime:find("^text/rtf"))
  local opened = textual and show_text(pane, path, cwd) or show_preview(pane, path, name)
  return { pane = opened, path = path }
end

thurm.action{
  name = "quicklook.preview",
  title = "Quick Look",
  description = "Preview a file in a floating pane",
  category = "File",
  args = {
    type = "object",
    properties = {
      path = { type = "string", description = "The file; relative to the pane's directory" },
    },
  },
  run = function(ctx, args)
    local ok, result = pcall(preview, ctx, args)
    if ok then
      return result
    elseif type(result) == "table" and result.refused then
      thurm.ui.toast("Quick Look: " .. result.refused, ctx.pane)
      return { error = result.refused }
    end
    error(result, 0)
  end,
}

local key = settings.key
if key == nil then
  key = "cmd+y"
end
if key then
  thurm.bind(key, "quicklook.preview")
end
