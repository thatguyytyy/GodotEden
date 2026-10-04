#ifndef EDEN_ANIMATOR_H
#define EDEN_ANIMATOR_H

#include "scene/3d/skeleton_modifier_3d.h"

// Procedural animation for the EDEN_Male rig (a child of its Skeleton3D). Every frame it blends EdenGait poses from
// what the body is doing, instead of cross-fading fixed clips: idle <-> walk <-> run by the (eased) ground speed, the
// stride phase advanced by distance travelled so feet don't slide; crouch, air and swim poses faded in and out; a
// knee-and-hip dip on landing scaled by the impact; the head turning toward where the camera looks.
// Foot IK on top: each foot finds the ground under it, the pelvis drops for the lower one, the knees bend so both
// feet land on the real ground (slopes, steps, rocks) and planted feet tilt to the slope -- the body stays upright.
// The owner (a character controller) feeds the inputs from its physics step. `step` fires as each foot strikes.
class EdenAnimator : public SkeletonModifier3D {
	GDCLASS(EdenAnimator, SkeletonModifier3D);

public:
	// Inputs (set by the owner)
	float ground_speed = 0.0f;
	bool airborne = false;
	bool crouching = false;
	bool swimming = false;
	float vertical_speed = 0.0f;
	float look_yaw = 0.0f; // where to look, relative to the body: radians, + left
	float look_pitch = 0.0f; // + up
	float walk_speed = 1.6f; // speeds that mean "walking" and "running" (gait 0 and 1)
	float run_speed = 5.5f;
	bool foot_ik = true;
	float foot_ik_max_step = 0.45f; // how far (m) a foot reaches up or down to the ground
	int foot_ik_mask = 1; // what counts as ground
	// The body just touched down after falling at `impact` m/s
	void land(float p_impact);
	// What it is showing: idle, walk, run, crouch_idle, crouch_walk, jump, fall, swim, tread
	String get_state() const { return state; }

#define EDEN_ANIM_PROP(m_type, m_name)                    \
	void set_##m_name(m_type p_value) { m_name = p_value; } \
	m_type get_##m_name() const { return m_name; }
	EDEN_ANIM_PROP(float, ground_speed)
	EDEN_ANIM_PROP(bool, airborne)
	EDEN_ANIM_PROP(bool, crouching)
	EDEN_ANIM_PROP(bool, swimming)
	EDEN_ANIM_PROP(float, vertical_speed)
	EDEN_ANIM_PROP(float, look_yaw)
	EDEN_ANIM_PROP(float, look_pitch)
	EDEN_ANIM_PROP(float, walk_speed)
	EDEN_ANIM_PROP(float, run_speed)
	EDEN_ANIM_PROP(bool, foot_ik)
	EDEN_ANIM_PROP(float, foot_ik_max_step)
	EDEN_ANIM_PROP(int, foot_ik_mask)
#undef EDEN_ANIM_PROP

	virtual bool has_process() const override { return true; }

protected:
	virtual void _process_modification(double p_delta) override;
	static void _bind_methods();

private:
	String state = "idle";
	HashMap<String, int> bones; // bone name -> index (-1: not in this rig)
	float time = 0.0f;
	float phase = 0.0f;
	float move = 0.0f;
	float gait = 0.0f;
	float crouch = 0.0f;
	float air = 0.0f;
	float swim = 0.0f;
	float stroke = 0.0f;
	float land_t = 10.0f;
	float land_amount = 0.0f;
	Vector2 look;
	float ik_offset[2] = { 0.0f, 0.0f }; // per foot: ground height under it vs the body's floor (skeleton units, eased)
	Vector3 ik_normal[2] = { Vector3(0, 0, 1), Vector3(0, 0, 1) }; // ground normal under it (skeleton space, eased)
	float ik_drop = 0.0f; // pelvis lowered by (eased)
	float ik_weight = 0.0f; // most recent IK weight applied

	int _bone(Skeleton3D *p_skel, const String &p_name);
	void _apply(Skeleton3D *p_skel, const Dictionary &p_pose);
	void _foot_ik(Skeleton3D *p_skel, float p_delta);
	void _two_bone(Skeleton3D *p_skel, int p_thigh, int p_calf, int p_foot, const Vector3 &p_target, const Quaternion &p_foot_tilt);
};

#endif // EDEN_ANIMATOR_H
