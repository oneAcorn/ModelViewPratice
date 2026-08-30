class_name FishViewer
extends Node3D
## 鱼的展示状态机:
## WHOLE(整体原地游动) --点击鱼--> SEPARATED(三段拆开悬浮)
## SEPARATED --点击某部位--> FOCUSED(镜头聚焦该部位,其余两段变暗消失)
## SEPARATED/FOCUSED --点击空白处或返回按钮--> WHOLE(合体,恢复游动)
##
## 拾取:运行时给每个部件的 MeshInstance3D 生成三剖分碰撞体(ConcavePolygonShape3D),
## 射线检测精确到网格表面,不需要手动摆碰撞盒。
## 淡出:复制材质并开启 alpha 透明,用 albedo_color 同步做"变暗 + 消失"。
## 游动:没有骨架,做程序化动画——根部起伏摇摆,各部件绕自身枢轴左右摆尾,
## 幅度头 < 身 < 尾、相位依次滞后,看起来像波动从头部传向尾部。

signal state_changed(state: State, part_id: StringName)

enum State { WHOLE, SEPARATED, FOCUSED }

const PART_TITLES := {&"Head": "鱼头", &"Body": "鱼身", &"Tail": "鱼尾"}
# 模型本身是纯白的,给三个部位着淡色区分,也方便聚焦时辨认
const PART_TINTS := {
	&"Head": Color(0.52, 0.62, 0.76),
	&"Body": Color(0.96, 0.93, 0.84),
	&"Tail": Color(0.85, 0.58, 0.38),
}
const SWIM_FREQ := 2.0       # 摆动角速度(弧度/秒)
const SPREAD_RATIO := 0.5    # 拆解位移 = 鱼长 * 该比例
const TAP_SLOP := 12.0       # 按下-抬起位移小于该值(像素)才算"点击"

@export var camera_rig: OrbitCamera

var state := State.WHOLE
var fish_bottom_y := 0.0  # 整鱼包围盒最低点,供场景摆放地面

# 点击落在该控件范围内时忽略(比如返回按钮,控件自己会消费事件)
var ui_blocker: Control

var _fish: Node3D
var _parts := {}  # StringName -> {pivot, pick, meshes, mats, base_colors, aabb, center, radius, rest_pos, offset, alpha, shown}
var _order: Array[StringName] = [&"Head", &"Body", &"Tail"]
var _axis := Vector3.BACK  # 鱼头朝向(fish 局部空间)
var _fish_len := 1.0
var _whole_box := AABB()
var _views := {}         # State -> {target, dist, min_dist, max_dist}
var _focus_views := {}   # StringName -> 同上
var swim_w := 1.0        # 游动幅度权重 0~1,过渡时由补间驱动
var _swim_t := 0.0
var _tween: Tween
var _busy := false       # 过渡动画期间屏蔽点击
var _touches := {}       # 触点 index -> 按下位置
var _mouse_press := Vector2.ZERO
var _mouse_down := false


func _ready() -> void:
	_fish = $Fish
	if camera_rig == null:  # 导出节点引用兜底
		camera_rig = get_node_or_null("../CameraRig")
	_setup_parts()
	_setup_layout()
	_setup_views()
	var v: Dictionary = _views[State.WHOLE]
	camera_rig.snap_to(v.target, deg_to_rad(24.0), deg_to_rad(14.0), v.dist)
	camera_rig.set_limits(v.min_dist, v.max_dist)


func _process(delta: float) -> void:
	if swim_w > 0.001:
		_swim_t += delta * SWIM_FREQ
	var w := swim_w
	var t := _swim_t
	# 根部:缓慢起伏 + 轻微俯仰/偏航/侧滚,给"水里悬浮"的感觉
	_fish.position.y = 0.05 * _fish_len * sin(t * 0.55) * w
	_fish.rotation = Vector3(0.03, 0.05, 0.02) * sin(t * 0.55 - 0.6) * w
	# 波动:尾幅最大、相位最滞后
	_set_wag(&"Head", 0.10, t, -0.15)
	_set_wag(&"Body", 0.05, t, -0.50)
	_set_wag(&"Tail", 0.40, t, -0.95)


