#!/usr/bin/env luajit
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
// core XCB types & calls
typedef uint32_t xcb_window_t;
typedef int32_t  xcb_connection_t;
typedef struct	 xcb_connection_t xcb_connection_t;
typedef struct { xcb_connection_t *connection; int pad; } xcb_setup_t;
typedef struct {
  xcb_window_t root;
  uint16_t     width_in_pixels, height_in_pixels;
} xcb_screen_t;
typedef struct { xcb_screen_t *data; int rem; } xcb_screen_iterator_t;

typedef struct {
  uint8_t  response_type, pad0;
  uint16_t sequence;
  uint32_t timestamp;
  xcb_window_t window;
} xcb_map_request_event_t;

typedef struct {
  uint8_t  response_type, pad0;
  uint16_t sequence;
  xcb_window_t window;
} xcb_destroy_notify_event_t;

typedef struct {
  uint8_t  response_type, pad0;
  uint16_t sequence;
  uint32_t pad1;
  uint8_t  detail;
  uint8_t  pad2[7];
  xcb_window_t child;
} xcb_button_press_event_t;

typedef struct {
  uint8_t  response_type, pad0;
  uint16_t sequence;
  uint32_t value_mask;
  xcb_window_t window, sibling;
  int16_t      x, y;
  uint16_t     width, height;
  uint16_t     border_width, pad3;
} xcb_configure_request_event_t;

typedef union {
  uint8_t                     response_type;
  xcb_map_request_event_t     map_request;
  xcb_destroy_notify_event_t  destroy_notify;
  xcb_button_press_event_t    button_press;
  xcb_configure_request_event_t configure_request;
} xcb_generic_event_t;

typedef struct { 
  uint32_t sequence; 
} xcb_void_cookie_t;

// from <xcb/xproto.h>
typedef struct { 
	uint8_t  response_type;
	uint8_t  error_code;
	uint16_t sequence; 
	uint32_t resource_id;
	uint16_t minor_code;
	uint8_t  major_code;
	uint8_t  pad0;
} xcb_generic_error_t;

// connection & main calls
xcb_connection_t*    xcb_connect(const char*, int*);
int                  xcb_connection_has_error(xcb_connection_t*);
const void*          xcb_get_setup(xcb_connection_t*);
xcb_screen_iterator_t xcb_setup_roots_iterator(const void*);
xcb_generic_event_t* xcb_wait_for_event(xcb_connection_t*);
void                 xcb_disconnect(xcb_connection_t*);
int                  xcb_flush(xcb_connection_t*);

// window ops
xcb_void_cookie_t    xcb_map_window(xcb_connection_t*, xcb_window_t);
xcb_void_cookie_t    xcb_unmap_window(xcb_connection_t*, xcb_window_t);
xcb_void_cookie_t    xcb_configure_window(xcb_connection_t*, xcb_window_t, uint32_t, const uint32_t*);
xcb_void_cookie_t    xcb_change_window_attributes_checked(xcb_connection_t*, xcb_window_t, uint32_t, const void*);
xcb_generic_error_t* xcb_request_check(xcb_connection_t*, xcb_void_cookie_t);
xcb_void_cookie_t    xcb_set_input_focus(xcb_connection_t*, uint8_t, xcb_window_t, uint32_t);

// grabbing
int                  xcb_grab_button(xcb_connection_t*, uint8_t, xcb_window_t, uint32_t, uint8_t, uint8_t, xcb_window_t, xcb_window_t, uint8_t, uint32_t);
int                  xcb_allow_events(xcb_connection_t*, uint8_t, uint32_t);

// signals
typedef void (*sighandler_t)(int);
sighandler_t signal(int, sighandler_t);

// free
void free(void*);

// getpid
typedef int pid_t;
pid_t getpid(void);
]]

-- advertise our PID to a file for shxkd to grab it
local pidfile = os.getenv("XDG_RUNTIME_DIR").."/sparta.pid"
do
	local f = io.open(pidfile, "w")
	if f then f:write(tostring(ffi.C.getpid())) f:close() end
end

local C = ffi.load("xcb")
local SIG = ffi.C

local dpy_err = ffi.new("int[1]")
local dpy     = C.xcb_connect(nil, dpy_err)
assert(dpy ~= nil and dpy_err[0] == 0, "cannot connect to X server")

