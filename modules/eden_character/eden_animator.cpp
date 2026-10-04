#include "eden_animator.h"

#include "eden_gait.h"

#include "core/math/math_funcs.h"
#include "scene/3d/physics/collision_object_3d.h"
#include "scene/3d/skeleton_3d.h"
#include "scene/resources/3d/world_3d.h"
#include "servers/physics_3d/physics_server_3d.h"

namespace {

float smooth(float t) {
	return t * t * (3.0f - 2.0f * t);
}

bool crossed(float a, float b, float x) {
	return b >= a ? (a < x && b >= x) : (a < x || b >= x);
}

} // namespace

void EdenAnimator::land(float p_impact) {
	land_amount = CLAMP(p_impact / 7.0f, 0.15f, 1.0f);
	land_t = 0.0f;
}

int EdenAnimator::_bone(Skeleton3D *p_skel, const String &p_name) {
	const int *found = bones.getptr(p_name);
	if (found != nullptr) {
		return *found;
	}
	const int i = p_skel->find_bone(p_name);
	bones[p_name] = i;
	return i;
}

void EdenAnimator::_process_modification(double p_delta) {
	Skeleton3D *skel = get_skeleton();
	if (skel == nullptr) {
		return;
	}
	const float delta = MIN(float(p_delta), 0.1f);
	time += delta;
	// Eased weights: each follows its target at its own rate (speed-ups snappier than slow-downs feel natural)
	const float moving = airborne ? 0.0f : CLAMP(ground_speed / 0.6f, 0.0f, 1.0f);
	move = Math::move_toward(move, moving, delta * (moving > move ? 5.0f : 3.5f));
	const float gait_target = CLAMP((ground_speed - walk_speed) / MAX(run_speed - walk_speed, 0.01f), 0.0f, 1.0f);
	gait = Math::lerp(gait, gait_target, 1.0f - Math::exp(-delta * 6.0f));
	crouch = Math::move_toward(crouch, crouching ? 1.0f : 0.0f, delta * 5.0f);
	air = Math::move_toward(air, (airborne && !swimming) ? 1.0f : 0.0f, delta * (airborne ? 8.0f : 12.0f));
	swim = Math::move_toward(swim, swimming ? 1.0f : 0.0f, delta * 2.5f);
	land_t += delta;
	Vector2 look_target(look_yaw, look_pitch);
	if (Math::abs(look_yaw) > Math::deg_to_rad(110.0f)) { // looking back over the shoulder: face forward rather than twist round
		look_target = Vector2();
	}
	look = look.lerp(look_target, 1.0f - Math::exp(-delta * 5.0f));

	// Stride phase: one cycle per cycle-distance travelled (crouch steps are shorter)
	float cycle = Math::lerp(EdenGait::WALK_CYCLE_DISTANCE, EdenGait::RUN_CYCLE_DISTANCE, gait);
	cycle = Math::lerp(cycle, 1.0f, crouch);
	const float before = phase;
	phase = Math::fposmod(phase + ground_speed * delta / cycle, 1.0f);
	// Strokes: faster when swimming than treading; each arm entering the water is a splash (the step signal)
	const float stroke_before = stroke;
	stroke = Math::fposmod(stroke + delta * Math::lerp(0.5f, 0.75f, CLAMP(ground_speed / 2.0f, 0.0f, 1.0f)), 1.0f);
	if (swimming && ground_speed > 0.4f) {
		if (crossed(stroke_before, stroke, 0.0f)) {
			emit_signal(SNAME("step"), 0, 0.6f);
		}
		if (crossed(stroke_before, stroke, 0.5f)) {
			emit_signal(SNAME("step"), 1, 0.6f);
		}
	}
	if (!airborne && !swimming && move > 0.3f) {
		const float strength = CLAMP(ground_speed / run_speed, 0.25f, 1.0f) * Math::lerp(1.0f, 0.5f, crouch);
		if (crossed(before, phase, 0.25f)) {
			emit_signal(SNAME("step"), 0, strength);
		}
		if (crossed(before, phase, 0.75f)) {
			emit_signal(SNAME("step"), 1, strength);
		}
	}

	// Standing: idle -> locomotion; crouched: the crouch pose (which has its own still -> moving blend). Only the poses
	// with weight are built.
	Dictionary stand;
	if (crouch < 1.0f) {
		if (move <= 0.0f) {
			stand = EdenGait::idle(time);
		} else if (move >= 1.0f) {
			stand = EdenGait::locomotion(phase, gait);
		} else {
			stand = EdenGait::blend(EdenGait::idle(time), EdenGait::locomotion(phase, gait), smooth(move));
		}
	}
	const Dictionary low = crouch > 0.0f ? EdenGait::crouch(phase, move, time) : Dictionary();
	Dictionary p = EdenGait::blend(stand, low, smooth(crouch));
	if (air > 0.0f) {
		p = EdenGait::blend(p, EdenGait::air(vertical_speed, time), smooth(air));
	}
	if (swim > 0.0f) {
		p = EdenGait::blend(p, EdenGait::swim(stroke, CLAMP(ground_speed / 1.5f, 0.0f, 1.0f), time), smooth(swim));
	}
	// Landing: dips fast, recovers over a third of a second
	if (land_t < 0.6f) {
		p = EdenGait::add_landing(p, land_amount * MIN(land_t / 0.06f, 1.0f) * Math::exp(-land_t / 0.14f));
	}
	// The head and neck turn toward the look direction on top of the pose (a head turns ~70 deg, tips ~35)
	const float yaw = Math::rad_to_deg(CLAMP(look.x, -1.2f, 1.2f));
	const float pitch = -Math::rad_to_deg(CLAMP(look.y, -0.6f, 0.5f));
	const Vector3 X(1, 0, 0), Z(0, 0, 1);
	p["neck_01"] = EdenGait::q(Z, yaw * 0.35f) * EdenGait::q(X, pitch * 0.4f) * (p.has("neck_01") ? Quaternion(p["neck_01"]) : Quaternion());
	p["head"] = EdenGait::q(Z, yaw * 0.5f) * EdenGait::q(X, pitch * 0.6f) * (p.has("head") ? Quaternion(p["head"]) : Quaternion());
	p["spine_03"] = EdenGait::q(Z, yaw * 0.15f) * (p.has("spine_03") ? Quaternion(p["spine_03"]) : Quaternion());
	_apply(skel, p);
	_foot_ik(skel, delta);

	if (swim > 0.5f) {
		state = ground_speed > 0.4f ? "swim" : "tread";
	} else if (air > 0.5f) {
		state = vertical_speed > 0.5f ? "jump" : "fall";
	} else if (crouching) {
		state = ground_speed > 0.15f ? "crouch_walk" : "crouch_idle";
	} else if (ground_speed > (walk_speed + run_speed) * 0.5f) {
		state = "run";
	} else if (ground_speed > 0.15f) {
		state = "walk";
	} else {
		state = "idle";
	}
}

