extends Node
class_name Brain

@export_category("Node References")
@export var lungs: Lungs
@export var voice: VoiceBox
@export var animation_tree: AnimationTree

@export_category("SneezeCounter")
##How many sneeze triggers is needed to reach max sneeze level?
@export var sneeze_trigger_target : float = 20.0
##How many seconds to decay sneeze trigger to zero?
@export var sneeze_trigger_decay_seconds : float = 20.0
##How many sneeze triggers to remove on sneeze
@export var sneeze_trigger_expel : float = 5
##How often to check for animation transitions
@export var update_timer_base_time := 0.25
##Variance in the update timer, from 0 seconds to value seconds
@export var update_timer_max_variance := 1.0

@export var sniff_sneeze_trigger_mod : Vector2 = Vector2(0.0,0.1)
@export var sigh_sneeze_trigger_mod : Vector2 = Vector2(0.0,-0.1)

@export_category("Fits")
##How likely to have a fit? Max 1.0
@export var fit_probability : float = 0.3
##How many seconds should a fit last? From X to Y seconds
@export var fit_window_seconds : Vector2 = Vector2(5.0, 20.0)
##How much to boost sneeze level while in a fit?
@export var fit_sneeze_bonus : float = 1.5
##How much to modify sneeze trigger removal while in a fit?
@export var fit_trigger_count_mult : float = 1

@export_category("Control")
@export var sneeze_size_curve : Curve
@export var control_count_max : float = 100.0
@export var control_recovery_threshold : float = 0.3
@export var control_decay_seconds : float = 30.0
@export var control_sneeze_expel_percent : float = 0.2
@export var control_sneeze_size_curve : Curve
@export var buildup_sneeze_size_mod : Vector2 = Vector2(0.0,0.1)
@export var sigh_sneeze_size_mod : Vector2 = Vector2(0.0,-0.1)

@export_category("Animation Curves")
##Define the chances of hitch animation playing depending on sneeze level
@export var hitch_curve : Curve
##Define the chances of buildup animation playing depending on sneeze level
@export var buildup_curve : Curve
##Define the chances of sneeze animation playing depending on sneeze level
@export var sneeze_curve : Curve
##Define the transition blend to the "tickle" expression
@export var tickle_curve : Curve

@export_category("Animation Modifiers")
##Modifier to chance to play a hitch while waiting in the hitch interrupt state
@export var hitch_repeat_modifier : CustomBoundedValue
##Modifier to chance to play a buildup while waiting in the buildup interrupt state
@export var buildup_repeat_modifier : CustomBoundedValue
##Modifier to chance to play a sneeze while waiting in the sneeze interrupt state
@export var sneeze_repeat_modifier : CustomBoundedValue

#Local node references
@onready var update_timer: Timer = %UpdateTimer
@onready var fit_timer: Timer = %FitTimer
@onready var anim_timeout_timer: Timer = %AnimTimeoutTimer

var sniff_trigger_count := CustomBoundedValue.new()
var sneeze_trigger_count := CustomBoundedValue.new()
var control_count := CustomBoundedValue.new()

@onready var sneeze_decay_rate : float = -sneeze_trigger_target / sneeze_trigger_decay_seconds
@onready var control_decay_rate : float = control_count_max / control_decay_seconds

var idletickleblend := 0.0
var sneeze_size := CustomBoundedValue.new()

var anim_parameters = {
	"hitch": false,
	"hitch_interrupt": false,
	"buildup": false,
	"buildup_interrupt": false,
	"sneeze": false,
	"sneeze_interrupt": false,
	"sigh": false,
	"sigh_interrupt": false,
	"sniff": false,
	"sniff_interrupt": false,
}

var is_hitching : bool = false
var is_building : bool = false
var is_sneezing : bool = false
var total_sneezes: int = 0
var is_sighing : bool = false
var is_sniffing : bool = false

signal on_hitch()
signal on_build()
signal on_sneeze()
signal on_sigh()
signal on_sniff()

