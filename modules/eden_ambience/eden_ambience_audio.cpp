#include "eden_ambience_audio.h"

#include <cmath>

static constexpr float TAU_F = 6.28318530718f;

// One-pole low-pass coefficient for a cutoff in Hz
static inline float _lp_coef(float p_hz, float p_rate) {
	return 1.0f - std::exp(-TAU_F * p_hz / p_rate);
}

static inline float _smoothstep(float a, float b, float x) {
	const float t = CLAMP((x - a) / (b - a), 0.0f, 1.0f);
	return t * t * (3.0f - 2.0f * t);
}

// Chamberlin state-variable filter; returns the band-pass output
static inline float _svf_band(float p_in, float p_f, float p_q, float &r_low, float &r_band) {
	r_low += p_f * r_band;
	const float high = p_in - r_low - p_q * r_band;
	r_band += p_f * high;
	return r_band;
}

AudioStreamEdenAmbience::AudioStreamEdenAmbience() {
	for (int i = 0; i < LAYER_MAX; i++) {
		levels[i].store(0.0f);
	}
}

void AudioStreamEdenAmbience::set_level(Layer p_layer, float p_level) {
	ERR_FAIL_INDEX(p_layer, LAYER_MAX);
	levels[p_layer].store(CLAMP(p_level, 0.0f, 2.0f), std::memory_order_relaxed);
}

float AudioStreamEdenAmbience::get_level(Layer p_layer) const {
	ERR_FAIL_INDEX_V(p_layer, LAYER_MAX, 0.0f);
	return levels[p_layer].load(std::memory_order_relaxed);
}

Ref<AudioStreamPlayback> AudioStreamEdenAmbience::instantiate_playback() {
	Ref<AudioStreamPlaybackEdenAmbience> pb;
	pb.instantiate();
	pb->stream = Ref<AudioStreamEdenAmbience>(this);
	// Own noise per playback: several emitters playing the same layer must not be sample-identical
	pb->rng = 0x9E3779B9u ^ (Math::rand() | 1u);
	return pb;
}

PackedVector2Array AudioStreamEdenAmbience::render(float p_seconds, int p_seed, const PackedVector2Array &p_thunder) {
	Ref<AudioStreamPlaybackEdenAmbience> pb = instantiate_playback();
	pb->rng = 0x9E3779B9u ^ (uint32_t)p_seed * 2654435761u;
	pb->start();
	pb->snap_levels = true;
	PackedVector2Array out;
	const int n = (int)(p_seconds * AudioStreamPlaybackEdenAmbience::RATE);
	out.resize(n);
	Vector2 *w = out.ptrw();
	int next_event = 0;
	for (int i = 0; i < n; i++) {
		// Thunder events: (time in seconds, distance 0..1)
		while (next_event < p_thunder.size() && p_thunder[next_event].x * AudioStreamPlaybackEdenAmbience::RATE <= i) {
			trigger_thunder(0.0f, p_thunder[next_event].y);
			next_event++;
		}
		float l, r;
		pb->_frame(l, r);
		w[i] = Vector2(l, r);
	}
	return out;
}

void AudioStreamEdenAmbience::trigger_thunder(float p_delay, float p_distance) {
	thunder_delay.store(MAX(p_delay, 0.0f), std::memory_order_relaxed);
	thunder_distance.store(p_distance, std::memory_order_relaxed);
	thunder_serial.fetch_add(1, std::memory_order_release);
}

void AudioStreamEdenAmbience::trigger_footstep(int p_surface, float p_strength, float p_pan) {
	step_surface.store(p_surface, std::memory_order_relaxed);
	step_strength.store(CLAMP(p_strength, 0.0f, 2.0f), std::memory_order_relaxed);
	step_pan.store(CLAMP(p_pan, -1.0f, 1.0f), std::memory_order_relaxed);
	step_serial.fetch_add(1, std::memory_order_release);
}

