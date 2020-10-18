import ../godotapi/[grid_map, mesh_library, mesh, spatial],
       godot, sets,
       core, globals, builder

gdobj Grid of GridMap:
  var
    highlight_material* {.gdExport}: Material
    original_materials: seq[Material]
    kept_blocks: HashSet[Vox]
    point, normal, draw_plane: Vector3

  proc build_unique_mesh_library() =
    self.mesh_library = self.mesh_library.duplicate().as(MeshLibrary)
    for index in self.mesh_library.get_item_list():
      let mesh = self.mesh_library.get_item_mesh(index).duplicate().as(Mesh)
      self.mesh_library.set_item_mesh(index, mesh)
      self.original_materials.add(mesh.surface_get_material(0))

  method ready*() =
    let signals = w"target_in target_out target_move target_fire target_remove"
    self.bind_signals(self, signals)
    self.build_unique_mesh_library()

  proc highlight() =
    let lib = self.mesh_library
    for index in lib.get_item_list():
      let mesh = lib.get_item_mesh(index)
      mesh.surface_set_material(0, self.highlight_material)

  proc clear_highlight() =
    let lib = self.mesh_library
    for index in lib.get_item_list():
      let mesh = lib.get_item_mesh(index)
      mesh.surface_set_material(0, self.original_materials[index])

  proc draw*(x, y, z: float, index: int, keep = false) =
    var index = index - 1
    let map_point = vec3(x, y, z)
    self.set_cell_item(int(map_point.x), int(map_point.y), int(map_point.z), index)
    let vox = (map_point, index, 0, keep)
    if keep and index > -1:
      self.kept_blocks.excl vox
      self.kept_blocks.incl vox
    else:
      self.kept_blocks.excl vox

  proc clear*(all = false) =
    self.as(GridMap).clear()
    if all:
      self.kept_blocks.clear()
    else:
      for vox in self.kept_blocks:
        let loc = vox.location
        self.set_cell_item(int loc.x, int loc.y, int loc.z, vox.index)

  proc export_data*(): seq[Vox] =
    for v in self.get_used_cells():
      let
        loc = v.asVector3()
        index = self.get_cell_item(int loc.x, int loc.y, int loc.z)

      var vox: Vox = (loc, int index + 1, 0, false)
      if vox in self.kept_blocks:
        vox.keep = true
      result.add(vox)

  proc import_data*(data: seq[Vox]) =
    for vox in data:
      let l = vox.location
      self.draw(l.x, l.y, l.z, vox.index, vox.keep)

  method on_target_in() =
    if tool_mode == CodeMode:
      self.highlight()

  method on_target_out() =
    self.clear_highlight()

  method on_target_move(point, normal: Vector3) =
    self.point = point - self.get_parent.as(Spatial).translation
    self.normal = normal

    if fire_down and tool_mode == BlockMode:
      let plane = self.point * self.normal
      if self.draw_plane == plane:
        self.on_target_fire()
    elif remove_down and tool_mode == BlockMode:
      let plane = self.point * self.normal
      if self.draw_plane == plane:
        self.on_target_remove()
    elif not remove_down and not fire_down:
      self.draw_plane = vec3()

  method on_target_fire() =
    if tool_mode == BlockMode:
      let point = self.world_to_map(self.point + self.normal * 0.5)
      self.draw(point.x, point.y, point.z, action_index, true)
      self.draw_plane = self.point * self.normal
      self.trigger("grid_block_added", point, action_index)
    else:
      self.clear_highlight()
      self.trigger("selected")

  method on_target_remove() =
    if tool_mode == BlockMode:
      let point = self.world_to_map(self.point - (self.normal * 0.5))
      let index = self.get_cell_item(int point.x, int point.y, int point.z).int
      self.draw(point.x, point.y, point.z, 0)
      self.draw_plane = self.point * self.normal
      if self.get_used_cells().len == 0:
        self.trigger("deleted")
      else:
        let keep = (point, 0, 0, false) in self.kept_blocks
        self.trigger("grid_block_removed", point, index, keep)