var _sneeze_queued = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	sneeze_size.name = "Sneeze Size"
	sneeze_size.max_value = 1.0
	rand_sneeze_size()
	
	sneeze_trigger_count.name = "Sneeze Trigger Count"
	sneeze_trigger_count.max_value = sneeze_trigger_target
	
	control_count.name = "Control Value"
	control_count.max_value = control_count_max
	control_count.current_value = control_count.max_value
	
	animation_tree.set("parameters/Blink Shot/request",AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	animation_tree.set("parameters/Earflick Shot/request",AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	
	animation_tree.connect("animation_finished",_on_animation_finished)
	lungs.breathe_out.connect(
		func():
			var flare_tween : Tween = create_tween()
			flare_tween.set_trans(Tween.TRANS_QUAD)
			flare_tween.tween_property(animation_tree, "parameters/NoseFlareStrength/blend_amount",0.0,0.5)
	)
	lungs.breathe_in.connect(
		func():
			var flare_tween : Tween = create_tween()
			flare_tween.set_trans(Tween.TRANS_QUAD)
			flare_tween.tween_property(animation_tree, "parameters/NoseFlareStrength/blend_amount",randf_range(.25,.5),0.5)
	)
	lungs.breathe_done.connect(
		func():
			var flare_tween : Tween = create_tween()
			flare_tween.set_trans(Tween.TRANS_QUAD)
			flare_tween.tween_property(animation_tree, "parameters/NoseFlareStrength/blend_amount",0.0,0.5)
	)
	
	lungs.want_breathe.connect(do_want_breathe)
	lungs.must_breathe.connect(do_must_breathe)
	
	#Attach all nose hitbox zones to the brain control
	for nose in get_tree().get_nodes_in_group("nose"):
		if nose is NoseTriggerZone:
			print("<BRAIN> Added Nose Trigger Zone ",nose)
			nose.sneeze_trigger.connect(sneeze_trigger)
			nose.sniff_trigger.connect(sniff_trigger)
			voice.on_sneeze.connect(nose.on_sneeze.bind(sneeze_size.get_percent()))
			voice.on_sniff.connect(nose.on_sniff)
	
	update_timer.timeout.connect(_on_update_timeout)
	
	voice.on_hitch.connect(do_hitch)
	voice.on_buildup.connect(do_buildup)
	voice.on_sneeze.connect(do_sneeze)
	
	voice.on_sneeze_finished.connect(func():
		anim_timeout_timer.start()
		rand_sneeze_size()
		#print("%s finished : %s"%["sneeze voice",Time.get_ticks_msec()])
		await anim_timeout_timer.timeout
		#print("%s finished : %s"%["sneeze timer",Time.get_ticks_msec()])
		sneeze_finished()
	)
	voice.on_buildup_finished.connect(func():
		anim_timeout_timer.start()
		#print("%s finished : %s"%["buildup voice",Time.get_ticks_msec()])
		await anim_timeout_timer.timeout
		#print("%s finished : %s"%["buildup timer",Time.get_ticks_msec()])
		buildup_finished()
	)
	voice.on_hitch_finished.connect(func():
		anim_timeout_timer.start()
		#print("%s finished : %s"%["hitch voice",Time.get_ticks_msec()])
		await anim_timeout_timer.timeout
		#print("%s finished : %s"%["hitch timer",Time.get_ticks_msec()])
		hitch_finished()
	)
	voice.on_sigh_finished.connect(func():
		anim_timeout_timer.start()
		#print("%s finished : %s"%["sigh voice",Time.get_ticks_msec()])
		await anim_timeout_timer.timeout
		#print("%s finished : %s"%["sigh timer",Time.get_ticks_msec()])
		sigh_finished()
	)
	voice.on_sniff_finished.connect(func():
		anim_timeout_timer.start()
		#print("%s finished : %s"%["sniff voice",Time.get_ticks_msec()])
		await anim_timeout_timer.timeout
		#print("%s finished : %s"%["sniff timer",Time.get_ticks_msec()])
		sniff_finished()
	)
	
	animation_tree.active = true
	
	animation_tree.animation_started.connect(func(anim_name : StringName):
		print_rich("[color=yellow]Animation Started: %s"%anim_name)
		match(anim_name):
			"sneeze","sneeze_small","sneeze_big":
				on_sneeze_anim()
			"sigh":
				on_sigh_anim()
			"buildup":
				on_buildup_anim()
			"hitch":
				on_hitch_anim()
			"sniff":
				on_sniff_anim()
	)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	idletickleblend = lerpf(idletickleblend, get_tickle_percent(), delta)
	
	sneeze_trigger_count.add_value(delta * sneeze_decay_rate)
	
	if sneeze_trigger_count.get_percent() < control_recovery_threshold:
		control_count.add_value(delta * control_decay_rate)
	
	animation_tree.set("parameters/Parameter Animation/IdleTickle/blend_position", idletickleblend)
	
	set_sneeze_size_blend(delta)
	
	_sneeze_queued = false
	#print("Sniff Trigger %s"%sniff_trigger_count.get_percent())
	#print("Hitch amount: ",hitch_curve.sample_baked(sneeze_trigger_count.get_percent()))

func get_tickle_percent() -> float:
	return clampf(tickle_curve.sample_baked(sneeze_trigger_count.get_percent() * (1.0 if fit_timer.is_stopped() else fit_sneeze_bonus)), 0.0, 1.0)

func _on_update_timeout():
	#reset_state_parameters()
	
	update_timer.wait_time = update_timer_base_time + randf_range(0.0,update_timer_max_variance)
	#print("<Brain> Sneeze trigger: ",sneeze_trigger_count)
	#print("<Brain> IdleTickleBlend: ",idletickleblend)
	var sneeze_percent = sneeze_trigger_count.get_percent()
	
	if randf() < hitch_curve.sample(sneeze_percent) * (hitch_repeat_modifier.current_value if is_hitching else 1.0):
		if not lungs.is_full():
			anim_parameters["hitch"] = true
		else:
			anim_parameters["sigh"] = true
	
	if randf() < buildup_curve.sample(sneeze_percent) * (1.0 if fit_timer.is_stopped() else fit_sneeze_bonus) * (buildup_repeat_modifier.current_value if is_building else 1.0):
		if not lungs.is_full():
			anim_parameters["buildup"] = true
		else:
			anim_parameters["sigh"] = true
			
	if randf() < sneeze_curve.sample(sneeze_percent) * (1.0 if fit_timer.is_stopped() else fit_sneeze_bonus) * (sneeze_repeat_modifier.current_value if is_sneezing else 1.0):
		anim_parameters["sneeze"] = true
		print("AnimParams Sneeze True")
		#if not is_sneezing or anim_parameters["sneeze_interrupt"]:
			#print("Sneeze Size now ",sneeze_size)
		
	if randf() < 0.1 : 
		anim_parameters["sigh"] = true
	
	if randf() < sniff_trigger_count.get_percent(): 
		anim_parameters["sniff"] = true

func reset_tracker_params():
	print_rich("[color=green]Reset tracker parameters!")
	is_hitching = false
	is_building = false
	is_sneezing = false
	is_sighing = false
	is_sniffing = false
	anim_parameters["hitch_interrupt"] = false
	anim_parameters["buildup_interrupt"] = false
	anim_parameters["sneeze_interrupt"] = false
	anim_parameters["sigh_interrupt"] = false
	anim_parameters["sniff_interrupt"] = false

func reset_state_parameters():
	print_rich("[color=darkgreen]Reset state parameters")
	anim_parameters["hitch"] = false
	anim_parameters["buildup"] = false
	anim_parameters["sneeze"] = false
	anim_parameters["sigh"] = false
	anim_parameters["sniff"] = false

func _on_animation_finished(animation_name : StringName):
	print("On anim finished... ",animation_name)
	match animation_name:
		"hitch", "sneeze", "sneeze_small", "sneeze_big", "buildup":
			reset_tracker_params()
			reset_state_parameters()

func on_hitch_anim():
	on_hitch.emit()
	print("Hitch Anim")
	voice.Play_Hitch()
	reset_tracker_params()
	reset_state_parameters()
	is_hitching = true

func on_buildup_anim():
	on_build.emit()
	print("Buildup Anim")
	voice.Play_Buildup()
	reset_tracker_params()
	reset_state_parameters()
	is_building = true
	sneeze_size.add_value(randf_range(buildup_sneeze_size_mod.x,buildup_sneeze_size_mod.y) * sneeze_size.max_value)

func on_sneeze_anim():
	if _sneeze_queued:
		return
	on_sneeze.emit()
	print_rich("Sneeze Anim")
	voice.Play_Sneeze(0.333)
	_sneeze_queued = true
	reset_tracker_params()
	reset_state_parameters()
	is_sneezing = true
	total_sneezes += 1

func on_sigh_anim():
	on_sigh.emit()
	print("Sigh Anim")
	voice.Play_Sigh()
	reset_tracker_params()
	reset_state_parameters()
	is_sighing = true
	lungs.set_breath_state(lungs.BREATH_STATE.OUT)
	sneeze_size.add_value(randf_range(sigh_sneeze_size_mod.x,sigh_sneeze_size_mod.y) * sneeze_size.max_value)
	sneeze_trigger_count.add_value(randf_range(sigh_sneeze_trigger_mod.x,sigh_sneeze_trigger_mod.y) * sneeze_trigger_count.max_value)

func on_sniff_anim():
	on_sniff.emit()
	print("Sniff Anim")
	voice.Play_Sniff()
	reset_tracker_params()
	reset_state_parameters()
	is_sniffing = true
	do_must_breathe()
	sniff_trigger_count.set_value(0.0)
	sneeze_trigger_count.add_value(randf_range(sniff_sneeze_trigger_mod.x,sniff_sneeze_trigger_mod.y) * sneeze_trigger_count.max_value)
	
func do_hitch():
	lungs.set_breath_state(lungs.BREATH_STATE.HITCH)
	
func do_buildup():
	lungs.set_breath_state(lungs.BREATH_STATE.BUILDUP)
	
func do_sneeze():
	lungs.set_breath_state(lungs.BREATH_STATE.SNEEZE)
	
	if randf() < fit_probability:
		print("Fit started")
		fit_timer.start(randf_range(fit_window_seconds.x, fit_window_seconds.y))
	
	if fit_timer.is_stopped():
		sneeze_trigger_count.add_value(-sneeze_trigger_expel * sneeze_size.get_percent())
		control_count.add_value(-control_sneeze_expel_percent * control_count_max * sneeze_size.get_percent())
	else:
		sneeze_trigger_count.add_value(-sneeze_trigger_expel * fit_trigger_count_mult * sneeze_size.get_percent())
		control_count.add_value(-control_sneeze_expel_percent * control_count_max * sneeze_size.get_percent())

func sneeze_finished():
	print_rich("[color=lightskyblue]Sneeze Interrupt: True!")
	anim_parameters["sneeze_interrupt"] = true

func hitch_finished():
	print("Hitch Interrupt")
	anim_parameters["hitch_interrupt"] = true

func buildup_finished():
	print("Buildup Interrupt")
	anim_parameters["buildup_interrupt"] = true

func sigh_finished():
	print("Sigh Interrupt")
	anim_parameters["sigh_interrupt"] = true

func sniff_finished():
	print("Sniff Interrupt")
	anim_parameters["sniff_interrupt"] = true
	
func sneeze_trigger(value):
	sneeze_trigger_count.add_value(value)

func sniff_trigger(value):
	sniff_trigger_count.add_value(value)

func do_want_breathe(weight : float):
	if randf() < weight:
		print("Want Breathe Started")
		lungs.set_breath_state(lungs.BREATH_STATE.IN)
		
func do_must_breathe():
	print("Must Breathe Started")
	lungs.set_breath_state(lungs.BREATH_STATE.IN)

func rand_sneeze_size():
	#print("Randomizing sneeze size...")
	sneeze_size.set_value(sneeze_size_curve.sample_baked(randf()) * control_sneeze_size_curve.sample_baked(control_count.get_percent()))
	#print("New sneeze size: %s"%sneeze_size.get_percent())

##Set the animation blend positions to the correct value.
func set_sneeze_size_blend(delta : float):
	var target : float = lerpf(-1,1,sneeze_size.get_percent())
	var from : float = animation_tree.get("parameters/Parameter Animation/SneezeBlend/blend_position")
	var blend : float = lerpf(from,target,delta)
	animation_tree.set("parameters/Parameter Animation/SneezeBlend/blend_position",blend)
	animation_tree.set("parameters/Parameter Animation/SneezeBlend2/blend_position",blend)

func send_sliders(container : DebugUIContainer):
	container.add_new_header(name + " Settings", "Settings for various brain functions")
	container.add_new_slider(sneeze_trigger_count, "Determines chance of hitch/buildup/sneeze")
	container.add_new_slider(sneeze_size,"Current size of sneeze")
	container.add_new_slider(hitch_repeat_modifier, "Modifies chance of hitching again after hitch")
	container.add_new_slider(buildup_repeat_modifier, "Modifies chance of buildup again after buildup")
	container.add_new_slider(sneeze_repeat_modifier, "Modifies chance of sneeze again after sneeze")
	container.add_new_slider(control_count,"Current control over sneezes")

func send_curves(container : DebugUIContainer):
	container.add_new_header(name + " Curves", "Curve thresholds for various brain functions")
	container.add_new_curve("Hitch Curve",hitch_curve)
	container.add_new_curve("Buildup Curve",buildup_curve)
	container.add_new_curve("Sneeze Curve",sneeze_curve)
	container.add_new_curve("Tickle Curve",tickle_curve)