void AudioStreamEdenAmbience::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_level", "layer", "level"), &AudioStreamEdenAmbience::set_level);
	ClassDB::bind_method(D_METHOD("get_level", "layer"), &AudioStreamEdenAmbience::get_level);
	ClassDB::bind_method(D_METHOD("render", "seconds", "seed", "thunder"), &AudioStreamEdenAmbience::render, DEFVAL(1), DEFVAL(PackedVector2Array()));
	ClassDB::bind_method(D_METHOD("trigger_thunder", "delay", "distance"), &AudioStreamEdenAmbience::trigger_thunder);
	ClassDB::bind_method(D_METHOD("trigger_footstep", "surface", "strength", "pan"), &AudioStreamEdenAmbience::trigger_footstep, DEFVAL(1.0f), DEFVAL(0.0f));
	BIND_ENUM_CONSTANT(SURFACE_GRASS);
	BIND_ENUM_CONSTANT(SURFACE_ROCK);
	BIND_ENUM_CONSTANT(SURFACE_SNOW);
	BIND_ENUM_CONSTANT(SURFACE_SAND);
	BIND_ENUM_CONSTANT(SURFACE_DIRT);
	BIND_ENUM_CONSTANT(SURFACE_MOSS);
	BIND_ENUM_CONSTANT(SURFACE_WET);
	BIND_ENUM_CONSTANT(SURFACE_WOOD);

	BIND_ENUM_CONSTANT(LAYER_WIND);
	BIND_ENUM_CONSTANT(LAYER_LEAVES);
	BIND_ENUM_CONSTANT(LAYER_SURF);
	BIND_ENUM_CONSTANT(LAYER_BIRDS);
	BIND_ENUM_CONSTANT(LAYER_CRICKETS);
	BIND_ENUM_CONSTANT(LAYER_RAIN);
	BIND_ENUM_CONSTANT(LAYER_MAX);
}

// ---------------------------------------------------------------------------------------------

void AudioStreamPlaybackEdenAmbience::start(double p_from_pos) {
	begin_resample();
	_reset_crickets();
	for (int i = 0; i < 2; i++) {
		waves[i].period = _range(7.0f, 12.0f);
		waves[i].t = waves[i].period * (0.1f + 0.5f * i);
		waves[i].gain = _range(0.6f, 1.0f);
		waves[i].pan = i == 0 ? -0.35f : 0.35f;
	}
	active = true;
}

void AudioStreamPlaybackEdenAmbience::_reset_crickets() {
	for (Cricket &c : crickets) {
		c.freq = _range(3800.0f, 5200.0f);
		c.rate = _range(1.2f, 3.2f);
		c.offset = _rand();
		c.gain = _range(0.04f, 0.6f);
		c.pan = _range(-0.9f, 0.9f);
	}
}

void AudioStreamPlaybackEdenAmbience::_spawn_bird() {
	for (Voice &v : voices) {
		if (v.kind >= 0) {
			continue;
		}
		v.kind = (int)(_rand() * 3.0f);
		v.t = 0;
		v.phase = 0;
		v.lps = 0;
		v.pan = _range(-0.9f, 0.9f);
		// Distance: far birds are quieter and duller
		const float dist = _rand();
		v.gain = Math::lerp(0.55f, 0.1f, dist);
		v.lp = _lp_coef(Math::lerp(9000.0f, 2500.0f, dist), RATE);
		switch (v.kind) {
			case 0: // whistled notes
				v.notes = (float)(int)_range(2.0f, 6.0f);
				v.dur = v.notes * _range(0.12f, 0.28f);
				v.f0 = _range(1900.0f, 3800.0f);
				v.f1 = v.f0 * _range(0.7f, 1.5f);
				break;
			case 1: // trill
				v.dur = _range(0.5f, 1.4f);
				v.f0 = _range(3800.0f, 6500.0f);
				v.f1 = v.f0 * 0.85f;
				v.rate = _range(16.0f, 32.0f);
				break;
			default: // chirp series
				v.notes = (float)(int)_range(3.0f, 9.0f);
				v.rate = _range(6.0f, 12.0f);
				v.dur = v.notes / v.rate;
				v.f0 = _range(5000.0f, 7200.0f);
				v.f1 = _range(2600.0f, 3600.0f);
				break;
		}
		return;
	}
}

