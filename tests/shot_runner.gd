extends SceneTree
## 视觉自检脚本(窗口模式运行):
##   godot --path . -s tests/shot_runner.gd
## 依次驱动 整体游动 → 拆解 → 聚焦鱼头 → 返回合体,各阶段截图到 tests/out/。
## 过渡是补间驱动的,所以每次点击前都等 viewer 空闲,不依赖固定帧数。

var main: Node
var viewer: Node
var phase := 0
var n := 0  # 当前阶段的帧计数


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/out"))
	main = load("res://fish/main.tscn").instantiate()
	root.add_child(main)
	viewer = main.get_node("FishViewer")


func _idle(extra := 15) -> bool:
	## 过渡结束且再稳定 extra 帧后返回 true
	return not viewer._busy and n > extra


func _process(_delta: float) -> bool:
	n += 1
	match phase:
		0:  # 初始整体 + 游动两个相位
			if n == 20:
				_shot("1_whole_a")
			elif n == 80:
				_shot("2_whole_b")
			elif n >= 85:
				print("[dbg] pick body -> ", _ray(_screen(viewer._parts[&"Body"].center)))
				viewer.pick_at(_screen(viewer._parts[&"Body"].center))
				_next()
		1:  # 拆解完成 → 截图 → 点鱼头
			if _idle():
				_shot("3_separated")
				var head: Dictionary = viewer._parts[&"Head"]
				print("[dbg] pick head -> ", _ray(_screen(head.center + head.offset)))
				viewer.pick_at(_screen(head.center + head.offset))
				_next()
		2:  # 聚焦鱼头完成 → 截图 → 点空白返回
			if _idle():
				_shot("4_focus_head")
				viewer.pick_at(Vector2(90, 90))
				_next()
		3:  # 合体完成 → 截图 → 结束
			if _idle(30):
				_shot("5_merged_whole")
				print("[dbg] final state=", viewer.state)
				quit()
	return false


func _next() -> void:
	phase += 1
	n = 0


func _ray(pos: Vector2) -> String:
	var cam: Camera3D = main.get_node("CameraRig").camera
	var from := cam.project_ray_origin(pos)
	var to := from + cam.project_ray_normal(pos) * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit: Dictionary = viewer.get_world_3d().direct_space_state.intersect_ray(q)
	return "MISS" if hit.is_empty() else String(hit.collider.get_path())


func _screen(world: Vector3) -> Vector2:
	var cam: Camera3D = main.get_node("CameraRig").camera
	return cam.unproject_position(viewer._fish.global_transform * world)


func _shot(tag: String) -> void:
	var img := root.get_texture().get_image()
	var path := "res://tests/out/%s.png" % tag
	img.save_png(ProjectSettings.globalize_path(path))
	print("saved ", path)