local setup  = C.xcb_get_setup(dpy)
local iter   = C.xcb_setup_roots_iterator(setup)
for i=1,dpy_err[0] do C.xcb_setup_roots_iterator(setup) end
local screen = iter.data
local root   = screen.root

local master, focus = nil, nil   -- head of client-list & focus-stack
local sw, sh         = screen.width_in_pixels, screen.height_in_pixels
local running        = true

-- signal flags
local SIGUSR1, SIGUSR2 = 10, 12
local fs_toggle, layout_cycle = false, false

local XCB_MAP_REQUEST        = 20
local XCB_CONFIGURE_REQUEST = 23
local XCB_BUTTON_PRESS       = 4
local XCB_DESTROY_NOTIFY     = 17

local function on_sigusr1(_) fs_toggle = true end
local function on_sigusr2(_) layout_cycle = true end
SIG.signal(SIGUSR1, ffi.cast("sighandler_t", on_sigusr1))
SIG.signal(SIGUSR2, ffi.cast("sighandler_t", on_sigusr2))

--- utilities

local function DIE(msg)
  io.stderr:write(msg)
  os.exit(1)
end

local function log_error(fmt, ...)
	local msg = string.format(fmt, ...)
	io.stderr:write("[ERROR]: ", msg, "\n")
end

local function move_resize(c, x, y, w, h)
  if not c then return end
  local mask = 0
  local vals = {}
  local i = 0
  local function set(fv, flag)
    if flag or c[fv.name] ~= fv.value then
      mask = bit.bor(mask, flag)
      vals[i] = fv.value; i = i + 1
      c[fv.name] = fv.value
    end
  end
  local force = (c.w == nil)
  set({name="x",     value=x},     bit.lshift(1, 0)) -- XCB_CONFIG_WINDOW_X
  set({name="y",     value=y},     bit.lshift(1, 1))
  set({name="width", value=w},     bit.lshift(1, 2))
  set({name="height",value=h},     bit.lshift(1, 3))
  if mask ~= 0 then
    C.xcb_configure_window(dpy, c.window, mask, ffi.new("uint32_t[4]", vals))
  end
end

local function add_focus(c)
  if c == focus then return end
  -- remove c from focus stack
  local prev = focus
  while prev and prev.focus_next ~= c do prev = prev.focus_next end
  if prev then prev.focus_next = c.focus_next end
  -- push front
  c.focus_next, focus = focus, c
end

local function raise_window(win)
  C.xcb_configure_window(dpy, win,
    bit.lshift(1, 8),                      -- XCB_CONFIG_WINDOW_STACK_MODE
    ffi.new("uint32_t[1]", {4})            -- ABOVE=4
  )
  C.xcb_set_input_focus(dpy, 1, win, 0)   -- Parent, CurrentTime
end

local function focus_client(c)
  if not c then return end
  add_focus(c)
  raise_window(c.window)
end