func _set_wag(part_id: StringName, amp: float, t: float, phase: float) -> void:
	var p: Dictionary = _parts[part_id]
	p.pivot.rotation.y = amp * sin(t + phase) * swim_w


# ---------------------------------------------------------------- 状态切换

func separate() -> void:
	## WHOLE -> SEPARATED:停止游动,三段展开,镜头稍稍拉远
	if state != State.WHOLE or _busy:
		return
	_busy = true
	state = State.SEPARATED
	state_changed.emit(state, &"")
	_stop_tween()
	var tw := create_tween()
	_tween = tw
	tw.tween_property(self, "swim_w", 0.0, 0.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for i in _order.size():
		var p: Dictionary = _parts[_order[i]]
		tw.parallel().tween_property(p.pivot, "position", p.rest_pos + p.offset, 0.75) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT) \
				.set_delay(0.1 * i)
	var v: Dictionary = _views[State.SEPARATED]
	camera_rig.set_view(v.target, v.dist)
	camera_rig.set_limits(v.min_dist, v.max_dist)
	tw.chain().tween_callback(_unset_busy)


func merge_to_whole() -> void:
	## SEPARATED/FOCUSED -> WHOLE:隐藏的部件淡入,三段合体,恢复游动
	if state == State.WHOLE or _busy:
		return
	_busy = true
	state = State.WHOLE
	state_changed.emit(state, &"")
	_stop_tween()
	var tw := create_tween()
	_tween = tw
	for i in _order.size():
		var pid: StringName = _order[i]
		var p: Dictionary = _parts[pid]
		if not p.shown:  # 从 FOCUSED 回来:先淡入被隐藏的两段
			p.pivot.visible = true
			p.shown = true
			_set_part_shadows(pid, true)
			tw.parallel().tween_method(_set_part_alpha.bind(pid), 0.0, 1.0, 0.5) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(p.pivot, "position", p.rest_pos, 0.65) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT) \
				.set_delay(0.08 * i)
	tw.chain().tween_property(self, "swim_w", 1.0, 0.5) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_callback(_unset_busy)
	var v: Dictionary = _views[State.WHOLE]
	camera_rig.set_view(v.target, v.dist)
	camera_rig.set_limits(v.min_dist, v.max_dist)


func _focus(part_id: StringName) -> void:
	_busy = true
	state = State.FOCUSED
	state_changed.emit(state, part_id)
	_stop_tween()
	var tw := create_tween()
	_tween = tw
	for pid in _order:
		if pid == part_id:
			continue
		var p: Dictionary = _parts[pid]
		p.pick.collision_layer = 0  # 立即停用拾取,避免半透明时还能点中
		_set_part_shadows(pid, false)
		tw.parallel().tween_method(_set_part_alpha.bind(pid), 1.0, 0.0, 0.6) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_hide_others.bind(part_id))
	tw.chain().tween_callback(_unset_busy)
	var v: Dictionary = _focus_views[part_id]
	camera_rig.set_view(v.target, v.dist)
	camera_rig.set_limits(v.min_dist, v.max_dist)


func _unset_busy() -> void:
	_busy = false


func _stop_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()


# ---------------------------------------------------------------- 点击拾取

func pick_at(screen_pos: Vector2) -> void:
	## 处理一次点击:按当前状态决定拆解 / 聚焦 / 返回
	if _busy or camera_rig.camera == null:
		return
	if ui_blocker and ui_blocker.is_visible_in_tree() \
			and ui_blocker.get_global_rect().has_point(screen_pos):
		return  # 按钮等 UI 自己处理
	var cam := camera_rig.camera
	var from := cam.project_ray_origin(screen_pos)
	var to := from + cam.project_ray_normal(screen_pos) * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	match state:
		State.WHOLE:
			if not hit.is_empty():
				separate()
		State.SEPARATED:
			if hit.is_empty():
				merge_to_whole()
			else:
				_focus(hit.collider.get_meta("part_id"))
		State.FOCUSED:
			if hit.is_empty():
				merge_to_whole()


