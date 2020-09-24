import ../godotapi / [spatial],
       godot, tables, math, sets, sugar, sequtils, hashes, os,
       core, globals, engine, pen

gdobj Builder of Spatial:
  var
    draw_mode* {.gdExport.}: DrawMode
    script_index* {.gdExport.} = 0
    enu_script* {.gdExport.} = "none"
    paused* = true
    schedule_save* = false
    engine: Engine
    callback: proc(delta: float): bool
    is_running = false
    index: int = 1
    blocks_per_frame = 0.0
    blocks_remaining_this_frame = 0.0
    speed = 0.0
    direction = FORWARD
    position = vec3()
    drawing = true
    save_points: Table[string, tuple[position: Vector3, direction: Vector3, index: int]]
    voxes: VoxSet
    pen: Pen
    grid: Node

  proc `running=`*(val: bool) =
    self.is_running = val
    if not val:
      debug(self.enu_script & " done.")

  proc running*: bool = self.is_running

  proc set_defaults() =
    self.direction = FORWARD
    self.position = self.translation
    self.speed = 30.0
    self.index = 0
    self.drawing = true

  proc load_vars() =
    var old_speed = self.speed
    self.speed = self.engine.get_float("speed", "grid")
    self.index = self.engine.get_int("color", "grid")
    self.drawing = self.engine.get_bool("drawing", "grid")
    self.blocks_per_frame = if self.speed == 0:
      float.high
    else:
      self.speed.float / 30.0
    if self.speed != old_speed:
      self.blocks_remaining_this_frame = 0

  method physics_process*(delta: float64) =
    if not self.paused:
      self.blocks_remaining_this_frame += self.blocks_per_frame
      try:
        if self.engine.is_nil:
          # if we load paused we won't have a script engine yet
          self.load_script()
        if self.blocks_per_frame > 0:
          while self.running and self.blocks_remaining_this_frame >= 1:
            if self.callback == nil or not self.callback(delta):
              self.running = self.engine.resume()
        else:
          if self.running and (self.callback == nil or not self.callback(delta)):
              self.running = self.engine.resume()

      except VMQuit as e:
        self.error(e)

    if self.schedule_save:
      self.schedule_save = false
      save_scene()

  proc set_vars() =
    self.engine.call_proc("set_vars", module_name = "grid", self.index, self.drawing, self.speed)

  proc move(direction: Vector3, steps: BiggestInt): bool =
    self.load_vars()
    var count = 0
    self.callback = proc(delta: float): bool =
      while count < steps and self.blocks_remaining_this_frame >= 1:
        self.position += direction
        inc count
        self.blocks_remaining_this_frame -= 1
        self.drop_block()
      return count < steps
    true

  proc turn(degrees: float): bool =
    self.load_vars()
    var direction = self.direction
    direction = direction.rotated(UP, deg_to_rad(degrees))

    self.direction = vec3(direction.x.round, direction.y.round, direction.z.round)
    false

  proc sleep(seconds: float): bool =
    var duration = 0.0
    self.blocks_per_frame = 0.0
    self.blocks_remaining_this_frame = 0.0
    self.callback = proc(delta: float): bool =
      duration += delta
      return duration < seconds
    true

  proc save(name: string): bool =
    self.load_vars()
    self.save_points[name] = (
      position: self.position,
      direction: self.direction,
      index: self.index
    )
    false

  proc restore(name: string): bool =
    (self.position, self.direction, self.index) = self.save_points[name]
    self.set_vars()
    false

  proc forward(steps: BiggestInt): bool = self.move(self.direction, steps)
  proc back(steps: BiggestInt): bool = self.move(-self.direction, steps)
  proc up(steps: BiggestInt): bool = self.move(UP, steps)
  proc down(steps: BiggestInt): bool = self.move(DOWN, steps)
  proc left(degrees: float): bool = self.turn(degrees)
  proc right(degrees: float): bool = self.turn(-degrees)

  proc error(e: ref VMQuit) =
    self.running = false
    errors[self.enu_script] = @[(e.msg, e.info)]
    err e.msg
    trigger("script_error")

  proc clear() =
    var removing: seq[Vox]
    for v in self.voxes.blocks:
      if v.save_kind == SaveBuilder:
        self.pen.draw(v.vec3, -1, save = SaveNone)
        removing.add v
    for v in removing: self.voxes.blocks.excl v

  proc reset(clear = true) =
    self.set_defaults()
    if self.engine.initialized: self.set_vars()
    if clear:
      self.clear()
      self.pen.draw(self.position, 1, save = SaveUser)

  proc drop_block() =
    if self.drawing:
      self.pen.draw(self.position, self.index, save = SaveBuilder)

  proc build() =
    if not file_exists(self.enu_script):
      os.copy_file "scripts/default_grid.nim", self.enu_script

    if not self.schedule_save and self.draw_mode == VoxelMode and self.voxes.blocks.len <= 1:
      self.paused = false
    self.position = self.translation
    self.pen.draw(self.position, action_index - 1, save = SaveUser)
    self.load_script()

  method on_game_ready*() =
    self.build()

  method ready*() =
    self.voxes = VoxSet()
    self.grid = self.get_node("Grid")
    assert self.grid != nil
    self.bind_signals self, "selected"
    self.bind_signals "game_ready", "reload", "pause", "reload_all"
    if self.script_index == 0:
      inc max_grid_index
      self.script_index = max_grid_index
      self.paused = true
    elif self.script_index > max_grid_index:
      max_grid_index = self.script_index

    self.enu_script = &"scripts/grid_{self.script_index}.nim"
    self.pen = self.draw_mode.init(self, self.enu_script, self.voxes)

    if self.schedule_save:
      self.build()

  proc load_script() =
    if self.enu_script == "none":# or self.paused:
      # can't use empty string because it gets set as nil, which is no longer valid nim.
      # can probably be fixed in godot-nim
      return
    var t = now()
    debug &"Loading {self.enu_script}. Paused {self.paused}"
    errors[self.enu_script] = @[]
    self.callback = nil
    self.blocks_remaining_this_frame = 0
    try:
      #if self.engine.is_nil:
      self.engine = Engine()
      if not (self.paused or self.engine.initialized):
        with self.engine:
          load(self.enu_script)
          expose("grid", "up", a => self.up(get_int(a, 0)))
          expose("grid", "down", a => self.down(get_int(a, 0)))
          expose("grid", "forward", a => self.forward(get_int(a, 0)))
          expose("grid", "back", a => self.back(get_int(a, 0)))
          expose("grid", "left", a => self.left(get_float(a, 0)))
          expose("grid", "right", a => self.right(get_float(a, 0)))
          expose("grid", "print", a => print(get_string(a, 0)))
          expose("grid", "echo", a => echo_console(get_string(a, 0)))
          expose("grid", "sleep", a => self.sleep(get_float(a, 0)))
          expose("grid", "save", a => self.save(get_string(a, 0)))
          expose("grid", "restore", a => self.restore(get_string(a, 0)))
          expose "grid", "reset", proc(a: VmArgs): bool =
            self.reset(get_bool(a, 0))
            false
        self.running = self.engine.run()
    except VMQuit as e:
      self.error(e)

  method on_selected() =
    show_editor self.enu_script, self.engine

  method reload() =
    self.reset()
    self.paused = false
    self.load_script()

  method on_reload*() =
    if not editing() or open_file == self.enu_script:
      self.reload()

  method on_reload_all*() =
    self.reload()

  method on_pause*() =
    self.paused = not self.paused