void EdenAnimator::_apply(Skeleton3D *p_skel, const Dictionary &p_pose) {
	// The pelvis always starts from rest (plus the pose's offset below): foot IK lowers it again every frame
	const int pelvis = _bone(p_skel, "pelvis");
	if (pelvis >= 0 && !p_pose.has("pelvis_offset")) {
		p_skel->set_bone_pose_position(pelvis, EdenGait::pelvis_rest());
	}
	for (const Variant &kv : p_pose.keys()) {
		const String k = kv;
		if (k == "pelvis_offset") {
			const int i = _bone(p_skel, "pelvis");
			if (i >= 0) {
				p_skel->set_bone_pose_position(i, EdenGait::pelvis_rest() + Vector3(p_pose[kv]));
			}
		} else {
			const int i = _bone(p_skel, k);
			if (i >= 0) {
				p_skel->set_bone_pose_rotation(i, p_pose[kv]);
			}
		}
	}
	// Bones a pose leaves out (clavicles when crouched, say) go back to rest rather than keeping a stale angle
	for (const KeyValue<String, int> &e : bones) {
		if (e.value >= 0 && !p_pose.has(e.key)) {
			p_skel->set_bone_pose_rotation(e.value, Quaternion());
		}
	}
}

// Foot IK, in skeleton space (Z up, origin on the body's floor): the pose has just been applied as if the ground were
// flat under the body; this puts each foot on the ground actually under it.
void EdenAnimator::_foot_ik(Skeleton3D *p_skel, float p_delta) {
	const int pelvis = _bone(p_skel, "pelvis");
	const int thigh[2] = { _bone(p_skel, "thigh_l"), _bone(p_skel, "thigh_r") };
	const int calf[2] = { _bone(p_skel, "calf_l"), _bone(p_skel, "calf_r") };
	const int foot[2] = { _bone(p_skel, "foot_l"), _bone(p_skel, "foot_r") };
	if (pelvis < 0 || thigh[0] < 0 || thigh[1] < 0 || calf[0] < 0 || calf[1] < 0 || foot[0] < 0 || foot[1] < 0) {
		return;
	}
	const Vector3 up(0, 0, 1);
	// Off in the air and in water; fades so a landing doesn't snap
	const float target_weight = foot_ik ? (1.0f - air) * (1.0f - swim) : 0.0f;
	ik_weight = Math::move_toward(ik_weight, target_weight, p_delta * 6.0f);

	// The ground under each foot
	Ref<World3D> world = p_skel->get_world_3d();
	PhysicsDirectSpaceState3D *space = world.is_valid() ? world->get_direct_space_state() : nullptr;
	const Transform3D to_world = p_skel->get_global_transform();
	const Transform3D to_skel = to_world.affine_inverse();
	PhysicsDirectSpaceState3D::RayParameters ray;
	ray.collision_mask = uint32_t(foot_ik_mask);
	for (Node *n = p_skel->get_parent(); n != nullptr; n = n->get_parent()) {
		CollisionObject3D *body = Object::cast_to<CollisionObject3D>(n);
		if (body != nullptr) {
			ray.exclude.insert(body->get_rid()); // our own capsule
			break;
		}
	}
	const float reach = foot_ik_max_step;
	const float ease = 1.0f - Math::exp(-p_delta * 14.0f);
	for (int i = 0; i < 2; ++i) {
		float offset = 0.0f;
		Vector3 normal = up;
		if (space != nullptr && ik_weight > 0.0f) {
			const Vector3 ankle = p_skel->get_bone_global_pose(foot[i]).origin;
			ray.from = to_world.xform(Vector3(ankle.x, ankle.y, reach + 0.3f));
			ray.to = to_world.xform(Vector3(ankle.x, ankle.y, -reach));
			PhysicsDirectSpaceState3D::RayResult hit;
			if (space->intersect_ray(ray, hit)) {
				offset = CLAMP(to_skel.xform(hit.position).z, -reach, reach);
				normal = to_skel.basis.xform(hit.normal).normalized();
				if (normal.dot(up) < 0.5f) { // a wall or a steep face: don't stand the foot up it
					normal = up;
				}
			}
		}
		ik_offset[i] = Math::lerp(ik_offset[i], offset, ease);
		ik_normal[i] = ik_normal[i].lerp(normal, ease).normalized();
	}
	// The pelvis comes down as far as the lower foot needs, so that leg can reach
	const float drop = MAX(0.0f, -MIN(ik_offset[0], ik_offset[1])) * ik_weight;
	ik_drop = Math::lerp(ik_drop, drop, ease);
	if (ik_weight <= 0.0f && ik_drop < 1e-4f) {
		return;
	}
	const Transform3D pelvis_parent = p_skel->get_bone_parent(pelvis) >= 0 ? p_skel->get_bone_global_pose(p_skel->get_bone_parent(pelvis)) : Transform3D();
	p_skel->set_bone_pose_position(pelvis, p_skel->get_bone_pose_position(pelvis) + pelvis_parent.basis.inverse().xform(-up * ik_drop));

	for (int i = 0; i < 2; ++i) {
		const Vector3 ankle = p_skel->get_bone_global_pose(foot[i]).origin; // (already lowered with the pelvis)
		const Vector3 target = ankle + up * ((ik_offset[i] * ik_weight) + ik_drop);
		// Planted feet (near their rest height) lie on the slope; a foot swinging through the air doesn't
		const float lift = ankle.z + ik_drop - p_skel->get_bone_global_rest(foot[i]).origin.z;
		const float planted = (1.0f - CLAMP(lift / 0.12f, 0.0f, 1.0f)) * ik_weight;
		Quaternion tilt(up, ik_normal[i]);
		const float max_tilt = Math::deg_to_rad(35.0f);
		if (tilt.get_angle() > max_tilt) {
			tilt = Quaternion().slerp(tilt, max_tilt / tilt.get_angle());
		}
		_two_bone(p_skel, thigh[i], calf[i], foot[i], target, Quaternion().slerp(tilt, planted));
	}
}