void AudioStreamPlaybackEdenAmbience::_frame(float &r_l, float &r_r) {
	constexpr float dt = 1.0f / RATE;
	const AudioStreamEdenAmbience *s = stream.ptr();
	const float ease = snap_levels ? 1.0f : dt / 1.5f;
	for (int i = 0; i < AudioStreamEdenAmbience::LAYER_MAX; i++) {
		level[i] += (s->levels[i].load(std::memory_order_relaxed) - level[i]) * ease;
	}
	float l = 0, r = 0;

	// Gusts: a slowly eased random target, shared by wind and leaves
	gust_timer -= dt;
	if (gust_timer <= 0) {
		const float g = s->gustiness.load(std::memory_order_relaxed);
		gust_target = CLAMP(0.15f + _rand() * (0.35f + g), 0.0f, 1.0f);
		gust_timer = _range(1.5f, 5.0f);
	}
	gust += (gust_target - gust) * (dt / 1.2f);

	// Wind: low rumble plus a band-passed hiss whose pitch rises with the gust
	if (level[AudioStreamEdenAmbience::LAYER_WIND] > 1e-4f) {
		const float a = _lp_coef(70.0f + 180.0f * gust, RATE);
		const float f = 2.0f * std::sin(Math::PI * (240.0f + 560.0f * gust) / RATE);
		const float a_hiss = _lp_coef(1100.0f, RATE);
		const float amp = level[AudioStreamEdenAmbience::LAYER_WIND] * (0.3f + 0.7f * gust);
		float out[2];
		for (int c = 0; c < 2; c++) {
			const float n = _noise();
			wl[c] += (n - wl[c]) * a;
			wl2[c] += (wl[c] - wl2[c]) * a;
			const float rumble = wl2[c] * 2.2f / std::sqrt(a);
			whiss[c] += (_svf_band(n, f, 0.3f, wbp_low[c], wbp_band[c]) - whiss[c]) * a_hiss;
			out[c] = amp * (rumble * 0.35f + whiss[c] * (0.15f + 0.3f * gust));
		}
		l += out[0];
		r += out[1];
	}

	// Leaves: a soft rustle that swells with the gusts and drifts slowly in between -- a fast random
	// flutter here read as a choppy, rushed hiss
	if (level[AudioStreamEdenAmbience::LAYER_LEAVES] > 1e-4f) {
		if (_rand() < 1.5f * dt) {
			leaf_flutter_target = _rand();
		}
		leaf_flutter += (leaf_flutter_target - leaf_flutter) * (dt * 2.0f);
		const float amp = level[AudioStreamEdenAmbience::LAYER_LEAVES] * (0.05f + 0.7f * gust * gust) * (0.6f + 0.4f * leaf_flutter);
		const float a_hp = _lp_coef(700.0f, RATE);
		const float a_lp = _lp_coef(3200.0f, RATE);
		float out[2];
		for (int c = 0; c < 2; c++) {
			const float n = _noise();
			leaf_hp[c] += (n - leaf_hp[c]) * a_hp;
			leaf_lp[c] += ((n - leaf_hp[c]) - leaf_lp[c]) * a_lp;
			leaf_lp2[c] += (leaf_lp[c] - leaf_lp2[c]) * a_lp;
			out[c] = leaf_lp2[c] * amp * 1.1f;
		}
		l += out[0];
		r += out[1];
	}

	// Surf: two staggered breakers; each crashes then washes out, getting duller as it fades
	if (level[AudioStreamEdenAmbience::LAYER_SURF] > 1e-4f) {
		for (Wave &w : waves) {
			w.t += dt;
			if (w.t >= w.period) {
				w.t = 0;
				w.period = _range(7.0f, 12.0f);
				w.gain = _range(0.55f, 1.0f);
			}
			const float x = w.t / w.period;
			// Swell, crash, long wash, over a constant distant roar
			const float crash = x < 0.25f ? _smoothstep(0.0f, 0.25f, x) : std::exp(-(x - 0.25f) * 3.5f);
			const float env = 0.2f + 0.8f * crash;
			const float a = _lp_coef(200.0f + 1600.0f * crash * crash, RATE);
			w.lp += (_noise() - w.lp) * a;
			w.lp2 += (w.lp - w.lp2) * a;
			const float v = w.lp2 / std::sqrt(a) * env * w.gain * level[AudioStreamEdenAmbience::LAYER_SURF] * 0.28f;
			l += v * std::sqrt(0.5f * (1.0f - w.pan));
			r += v * std::sqrt(0.5f * (1.0f + w.pan));
		}
	}

	float wet_l = 0, wet_r = 0;

	// Birds
	const float birds = level[AudioStreamEdenAmbience::LAYER_BIRDS];
	bird_timer -= dt;
	if (bird_timer <= 0) {
		bird_timer = _range(0.2f, 1.3f);
		if (_rand() < birds) {
			_spawn_bird();
		}
	}
	for (Voice &v : voices) {
		if (v.kind < 0) {
			continue;
		}
		v.t += dt;
		if (v.t >= v.dur) {
			v.kind = -1;
			continue;
		}
		float freq = 0, env = 0;
		if (v.kind == 0) {
			const float slot = v.dur / v.notes;
			const float note = std::floor(v.t / slot);
			const float u = (v.t - note * slot) / (slot * 0.8f);
			const float glide = ((int)note & 1) ? 1.0f - u : u;
			freq = Math::lerp(v.f0, v.f1, CLAMP(glide, 0.0f, 1.0f)) * (1.0f + 0.012f * std::sin(TAU_F * 28.0f * v.t));
			env = u < 1.0f ? std::sin(Math::PI * u) : 0.0f;
			env *= env;
		} else if (v.kind == 1) {
			const float u = v.t / v.dur;
			freq = Math::lerp(v.f0, v.f1, u);
			const float am = MAX(std::sin(TAU_F * v.rate * v.t), 0.0f);
			env = std::sin(Math::PI * u) * am * am;
		} else {
			const float ct = std::fmod(v.t, 1.0f / v.rate);
			const float u = ct / 0.035f;
			freq = Math::lerp(v.f0, v.f1, MIN(u, 1.0f));
			env = u < 1.0f ? std::sin(Math::PI * u) : 0.0f;
		}
		v.phase += freq * dt;
		v.phase -= std::floor(v.phase);
		const float tone = (std::sin(TAU_F * v.phase) + 0.12f * std::sin(2.0f * TAU_F * v.phase)) * env * v.gain;
		v.lps += (tone - v.lps) * v.lp; // distance low-pass
		const float filtered = v.lps;
		const float gl = std::sqrt(0.5f * (1.0f - v.pan)), gr = std::sqrt(0.5f * (1.0f + v.pan));
		const float dry = filtered * birds * 0.3f;
		l += dry * gl;
		r += dry * gr;
		wet_l += dry * gl;
		wet_r += dry * gr;
	}

	// Crickets: each a pure tone pulsed three times per chirp
	const float crick = level[AudioStreamEdenAmbience::LAYER_CRICKETS];
	if (crick > 1e-4f) {
		for (Cricket &c : crickets) {
			c.clock += dt;
			const float period = 1.0f / c.rate;
			const float ct = std::fmod(c.clock + c.offset * period, period);
			const int pulse = (int)(ct / 0.034f);
			const float pt = ct - pulse * 0.034f;
			c.phase += c.freq * dt;
			c.phase -= std::floor(c.phase);
			if (pulse < 3 && pt < 0.02f) {
				const float v = std::sin(TAU_F * c.phase) * std::sin(Math::PI * pt / 0.02f) * c.gain * crick * 0.18f;
				const float gl = std::sqrt(0.5f * (1.0f - c.pan)), gr = std::sqrt(0.5f * (1.0f + c.pan));
				l += v * gl;
				r += v * gr;
				wet_l += v * gl;
				wet_r += v * gr;
			}
		}
	}

	// Rain: a steady hiss with a low roar underneath
	const float rain = level[AudioStreamEdenAmbience::LAYER_RAIN];
	if (rain > 1e-4f) {
		// Soft, darker hiss (two poles at 3.5 kHz) whose loudness drifts as the shower thickens and eases
		const float a_hp = _lp_coef(500.0f, RATE), a_lp = _lp_coef(3500.0f, RATE), a_body = _lp_coef(350.0f, RATE);
		if (_rand() < 3.0f * dt) {
			rain_swell_target = _rand();
		}
		rain_swell += (rain_swell_target - rain_swell) * dt * 1.5f;
		const float amp = rain * (0.7f + 0.3f * rain_swell);
		for (int c = 0; c < 2; c++) {
			const float n = _noise();
			rain_hp[c] += (n - rain_hp[c]) * a_hp;
			rain_lp[c] += ((n - rain_hp[c]) - rain_lp[c]) * a_lp;
			rain_lp2[c] += (rain_lp[c] - rain_lp2[c]) * a_lp;
			rain_body[c] += (n - rain_body[c]) * a_body;
			(c == 0 ? l : r) += amp * (rain_lp2[c] * 0.45f + rain_body[c] / std::sqrt(a_body) * 0.07f);
		}
	}

	// Thunder
	const uint32_t serial = s->thunder_serial.load(std::memory_order_acquire);
	if (serial != thunder_seen) {
		thunder_seen = serial;
		// A free slot, else replace the one that has rolled longest
		Thunder *slot = &thunders[0];
		for (Thunder &th : thunders) {
			if (!th.active || th.t > slot->t) {
				slot = &th;
				if (!th.active) {
					break;
				}
			}
		}
		*slot = Thunder();
		slot->active = true;
		slot->t = -s->thunder_delay.load(std::memory_order_relaxed);
		slot->dist = CLAMP(s->thunder_distance.load(std::memory_order_relaxed), 0.0f, 1.0f);
	}
	// Footsteps
	const uint32_t step_ser = s->step_serial.load(std::memory_order_acquire);
	if (step_ser != step_seen) {
		step_seen = step_ser;
		Step *slot = &steps[0];
		for (Step &st : steps) {
			if (!st.active || st.t > slot->t) {
				slot = &st;
				if (!st.active) {
					break;
				}
			}
		}
		*slot = Step();
		slot->active = true;
		slot->surface = s->step_surface.load(std::memory_order_relaxed);
		slot->strength = s->step_strength.load(std::memory_order_relaxed) * _range(0.8f, 1.1f);
		slot->pan = s->step_pan.load(std::memory_order_relaxed);
		slot->vary = _range(0.88f, 1.12f);
		slot->toe = _range(0.07f, 0.12f);
	}
	for (Step &st : steps) {
		if (st.active) {
			_step_frame(st, l, r);
		}
	}

	const float thunder_gain = s->thunder_gain.load(std::memory_order_relaxed);
	for (Thunder &th : thunders) {
		if (th.active) {
			_thunder_frame(th, thunder_gain, l, r);
		}
	}

	// Slapback echo for the calls: reads as open air instead of a dry studio take
	const int dl = (echo_pos - 3300) & 8191, dr = (echo_pos - 4700) & 8191;
	const float el = echo[0][dl], er = echo[1][dr];
	echo[0][echo_pos] = wet_l + er * 0.35f;
	echo[1][echo_pos] = wet_r + el * 0.35f;
	echo_pos = (echo_pos + 1) & 8191;
	l += el * 0.3f;
	r += er * 0.3f;

	const float g = s->out_gain.load(std::memory_order_relaxed);
	const float pan = s->out_pan.load(std::memory_order_relaxed);
	if (cur_gain < 0.0f || snap_levels) {
		cur_gain = g;
		cur_pan = pan;
	}
	cur_gain += (g - cur_gain) * (dt / 0.08f);
	cur_pan += (pan - cur_pan) * (dt / 0.08f);
	// Balance, not a mono pan: the layers keep their stereo width, one side just drops away
	l *= cur_gain * MIN(1.0f, 1.0f - cur_pan);
	r *= cur_gain * MIN(1.0f, 1.0f + cur_pan);
	r_l = std::tanh(l);
	r_r = std::tanh(r);
}

