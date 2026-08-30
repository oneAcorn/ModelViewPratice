class_name OrbitCamera
extends Node3D
## 轨道相机:目标点 + 偏航/俯仰 + 距离,所有量都做指数平滑插值,
## 外部(状态机)只需调 set_view()/set_limits() 即可得到平滑运镜。
##
## 输入约定:
## - 桌面:按住左键拖拽旋转,滚轮缩放
## - 触屏:单指拖拽旋转,双指捏合缩放
## - 触屏会模拟出鼠标事件(device == DEVICE_ID_EMULATION),鼠标分支要跳过,避免移动端双重响应

const ROTATE_SPEED := 0.005  # 弧度 / 像素
const WHEEL_STEP := 0.9      # 每格滚轮的距离系数
const SMOOTH := 7.0          # 平滑系数,越大跟随越快

@export var fov := 45.0
@export var min_pitch_deg := -80.0
@export var max_pitch_deg := 80.0

var camera: Camera3D

var _des_yaw := 0.0
var _des_pitch := 0.3
var _des_dist := 5.0
var _des_target := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.3
var _dist := 5.0
var _target := Vector3.ZERO
var _min_dist := 0.5
var _max_dist := 30.0
var _touches := {}  # 触点 index -> 当前屏幕坐标
var _pinch := 0.0   # 双指间距


func _ready() -> void:
	camera = $Camera3D
	camera.fov = fov
	camera.current = true
	_yaw = _des_yaw
	_pitch = _des_pitch
	_dist = _des_dist
	_apply()


func snap_to(target: Vector3, yaw: float, pitch: float, dist: float) -> void:
	## 立即摆好机位(初始帧用,不做插值动画)
	_des_target = target
	_des_yaw = yaw
	_des_pitch = pitch
	_des_dist = dist
	_target = target
	_yaw = yaw
	_pitch = pitch
	_dist = dist
	_apply()


func set_view(target: Vector3, dist: float) -> void:
	## 平滑移动到新机位
	_des_target = target
	_des_dist = clampf(dist, _min_dist, _max_dist)


func set_limits(min_dist: float, max_dist: float) -> void:
	_min_dist = min_dist
	_max_dist = max_dist
	_des_dist = clampf(_des_dist, _min_dist, _max_dist)


func fit_distance(radius: float, margin := 1.2) -> float:
	## 让半径为 radius 的包围球刚好入画的距离
	return radius / sin(deg_to_rad(fov) * 0.5) * margin


func _process(delta: float) -> void:
	var k := 1.0 - exp(-SMOOTH * delta)
	_yaw = lerpf(_yaw, _des_yaw, k)
	_pitch = lerpf(_pitch, _des_pitch, k)
	_dist = lerpf(_dist, _des_dist, k)
	_target = _target.lerp(_des_target, k)
	_apply()


func _apply() -> void:
	position = _target
	# pitch 取负:正值代表相机高于目标俯视
	rotation = Vector3(-_pitch, _yaw, 0.0)
	if camera:
		camera.position = Vector3(0.0, 0.0, _dist)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 2:
				_pinch = _spacing()
		else:
			_touches.erase(event.index)
			_pinch = _spacing()  # 剩一指时清零,避免捏合跳变
	elif event is InputEventScreenDrag:
		if _touches.has(event.index):
			_touches[event.index] = event.position
		if _touches.size() >= 2:
			var s := _spacing()
			if _pinch > 0.0 and s > 0.0:
				_des_dist = clampf(_des_dist * _pinch / s, _min_dist, _max_dist)
			_pinch = s
		elif _touches.size() == 1:
			_rotate(event.relative)
	elif event is InputEventMouseMotion \
			and event.button_mask & MOUSE_BUTTON_MASK_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		_rotate(event.relative)
	elif event is InputEventMouseButton and event.pressed \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_des_dist = clampf(_des_dist * WHEEL_STEP, _min_dist, _max_dist)
			MOUSE_BUTTON_WHEEL_DOWN:
				_des_dist = clampf(_des_dist / WHEEL_STEP, _min_dist, _max_dist)


func _rotate(rel: Vector2) -> void:
	_des_yaw -= rel.x * ROTATE_SPEED
	_des_pitch = clampf(_des_pitch - rel.y * ROTATE_SPEED,
			deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))


func _spacing() -> float:
	var v := _touches.values()
	return v[0].distance_to(v[1]) if v.size() >= 2 else 0.0
