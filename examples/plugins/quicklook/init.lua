-- quicklook: a Quick Look preview of a file, in a floating pane over the one you are in.
--
-- Install: link this directory into your plugins directory, then reload.
--
--   ln -s "$PWD/examples/plugins/quicklook" ~/.config/thurm/plugins/quicklook
--   thurm reload
--
-- Use:
--
--   cmd+y        previews the file you selected, or the one the mouse pointer is over;
--                when neither is a file, asks for one, starting from the last file the
--                pane shows
--   thurm action run quicklook.preview '{"path":"report.pdf"}'
--   thurm.run("quicklook.preview", { path = "~/Desktop/shot.png" })      -- from Lua
--
-- A relative path is taken from the pane's directory. The file shows as the thumbnail Quick
-- Look makes for it (an image, a PDF's or a document's first page, the start of a text file),
-- in a card shaped like it, drawn with the kitty graphics protocol; any key closes it. A text
-- file Quick Look has no generator for (no extension, `.toml`, `.yaml`) is drawn as plain text.
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

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- `test -f` reads a file's type without opening it: opening a named pipe waits for a writer.
local function is_file(path)
  return thurm.exec({ "/bin/test", "-f", path }).ok
end

-- The index of the first of `paths` that is a regular file, checked in one run.
local function first_file(paths)
  if #paths == 0 then
    return nil
  end
  local r = thurm.exec({
    "/bin/sh", "-c", 'i=0; for f; do i=$((i + 1)); [ -f "$f" ] && echo "$i" && exit; done; exit 1',
    "sh", table.unpack(paths),
  })
  return r.ok and tonumber(trim(r.stdout)) or nil
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
  -- The words that may name a file, last first, checked 200 at a time: the first batch with a
  -- file in it has the last one.
  local words, paths = {}, {}
  local function check()
    local found = words[first_file(paths)]
    words, paths = {}, {}
    return found
  end
  for i = #lines, 1, -1 do
    local line = {}
    for word in lines[i]:gmatch("[^%s\"'`]+") do
      line[#line + 1] = word
    end
    for j = #line, 1, -1 do
      -- `src/main.rs:12:5`, `(notes.txt).`, `file.pdf,`
      local word = line[j]:gsub("^[%(%[<]+", ""):gsub("[%)%]>,;:.]+$", ""):gsub(":%d+.*$", "")
      if word:find("[./]") and word ~= "." and word ~= ".." then
        words[#words + 1] = word
        paths[#paths + 1] = resolve(word, cwd)
        if #paths >= 200 then
          local found = check()
          if found then
            return found
          end
        end
      end
    end
  end
  return check()
end

-- The file to preview: the one asked for, else the selection or the file under the pointer
-- when it is one, else the user's answer. Nil when they cancel.
local function choose(ctx, args, cwd)
  if type(args) == "table" and args.path then
    return args.path
  end
  local selection = ctx.selection and trim(ctx.selection)
  if selection == "" or (selection and selection:find("\n")) then
    selection = nil
  end
  if selection and is_file(resolve(selection, cwd)) then
    return selection
  end
  if ctx.file and is_file(resolve(ctx.file, cwd)) then
    return ctx.file
  end
  -- A selection or a pointer path that is not a file is no default: the screen's file is.
  local default = file_on_screen(ctx.pane, cwd)
    or (cwd and (cwd:gsub("/$", "")) .. "/") or ""
  local path = thurm.ui.input{ title = "Quick Look", placeholder = "A file", value = default }
  if path and trim(path) ~= "" then
    return trim(path)
  end
  return nil
end

-- A PNG's width and height, from its header.
local function png_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(2, 4) ~= "PNG" then
    return nil
  end
  return string.unpack(">I4I4", head, 17)
end

-- Cells for a card over `pane`, centered: `cols` by `rows`, or less when the pane is smaller.
local function centered(pane_size, cols, rows)
  cols = math.max(20, math.min(cols, pane_size.cols))
  rows = math.max(4, math.min(rows, pane_size.rows))
  return {
    cols = cols,
    rows = rows,
    col = (pane_size.cols - cols) // 2,
    row = (pane_size.rows - rows) // 2,
  }
end

-- A card for an image `w` by `h` pixels: as large as fits in most of the pane, shaped like the
-- image, with a line below it for its name.
local function image_card(pane_size, w, h)
  local cw = pane_size.cell_width > 0 and pane_size.cell_width or 8
  local ch = pane_size.cell_height > 0 and pane_size.cell_height or 16
  local room_w = math.floor(pane_size.cols * 0.9) * cw
  local room_h = (math.floor(pane_size.rows * 0.9) - 1) * ch
  local scale = math.min(room_w / w, room_h / h)
  local cols = math.ceil(w * scale / cw)
  local rows = math.ceil(h * scale / ch) + 1
  return centered(pane_size, cols, rows)
end

-- Quick Look's thumbnail of `path`, written into `dir`: its PNG, or nil.
local function thumbnail(path, name, dir)
  -- -x: through quicklookd. Without it, qlmanage waits forever for a file it has no
  -- generator for; with it, it exits and writes nothing.
  local r = thurm.exec({ QLMANAGE, "-t", "-x", "-s", tostring(size), "-o", dir, path }, { timeout = 30 })
  if r.timed_out then
    thurm.exec({ "rm", "-rf", dir })
    thurm.fail("Quick Look took too long on " .. name)
  end
  local png = dir .. "/" .. name .. ".png"
  return r.ok and png_size(png) and png or nil
end

-- The thumbnail of a text file Quick Look has no generator for (no extension, `.toml`,
-- `.yaml`): made from a `.txt` copy of its start, which is all a thumbnail shows. Forcing
-- plain text with `qlmanage -c` draws black text on a dark page, and quicklookd skips a
-- `.txt` symlink.
local function text_thumbnail(path, name, dir)
  local copy = dir .. "/" .. name .. ".txt"
  -- head, not io.open: a file swapped for a named pipe since it was checked times out.
  local r = thurm.exec(
    { "/bin/sh", "-c", 'exec /usr/bin/head -c 65536 -- "$1" > "$2"', "sh", path, copy },
    { timeout = 5 }
  )
  if not r.ok then
    os.remove(copy)
    return nil
  end
  local png = thumbnail(copy, name .. ".txt", dir)
  os.remove(copy)
  return png
end

local function show_preview(pane, info, path, name, textual)
  -- macOS's mktemp: GNU's, from Nix or Homebrew, wants X's in the template.
  local tmp = thurm.exec({ "/usr/bin/mktemp", "-d", "-t", "thurm-quicklook" })
  if not tmp.ok then
    thurm.fail("cannot make a temporary directory: " .. trim(tmp.stderr))
  end
  local dir = trim(tmp.stdout)
  local png = thumbnail(path, name, dir)
  if not png and textual then
    png = text_thumbnail(path, name, dir)
  end
  local w, h
  if png then
    w, h = png_size(png)
  end
  if not w then
    thurm.exec({ "rm", "-rf", dir })
    thurm.fail("no Quick Look preview for " .. name)
  end
  -- The viewer deletes the PNG and the directory when it closes; without a viewer, they go here.
  local ok, opened = pcall(thurm.open, {
    -- The card shares the pane's font, so its cells are the pane's size.
    command = {
      "/bin/sh", thurm.dir .. "/view.sh", png, name,
      tostring(info.size.cell_width), tostring(info.size.cell_height),
    },
    target = pane,
    float = true,
    cells = image_card(info.size, w, h),
  })
  if not ok then
    thurm.exec({ "rm", "-rf", dir })
    error(opened, 0)
  end
  return opened
end

local function preview(ctx, args)
  if ctx.remote then
    thurm.fail("the pane is on " .. ctx.remote .. ", and Quick Look reads this Mac's files only")
  end
  local pane = ctx.pane
  if not pane then
    thurm.fail("no pane of this Mac to preview for")
  end
  if not is_file(QLMANAGE) then
    thurm.fail("qlmanage is missing: Quick Look needs macOS")
  end
  local info = thurm.info(pane)
  local fg = info.foreground and info.foreground.name
  if fg and REMOTE_CLIENTS[fg] then
    thurm.fail("the pane runs " .. fg .. ", and Quick Look reads this Mac's files only")
  end
  local cwd = info.cwd

  local path = choose(ctx, args, cwd)
  if not path then
    return nil
  end
  if path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "~" and not cwd then
    thurm.fail("the pane's directory is unknown: give the full path of " .. path)
  end
  path = resolve(path, cwd)
  local name = path:match("([^/]+)/*$") or path

  local kind = thurm.exec({ "file", "-b", "--mime", "--", path })
  local mime = trim(kind.stdout)
  if not kind.ok or mime:find("^cannot open") then
    thurm.fail("no such file: " .. path)
  end
  if mime:find("^inode/directory") then
    thurm.fail(name .. " is a directory")
  end
  if not is_file(path) then
    thurm.fail(name .. " is not a regular file")
  end

  local textual = mime:find("charset=binary") == nil or mime:find("^inode/x%-empty") ~= nil
  return { pane = show_preview(pane, info, path, name, textual), path = path }
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
  run = preview,
}

local key = settings.key
if key == nil then
  key = "cmd+y"
end
if key then
  thurm.bind(key, "quicklook.preview")
end