// One footstep, heel then toe: the heel strikes (a soft thump under every surface plus the surface's own sound), and
// 70-120 ms later the toe rolls down with a quieter copy of it. Each step's timbre is shifted a little (vary), so a
// walk never repeats. Grass rustles, moss squishes softly, dirt thuds with a little grit, sand shifts in fine
// grains, snow crunches with a cold squeak, rock clicks and scuffs, wood knocks hollow, wet ground splashes.
void AudioStreamPlaybackEdenAmbience::_step_frame(Step &p_step, float &r_l, float &r_r) {
	constexpr float dt = 1.0f / RATE;
	p_step.t += dt;
	const float T = p_step.t;
	if (T > 0.45f) {
		p_step.active = false;
		return;
	}
	const float vary = p_step.vary;
	const float Tt = T - p_step.toe; // the toe's own clock (negative until it lands)
	// Heel and toe envelopes for a surface sound that decays over `tau` seconds after an `attack`
	auto hit = [&](float p_attack, float p_tau) {
		const float heel = _smoothstep(0.0f, p_attack, T) * std::exp(-T / p_tau);
		const float toe = Tt > 0.0f ? 0.55f * _smoothstep(0.0f, p_attack, Tt) * std::exp(-Tt / p_tau) : 0.0f;
		return heel + toe;
	};
	const float n = _noise();
	const float a_thump = _lp_coef(240.0f * vary, RATE);
	p_step.thump += (n - p_step.thump) * a_thump;
	const float thump = p_step.thump / std::sqrt(a_thump) * 0.12f * hit(0.004f, 0.028f);
	float v = 0.0f;
	switch (p_step.surface) {
		case AudioStreamEdenAmbience::SURFACE_ROCK: {
			// A hard click, a short stony ring, and grit scuffed under the toe
			const float click = n * (std::exp(-T / 0.003f) + (Tt > 0.0f ? 0.5f * std::exp(-Tt / 0.003f) : 0.0f)) * 0.32f;
			p_step.ring += 2300.0f * vary * dt;
			p_step.ring2 += 3700.0f * vary * dt;
			const float ring = (std::sin(TAU_F * p_step.ring) + 0.5f * std::sin(TAU_F * p_step.ring2)) * std::exp(-T / 0.025f) * 0.05f;
			const float f = 2.0f * std::sin(Math::PI * 4200.0f * vary / RATE);
			const float scuff = Tt > 0.0f ? _svf_band(n, f, 0.7f, p_step.band_low, p_step.band) * _smoothstep(0.0f, 0.01f, Tt) * std::exp(-Tt / 0.04f) * 0.12f : 0.0f;
			v = thump * 0.8f + click + ring + scuff;
		} break;
		case AudioStreamEdenAmbience::SURFACE_DIRT: {
			// A dull thud with a mid "puff", and a few crumbs crackling as the sole settles
			const float f = 2.0f * std::sin(Math::PI * 650.0f * vary / RATE);
			const float mid = _svf_band(n, f, 1.2f, p_step.band_low, p_step.band) * hit(0.006f, 0.05f) * 0.2f;
			if (_rand() < 260.0f * dt * hit(0.01f, 0.08f)) {
				p_step.grit = _noise();
			}
			p_step.grit *= 0.8f;
			const float f2 = 2.0f * std::sin(Math::PI * 2600.0f * vary / RATE);
			const float crumbs = _svf_band(p_step.grit, f2, 0.9f, p_step.band_low2, p_step.band2) * 0.22f;
			v = thump * 1.2f + mid + crumbs;
		} break;
		case AudioStreamEdenAmbience::SURFACE_SAND: {
			// Fine grains shifting: dense tiny impulses, band-limited, over a soft low "shff"
			const float env = hit(0.02f, 0.11f);
			if (_rand() < 2600.0f * dt * env) {
				p_step.crunch = _noise();
			}
			p_step.crunch *= 0.7f;
			const float f = 2.0f * std::sin(Math::PI * 3000.0f * vary / RATE);
			const float grains = _svf_band(p_step.crunch, f, 1.1f, p_step.band_low, p_step.band) * 0.3f;
			const float f2 = 2.0f * std::sin(Math::PI * 420.0f * vary / RATE);
			const float shff = _svf_band(n, f2, 1.4f, p_step.band_low2, p_step.band2) * env * 0.12f;
			v = thump * 0.55f + grains + shff;
		} break;
		case AudioStreamEdenAmbience::SURFACE_SNOW: {
			// Grains snapping as the snow packs (dense at first, band-limited so they crunch rather than tick), and a
			// faint squeak sliding down while it compresses
			const float env = hit(0.012f, 0.08f);
			if (_rand() < 1100.0f * dt * env) {
				p_step.crunch = _noise();
			}
			p_step.crunch *= 0.85f;
			const float f = 2.0f * std::sin(Math::PI * 1900.0f * vary / RATE);
			const float crunch = _svf_band(p_step.crunch, f, 0.9f, p_step.band_low, p_step.band) * 0.55f;
			p_step.ring += Math::lerp(1150.0f, 720.0f, MIN(T / 0.12f, 1.0f)) * vary * dt;
			const float squeak = std::sin(TAU_F * p_step.ring) * _smoothstep(0.02f, 0.05f, T) * (1.0f - _smoothstep(0.08f, 0.14f, T)) * 0.025f;
			v = thump * 0.7f + crunch + squeak;
		} break;
		case AudioStreamEdenAmbience::SURFACE_MOSS: {
			// Soft and damp: a muffled thump and a low wet squish, no bright rustle
			p_step.low += (n - p_step.low) * _lp_coef(700.0f * vary, RATE);
			const float f = 2.0f * std::sin(Math::PI * 520.0f * vary / RATE);
			const float squish = _svf_band(p_step.low, f, 0.6f, p_step.band_low, p_step.band) * hit(0.02f, 0.07f) * 0.5f;
			v = thump * 0.75f + squish;
		} break;
		case AudioStreamEdenAmbience::SURFACE_WOOD: {
			// A hollow knock: two plank resonances ringing briefly under a dry click
			const float click = n * (std::exp(-T / 0.002f) + (Tt > 0.0f ? 0.4f * std::exp(-Tt / 0.002f) : 0.0f)) * 0.06f;
			p_step.ring += 185.0f * vary * dt;
			p_step.ring2 += 430.0f * vary * dt;
			const float body = (std::sin(TAU_F * p_step.ring) * 0.6f + std::sin(TAU_F * p_step.ring2) * 0.4f) * hit(0.002f, 0.06f) * 0.16f;
			v = thump * 0.5f + click + body;
		} break;
		case AudioStreamEdenAmbience::SURFACE_WET: {
			const float f = 2.0f * std::sin(Math::PI * 1500.0f * vary / RATE);
			const float splash = _svf_band(n, f, 0.8f, p_step.band_low, p_step.band) * hit(0.004f, 0.08f) * 0.3f;
			p_step.ring += Math::lerp(750.0f, 320.0f, MIN(T / 0.12f, 1.0f)) * vary * dt;
			const float bubble = std::sin(TAU_F * p_step.ring) * std::exp(-T / 0.05f) * _smoothstep(0.01f, 0.03f, T) * 0.05f;
			v = thump * 0.5f + splash + bubble;
		} break;
		default: { // grass
			// Blades brushing the foot: bright noise with an uneven, fluttering level, on the heel and the toe
			p_step.low += (n - p_step.low) * _lp_coef(1500.0f * vary, RATE);
			// (band-limited to ~1.5-6 kHz: above that it read as hiss rather than leaves)
			p_step.low2 += ((n - p_step.low) - p_step.low2) * _lp_coef(6000.0f * vary, RATE);
			const float swish = p_step.low2 * 1.4f * hit(0.012f, 0.075f);
			if (_rand() < 70.0f * dt) {
				p_step.crunch = 0.4f + 0.6f * _rand();
			}
			p_step.crunch += (0.5f - p_step.crunch) * dt * 30.0f;
			v = thump * 0.6f + swish * 0.32f * p_step.crunch;
		} break;
	}
	v *= p_step.strength;
	r_l += v * std::sqrt(0.5f * (1.0f - p_step.pan)) * 1.41f;
	r_r += v * std::sqrt(0.5f * (1.0f + p_step.pan)) * 1.41f;
}