local function setup()
  -- claim root
  local SUBREDIRECT = bit.lshift(1, 8)
  local SUBNOTIFY   = bit.lshift(1,9)

  local event_mask = bit.bor(SUBREDIRECT, SUBNOTIFY)

  local CWEVENT_MASK = bit.lshift(1, 11)
  local ck = C.xcb_change_window_attributes_checked(
    dpy,
	root,
	CWEVENT_MASK,
	ffi.new("uint32_t[1]", { event_mask })
  )
  local err = C.xcb_request_check(dpy, ck) -- we own this!
  if err ~= nil then 
	  local errno = tonumber(err.error_code)
	  ffi.C.free(err) -- be a good steward of sys resources
	  log_error("%d", errno)
	  DIE("another WM is running\n") 
  end

  -- grab all mouse clicks on root
  local BUTTON_PRESS = 0x100
  local BUTTON_RELEASE = 0x200
  local mouse_event_mask = bit.bor(BUTTON_PRESS, BUTTON_RELEASE)
  C.xcb_grab_button(
	  dpy,				-- XCB conn
	  1,				-- owner_events (if 1, the grab window snitches
	  root,				-- the snitch (aka the grab_window)
	  mouse_event_mask, -- event_mask
	  1,				-- pointer_mode  (SYNC || ASYNC)
	  0,				-- keyboard_mode (""  "" "")
	  root,				-- confine_to window
	  0,				-- cursor
	  0,				-- button 
	  0					-- modifiers
  )
  C.xcb_flush(dpy)
end

local function find_client(win)
	local c = master
	while c do
		if c.window == win then 
			return c 
		end
		c = c.next
	end
  	return nil
end

local function add_window(win)
  local c = find_client(win)
  if c then return c end
  c = { window = win, focus_next = nil }
  if not master then master = c else
    local last = master
    while last.next do last = last.next end
    last.next = c
  end
  return c
end

local function map_request(ev)
  local c = add_window(ev.map_request.window)
  add_focus(c)
  arrange()
  C.xcb_map_window(dpy, c.window)
  focus_client(c)
end

local function button_press(ev)
  local c = find_client(ev.button_press.child)
  if c then
	  focus_client(c)
  end
  C.xcb_allow_events(dpy, 1, ev.button_press.sequence)
end

local function configure_request(ev)
  local win = ev.configure_request.window
  if not find_client(win) then
    -- pass through for unmanaged windows
    local vals, i = {}, 0
    local mask = ev.configure_request.value_mask
    local function grab(field, flag) 
      if bit.band(mask, flag) ~= 0 then
        vals[i] = ev.configure_request[field]; i=i+1
      end
    end
    grab("x",     bit.lshift(1,0))
    grab("y",     bit.lshift(1,1))
    grab("width", bit.lshift(1,2))
    grab("height",bit.lshift(1,3))
    grab("sibling",bit.lshift(1,4))
    grab("stack_mode",bit.lshift(1,5))
    C.xcb_configure_window(dpy, win, mask, ffi.new("uint32_t[6]", vals))
  end
end

local function destroy_notify(ev)
  local win = ev.destroy_notify.window
  -- 1) find the client object
  local c = find_client(win)
  if not c then return end

  -- 2) detach from master list
  if not master.next then
    -- only one client
    master = nil
  elseif master == c then
    -- first client
    master = c.next
  else
    -- middle or end
    local prev = master
    while prev.next and prev.next ~= c do
      prev = prev.next
    end
    if prev.next == c then
      prev.next = c.next
    end
  end

  -- 3) detach from focus stack
  if not focus.focus_next then
    -- only one focused
    focus = nil
  elseif focus == c then
    -- focused was head
    focus = c.focus_next
  else
    -- in the middle or end
    local prevf = focus
    while prevf.focus_next and prevf.focus_next ~= c do
      prevf = prevf.focus_next
    end
    if prevf.focus_next == c then
      prevf.focus_next = c.focus_next
    end
  end
end

local function arrange()
  -- 1) handle signal flags
  if fs_toggle and focus then
    fs_toggle = false
    -- only the top of the focus stack toggles fullscreen
    focus.fullscreen = not focus.fullscreen
  end
  if layout_cycle then
    layout_cycle = false
    layout = (layout == "tile") and "monocle" or "tile"
  end

  -- 2) collect all clients into a Lua array
  local list = {}
  local n = 0
  local node = master
  while node do
    n = n + 1
    list[n] = node
    node = node.next
  end

  if n == 0 then
    C.xcb_flush(dpy)
    return
  end

  -- 3) apply tile or monocle
  if layout == "monocle" then
    -- only the first (focused) client in list
    local c = list[1]
    move_resize(c, 0, 0, sw, sh)
  else
    local w = math.floor(sw / n)
    for i = 1, n do
      local c = list[i]
      move_resize(c, (i-1)*w, 0, w, sh)
    end
  end

  -- 4) flush once at the end
  C.xcb_flush(dpy)
end


-- Main loop
local function run()
	while running do
	  C.xcb_flush(dpy)
	  local ev = C.xcb_wait_for_event(dpy) -- We own this!
	  if not ev then break end
	  local code = bit.band(ev.response_type, 0x7F)
	  if     code == XCB_MAP_REQUEST  then map_request(ev)
	  elseif code == XCB_CONFIGURE_REQUEST  then configure_request(ev)
	  elseif code == XCB_BUTTON_PRESS  then button_press(ev)
	  elseif code == XCB_DESTROY_NOTIFY then destroy_notify(ev)
	  else
		  io.stderr:write("[sparta] err on event: ", code, "\n")
	  end

	  ffi.C.free(ev) -- free xcb_wait_for_event
	  arrange()
	end
end

local function main()
	setup()
	run()
	C.xcb_disconnect(dpy)
	os.exit(0)
end
main()