// Bends thigh and calf so the foot's ankle reaches p_target (skeleton space), keeping the knee in the plane it already
// bends in; the foot keeps its world orientation, turned by p_foot_tilt.
void EdenAnimator::_two_bone(Skeleton3D *p_skel, int p_thigh, int p_calf, int p_foot, const Vector3 &p_target, const Quaternion &p_foot_tilt) {
	const Transform3D gt = p_skel->get_bone_global_pose(p_thigh);
	const Transform3D gc = p_skel->get_bone_global_pose(p_calf);
	const Transform3D gf = p_skel->get_bone_global_pose(p_foot);
	const Vector3 a = gt.origin, b = gc.origin, c = gf.origin;
	const float l1 = a.distance_to(b), l2 = b.distance_to(c);
	if (l1 < 1e-4f || l2 < 1e-4f) {
		return;
	}
	Vector3 to_target = p_target - a;
	const float d = CLAMP(to_target.length(), Math::abs(l1 - l2) + 1e-3f, l1 + l2 - 1e-3f);
	const Vector3 dir = to_target.length() > 1e-5f ? to_target.normalized() : (c - a).normalized();
	const Vector3 t = a + dir * d;
	Vector3 pole = (b - a) - dir * (b - a).dot(dir); // which way the knee points
	if (pole.length_squared() < 1e-8f) {
		pole = Vector3(0, -1, 0) + dir * dir.y; // straight leg: knees go forward (-Y), off the leg's line
	}
	pole.normalize();
	const float cos_a = CLAMP((l1 * l1 + d * d - l2 * l2) / (2.0f * l1 * d), -1.0f, 1.0f);
	const Vector3 knee = a + dir * (l1 * cos_a) + pole * (l1 * Math::sqrt(MAX(0.0f, 1.0f - cos_a * cos_a)));

	const Quaternion q_thigh((b - a).normalized(), (knee - a).normalized());
	const Quaternion thigh_rot = q_thigh * gt.basis.get_rotation_quaternion();
	const Quaternion q_calf(q_thigh.xform(c - b).normalized(), (t - knee).normalized());
	const Quaternion calf_rot = q_calf * q_thigh * gc.basis.get_rotation_quaternion();
	const Quaternion foot_rot = p_foot_tilt * gf.basis.get_rotation_quaternion();

	const int parent = p_skel->get_bone_parent(p_thigh);
	const Quaternion parent_rot = parent >= 0 ? p_skel->get_bone_global_pose(parent).basis.get_rotation_quaternion() : Quaternion();
	p_skel->set_bone_pose_rotation(p_thigh, (parent_rot.inverse() * thigh_rot).normalized());
	p_skel->set_bone_pose_rotation(p_calf, (thigh_rot.inverse() * calf_rot).normalized());
	p_skel->set_bone_pose_rotation(p_foot, (calf_rot.inverse() * foot_rot).normalized());
}