func _unhandled_input(event: InputEvent) -> void:
	# 点击 = 按下到抬起位移很小。拖拽旋转、双指捏合都不会误触发。
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		elif _touches.has(event.index):
			var start: Vector2 = _touches[event.index]
			_touches.erase(event.index)
			if _touches.is_empty() and event.position.distance_to(start) <= TAP_SLOP:
				pick_at(event.position)
	elif event is InputEventScreenDrag:
		# 拖拽会刷新触点位置,松手时比较的是最新位置,避免"转一圈回到原点"被当成点击
		if _touches.has(event.index):
			_touches[event.index] = event.position
	elif event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.pressed:
			_mouse_press = event.position
			_mouse_down = true
		elif _mouse_down:
			_mouse_down = false
			if event.position.distance_to(_mouse_press) <= TAP_SLOP:
				pick_at(event.position)


# ---------------------------------------------------------------- 部件准备

func _setup_parts() -> void:
	for part_id in _order:
		var part: Node3D = _fish.get_node(NodePath(String(part_id)))
		var rest_pos: Vector3 = part.position
		# 套一层枢轴:枢轴停在部件原位置,之后摇摆/拆解都只动枢轴,部件局部变换保持干净
		var pivot := Node3D.new()
		pivot.name = String(part_id) + "Pivot"
		_fish.add_child(pivot)
		pivot.position = rest_pos
		part.reparent(pivot)

		var meshes: Array[MeshInstance3D] = []
		_collect_meshes(part, meshes)

		# 拾取体:每个网格生成三剖分碰撞形状
		var pick := StaticBody3D.new()
		pick.name = "Pick"
		pick.collision_layer = 1
		pick.collision_mask = 0
		pick.set_meta("part_id", part_id)
		part.add_child(pick)
		var inv_pick: Transform3D = pick.global_transform.affine_inverse()
		for mi in meshes:
			var shape: ConcavePolygonShape3D = mi.mesh.create_trimesh_shape()
			if shape:
				var cs := CollisionShape3D.new()
				cs.shape = shape
				cs.transform = inv_pick * mi.global_transform
				pick.add_child(cs)

		# 材质:复制一份并着色,原材质不动;记录基准色供淡入淡出还原。
		# 平时保持不透明——alpha 混合的材质不参与投影,会导致整条鱼没有影子;
		# 只在淡出/淡入动画期间临时切到 ALPHA。
		var mats: Array[BaseMaterial3D] = []
		var base_colors: Array[Color] = []
		var tint: Color = PART_TINTS.get(part_id, Color.WHITE)
		for mi in meshes:
			for i in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(i)
				if m is BaseMaterial3D:
					var dup: BaseMaterial3D = m.duplicate()
					dup.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
					var c: Color = m.albedo_color
					c.r *= tint.r
					c.g *= tint.g
					c.b *= tint.b
					dup.albedo_color = c
					mi.set_surface_override_material(i, dup)
					mats.append(dup)
					base_colors.append(c)

		_parts[part_id] = {
			"pivot": pivot, "pick": pick, "meshes": meshes,
			"mats": mats, "base_colors": base_colors,
			"aabb": _meshes_aabb(meshes), "rest_pos": rest_pos,
			"offset": Vector3.ZERO, "alpha": 1.0, "shown": true,
		}
		var aabb: AABB = _parts[part_id].aabb
		_parts[part_id]["center"] = aabb.get_center()
		_parts[part_id]["radius"] = aabb.size.length() * 0.5


