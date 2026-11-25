extends RefCounted
## 脱垂触发源接口。每种方式（钢球扯出、以后的腹压 / 手法牵拉 / 剧情）实现一个子类再
## ProlapseController.register_trigger()。控制器只看 evaluate() 的结果和 drive_node()。
class_name ProlapseTrigger

## 唯一 id，例如 "ball_rod"。
func id() -> String:
	return ""

## 显示名。
func display_name() -> String:
	return id()

## ctx：触发源自己报告的情况（尺寸、拉速等）；params：ProlapseParams。返回 true 则开始脱垂驱动。
func evaluate(_ctx: Dictionary, _params: Resource) -> bool:
	return false

## 由哪个子宫段链节点承受牵拉（0 = 宫颈，最后 = 宫底）。
func drive_node() -> int:
	return 0

## 驱动中是否允许往回推时手法复位。
func allows_reduce() -> bool:
	return true

## 最近一次 evaluate 的诊断（自检 / 调试面板）。
var last_report: Dictionary = {}
