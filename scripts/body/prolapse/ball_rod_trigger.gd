extends "res://scripts/body/prolapse/prolapse_trigger.gd"
## 触发 #1：长柄金属球进入宫腔后放大，强行往外扯时被宫颈卡住，把子宫一起拖下来。
## ctx = {in_uterus, ball_radius, pull_speed, pull_force}
class_name BallRodProlapseTrigger


func id() -> String:
	return "ball_rod"


func display_name() -> String:
	return "长杆钢球扯出"


func evaluate(ctx: Dictionary, params: Resource) -> bool:
	var r := float(ctx.get("ball_radius", 0.0))
	var cap := float(params.get("cervix_capacity_r")) if params else 0.0105
	var ratio := float(params.get("catch_ratio")) if params else 1.08
	var v_thr := float(params.get("trigger_pull_speed")) if params else 0.16
	var f_thr := float(params.get("trigger_pull_force")) if params else 0.03
	var big := r >= cap * ratio
	var speed := float(ctx.get("pull_speed", 0.0))
	var force := float(ctx.get("pull_force", 0.0))
	var hard := speed >= v_thr or force >= f_thr
	var inside := bool(ctx.get("in_uterus", false))
	last_report = {"big": big, "hard": hard, "inside": inside, "ball_radius": r, "catch_radius": cap * ratio, "pull_speed": speed, "pull_force": force}
	return inside and big and hard


func drive_node() -> int:
	return 0