func _setup_layout() -> void:
	## 根据部件包围盒推鱼头朝向、鱼长、拆解位移
	_whole_box = _union_boxes(func(p: Dictionary) -> AABB: return p.aabb)
	var head: Dictionary = _parts[&"Head"]
	var tail: Dictionary = _parts[&"Tail"]
	_axis = (head.center - tail.center).normalized()
	_fish_len = maxf(absf(_axis.dot(_whole_box.size)), 0.1)
	fish_bottom_y = _whole_box.position.y
	_parts[&"Head"]["offset"] = _axis * SPREAD_RATIO * _fish_len
	_parts[&"Body"]["offset"] = Vector3.UP * 0.15 * _fish_len
	_parts[&"Tail"]["offset"] = -_axis * SPREAD_RATIO * _fish_len


func _setup_views() -> void:
	# 细长形体的包围球拟合很保守,边距收得比"刚好入画"更紧
	_views[State.WHOLE] = _make_view(_whole_box, 0.78, 0.4, 2.2)
	var sep_box := _union_boxes(
			func(p: Dictionary) -> AABB: return _box_offset(p.aabb, p.offset))
	_views[State.SEPARATED] = _make_view(sep_box, 0.72, 0.4, 2.4)
	for pid in _order:
		var p: Dictionary = _parts[pid]
		_focus_views[pid] = _make_view(_box_offset(p.aabb, p.offset), 1.15, 0.5,
				_views[State.WHOLE].dist * 1.2)


func _box_offset(b: AABB, off: Vector3) -> AABB:
	return AABB(b.position + off, b.size)


func _make_view(box: AABB, margin: float, min_scale: float, max_scale: float) -> Dictionary:
	var dist := camera_rig.fit_distance(box.size.length() * 0.5, margin)
	return {
		"target": _fish.global_transform * box.get_center(),
		"dist": dist,
		"min_dist": dist * min_scale,
		"max_dist": dist * max_scale,
	}


func _union_boxes(get_box: Callable) -> AABB:
	var out := AABB()
	var first := true
	for pid in _order:
		var box: AABB = get_box.call(_parts[pid])
		out = _box_union(out, box) if not first else box
		first = false
	return out


func _box_union(a: AABB, b: AABB) -> AABB:
	var lo := a.position.min(b.position)
	var hi := a.end.max(b.end)
	return AABB(lo, hi - lo)


func _meshes_aabb(meshes: Array[MeshInstance3D]) -> AABB:
	## 所有网格合并到 fish 局部空间的包围盒
	var inv: Transform3D = _fish.global_transform.affine_inverse()
	var out := AABB()
	var first := true
	for mi in meshes:
		var box: AABB = inv * (mi.global_transform * mi.get_aabb())
		out = _box_union(out, box) if not first else box
		first = false
	return out


func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D and n.mesh:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)


# ---------------------------------------------------------------- 淡入淡出

func _set_part_alpha(a: float, part_id: StringName) -> void:
	## a 从 1 到 0:颜色同步压暗,视觉上是"变暗直到消失"
	## (tween_method 把插值作为第一个实参,部件 id 由 bind 追加)
	var p: Dictionary = _parts[part_id]
	p.alpha = a
	var mats: Array = p.mats
	var cols: Array = p.base_colors
	for i in mats.size():
		var mat: BaseMaterial3D = mats[i]
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if a < 0.999 \
				else BaseMaterial3D.TRANSPARENCY_DISABLED
		var base: Color = cols[i]
		mat.albedo_color = Color(base.r * a, base.g * a, base.b * a, a)


func _hide_others(keep: StringName) -> void:
	for pid in _order:
		if pid != keep:
			var p: Dictionary = _parts[pid]
			p.pivot.visible = false
			p.shown = false


func _set_part_shadows(part_id: StringName, on: bool) -> void:
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for mi in _parts[part_id].meshes:
		mi.cast_shadow = mode
