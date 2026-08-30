extends Node3D
## 场景入口:灯光朝向、地面位置、中文字体兜底,以及随状态切换的 UI 提示。

@onready var _viewer: FishViewer = $FishViewer
@onready var _hint: Label = %HintLabel
@onready var _part: Label = %PartLabel
@onready var _back: Button = %BackButton

const HINTS := {
	FishViewer.State.WHOLE: "拖动旋转 · 滚轮 / 双指缩放 · 点击鱼进行拆解",
	FishViewer.State.SEPARATED: "点击某个部位查看细节 · 点击空白处返回整体",
	FishViewer.State.FOCUSED: "拖动旋转查看细节 · 点击空白处或按钮返回整体",
}


func _ready() -> void:
	$Sun.rotation_degrees = Vector3(-65.0, -20.0, 0.0)
	$Sun.directional_shadow_max_distance = 15.0  # 场景很小,收紧阴影范围换更高分辨率
	$Floor.position.y = _viewer.fish_bottom_y - 1.5
	_setup_ui_font()
	_back.pressed.connect(_viewer.merge_to_whole)
	_viewer.ui_blocker = _back
	_viewer.state_changed.connect(_on_state_changed)
	_on_state_changed(_viewer.state, &"")


func _on_state_changed(state: FishViewer.State, part_id: StringName) -> void:
	_hint.text = HINTS.get(state, "")
	if state == FishViewer.State.FOCUSED:
		_part.text = FishViewer.PART_TITLES.get(part_id, String(part_id))
		_part.visible = true
	else:
		_part.visible = false
	_back.visible = state != FishViewer.State.WHOLE


func _setup_ui_font() -> void:
	# Godot 内置默认字体不含中文字形,借用系统中文字体兜底,否则提示文字全是方框
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC",
		"Noto Sans CJK SC", "WenQuanYi Micro Hei", "sans-serif",
	])
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 16
	%UIRoot.theme = theme
