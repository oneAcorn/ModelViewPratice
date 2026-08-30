extends SceneTree
## 输入链路自检(窗口模式):合成真实的鼠标/触摸事件,验证
## 点击拆解 → 触摸聚焦 → 拖拽旋转 → 滚轮缩放 → 空白处触摸返回 全链路。

var main: Node
var viewer: Node
var n := 0
var phase := 0
var yaw_before := 0.0
var dist_before := 0.0
var results: Array[String] = []


func _initialize() -> void:
	main = load("res://fish/main.tscn").instantiate()
	root.add_child(main)
	viewer = main.get_node("FishViewer")


func _idle(extra := 10) -> bool:
	n += 1
	return not viewer._busy and n > extra


func _next() -> void:
	phase += 1
	n = 0


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	ev.device = 0  # 真实鼠标
	Input.parse_input_event(ev)


func _wheel(pos: Vector2, up: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = pos
	ev.global_position = pos
	ev.device = 0
	Input.parse_input_event(ev)


func _touch(pos: Vector2, pressed: bool, idx := 0) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = idx
	ev.pressed = pressed
	ev.position = pos
	ev.device = 0
	Input.parse_input_event(ev)


func _motion(pos: Vector2, rel: Vector2, drag: bool) -> void:
	if drag:
		var ev := InputEventScreenDrag.new()
		ev.index = 0
		ev.position = pos
		ev.relative = rel
		ev.device = 0
		Input.parse_input_event(ev)
	else:
		var ev := InputEventMouseMotion.new()
		ev.position = pos
		ev.global_position = pos
		ev.relative = rel
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
		ev.device = 0
		Input.parse_input_event(ev)


func _screen(world: Vector3) -> Vector2:
	var cam: Camera3D = main.get_node("CameraRig").camera
	return cam.unproject_position(viewer._fish.global_transform * world)


func _check(label: String, ok: bool) -> void:
	results.append("%s %s" % ["PASS" if ok else "FAIL", label])
	print(("PASS: " if ok else "FAIL: ") + label)


func _process(_delta: float) -> bool:
	n += 1
	match phase:
		0:
			if _idle(20):
				var p := _screen(viewer._parts[&"Body"].center)
				_mouse_button(p, true)
				_mouse_button(p, false)
				_next()
		1:  # 鼠标点击鱼身 → 拆解
			if _idle():
				_check("鼠标点击 → SEPARATED", viewer.state == viewer.State.SEPARATED)
				_next()
		2:  # 触摸点击鱼头 → 聚焦
			if _idle():
				var head: Dictionary = viewer._parts[&"Head"]
				var p := _screen(head.center + head.offset)
				_touch(p, true)
				_touch(p, false)
				_next()
		3:
			if _idle():
				_check("触摸点击 → FOCUSED(head)", viewer.state == viewer.State.FOCUSED
						and viewer._parts[&"Head"].shown
						and not viewer._parts[&"Body"].shown)
				yaw_before = main.get_node("CameraRig")._des_yaw
				dist_before = main.get_node("CameraRig")._des_dist
				_next()
		4:  # 单指按下 → 拖拽旋转 + 滚轮缩放 → 抬起
			_touch(Vector2(576, 324), true)
			for i in 10:
				_motion(Vector2(576, 324), Vector2(30, 0), true)
			_touch(Vector2(900, 324), false)
			_wheel(Vector2(576, 324), false)
			_next()
		5:
			if _idle(5):
				var rig: Node = main.get_node("CameraRig")
				_check("拖拽旋转生效", not is_equal_approx(rig._des_yaw, yaw_before))
				_check("滚轮缩放生效", rig._des_dist > dist_before)
				_check("拖拽没有误判为点击", viewer.state == viewer.State.FOCUSED)
				_touch(Vector2(80, 80), true)
				_touch(Vector2(80, 80), false)  # 空白处触摸 → 合体
				_next()
		6:
			if _idle():
				_check("空白触摸 → WHOLE", viewer.state == viewer.State.WHOLE)
				var p := _screen(viewer._parts[&"Body"].center)
				_mouse_button(p, true)
				_mouse_button(p, false)  # 再次拆解,为按钮测试做准备
				_next()
		7:
			if _idle():
				var btn: Button = main.get_node("UI/UIRoot/BackButton")
				var c := btn.get_global_rect().get_center()
				_mouse_button(c, true)
				_mouse_button(c, false)  # 点返回按钮 → 合体(且 ui_blocker 屏蔽拾取)
				_next()
		8:
			if _idle():
				_check("返回按钮 → WHOLE", viewer.state == viewer.State.WHOLE)
				_next()
		9:
			print("----")
			for r in results:
				print(r)
			quit()
	return false