// One thunder strike, modelled on a recorded close strike: a ~100 ms swell into a broadband crack (the first
// ~0.2 s carries real energy above 2 kHz), a crackling "tearing" band at 200 Hz..2 kHz for about a second, and a
// rolling rumble that starts bright and settles to ~150..400 Hz, swelling at random and decaying ~3 dB/s.
// Far strikes (dist -> 1) keep only a slower, darker, shorter rumble: the soft low bumps under distant storms.
void AudioStreamPlaybackEdenAmbience::_thunder_frame(Thunder &p_th, float p_gain, float &r_l, float &r_r) {
	constexpr float dt = 1.0f / RATE;
	p_th.t += dt;
	const float T = p_th.t;
	if (T < 0.0f) {
		return;
	}
	const float near = (1.0f - p_th.dist) * (1.0f - p_th.dist);
	const float dur = Math::lerp(3.5f, 10.0f, 1.0f - p_th.dist);
	if (T > dur) {
		p_th.active = false;
		return;
	}
	// Crackle: fast random level jumps (the tearing texture), and slow swells (the roll)
	if (_rand() < 45.0f * dt) {
		p_th.crackle_target = 0.25f + 0.75f * Math::sqrt(_rand());
	}
	p_th.crackle += (p_th.crackle_target - p_th.crackle) * dt * 90.0f;
	if (_rand() < 2.5f * dt) {
		p_th.swell_target = _range(0.45f, 1.2f);
	}
	p_th.swell += (p_th.swell_target - p_th.swell) * dt * 3.0f;

	const float attack = _smoothstep(0.0f, 0.1f + 0.5f * p_th.dist, T);
	const float fade = 1.0f - _smoothstep(dur * 0.6f, dur, T);
	const float rumble_env = std::exp(-T / Math::lerp(1.2f, 3.0f, 1.0f - p_th.dist)) * p_th.swell;
	const float tear_env = near * std::exp(-T / 0.55f) * p_th.crackle;
	const float crack_env = near * std::exp(-T / 0.12f) * (0.5f + 0.5f * p_th.crackle);
	// Rumble brightness: sweeps down from ~900 Hz (near) and settles; far strikes stay dark
	const float fc = Math::lerp(140.0f, 280.0f, 1.0f - p_th.dist) + 650.0f * near * std::exp(-T / 0.7f);
	const float a = _lp_coef(fc, RATE);
	const float a_sub = _lp_coef(70.0f, RATE);
	const float a_t_hp = _lp_coef(200.0f, RATE), a_t_lp = _lp_coef(2000.0f, RATE), a_c = _lp_coef(1500.0f, RATE);
	const float level = attack * fade * p_gain * Math::lerp(0.8f, 2.6f, near);
	for (int c = 0; c < 2; c++) {
		const float n = _noise();
		p_th.lp[c] += (n - p_th.lp[c]) * a;
		p_th.lp2[c] += (p_th.lp[c] - p_th.lp2[c]) * a;
		p_th.sub[c] += (n - p_th.sub[c]) * a_sub;
		p_th.tear_hp[c] += (n - p_th.tear_hp[c]) * a_t_hp;
		p_th.tear_lp[c] += ((n - p_th.tear_hp[c]) - p_th.tear_lp[c]) * a_t_lp;
		p_th.crack_lp[c] += (n - p_th.crack_lp[c]) * a_c;
		const float rumble = p_th.lp2[c] / std::sqrt(a) * 0.42f + p_th.sub[c] / std::sqrt(a_sub) * 0.25f;
		const float tear = p_th.tear_lp[c] * 1.6f;
		const float crack = (n - p_th.crack_lp[c]) * 0.9f;
		const float v = (rumble * rumble_env + tear * tear_env + crack * crack_env) * level;
		(c == 0 ? r_l : r_r) += v;
	}
}

int AudioStreamPlaybackEdenAmbience::_mix_internal(AudioFrame *p_buffer, int p_frames) {
	if (!active || stream.is_null()) {
		return 0;
	}
	for (int i = 0; i < p_frames; i++) {
		_frame(p_buffer[i].left, p_buffer[i].right);
	}
	return p_frames;
}