void EdenAnimator::_bind_methods() {
	ClassDB::bind_method(D_METHOD("land", "impact"), &EdenAnimator::land);
	ClassDB::bind_method(D_METHOD("get_state"), &EdenAnimator::get_state);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "state", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "get_state");
#define EDEN_ANIM_BIND(m_vtype, m_name)                                                          \
	ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &EdenAnimator::set_##m_name);       \
	ClassDB::bind_method(D_METHOD("get_" #m_name), &EdenAnimator::get_##m_name);                \
	ADD_PROPERTY(PropertyInfo(Variant::m_vtype, #m_name), "set_" #m_name, "get_" #m_name);
	EDEN_ANIM_BIND(FLOAT, ground_speed)
	EDEN_ANIM_BIND(BOOL, airborne)
	EDEN_ANIM_BIND(BOOL, crouching)
	EDEN_ANIM_BIND(BOOL, swimming)
	EDEN_ANIM_BIND(FLOAT, vertical_speed)
	EDEN_ANIM_BIND(FLOAT, look_yaw)
	EDEN_ANIM_BIND(FLOAT, look_pitch)
	EDEN_ANIM_BIND(FLOAT, walk_speed)
	EDEN_ANIM_BIND(FLOAT, run_speed)
	EDEN_ANIM_BIND(BOOL, foot_ik)
	EDEN_ANIM_BIND(FLOAT, foot_ik_max_step)
	EDEN_ANIM_BIND(INT, foot_ik_mask)
#undef EDEN_ANIM_BIND
	ADD_SIGNAL(MethodInfo("step", PropertyInfo(Variant::INT, "foot"), PropertyInfo(Variant::FLOAT, "strength")));
}
