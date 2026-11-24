"""Imitate the old side-view gait and test it in a sagittal-plane dynamics model."""
import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import sys

import mujoco
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Rig"))
from side import walking_targets

# Order matches hip and knee actuators. Positive world x is toward the head.
PAWS = ("paw", "farPaw", "rearFoot", "farRearFoot")
PIXEL_METRES = 0.00130  # illustrative scale, not a measurement of Dada
PERIOD = 0.8
LINK = 0.13
DEPTH = 0.213
EDGE = 0.61
DT = 0.002
CONTROL_STEPS = 10
FOOT_RADIUS = 0.012


def painting_targets(phase, speed):
    travel = speed * PERIOD / PIXEL_METRES
    points = walking_targets(phase, (1, 1), travel)
    return np.array([points[paw] for paw in PAWS])


def reference(phase, speed):
    # At zero stride x is the neutral centre. The maximum y is the stance floor.
    return (REST_PIXELS - painting_targets(phase, speed)) * PIXEL_METRES


REST_PIXELS = np.max([painting_targets(p / 100, 0) for p in range(100)], axis=0)


class GaitNetwork:
    """One tanh hidden layer with fixed random features and a ridge-trained readout."""

    def __init__(self, seed, samples=None):
        rng = np.random.default_rng(seed)
        self.weights = rng.normal(0, 1.5, (3, 96))
        self.bias = rng.normal(0, 1, 96)
        if samples is None:
            phase = rng.uniform(0, 1, 1600)
            speed = rng.uniform(0.12, 0.30, len(phase))
            labels = np.array([reference(p, s).reshape(-1) for p, s in zip(phase, speed)])
        else:
            phase, speed, labels = samples
        hidden = self.features(phase, speed)
        self.readout = np.linalg.solve(
            hidden.T @ hidden + 1e-5 * np.eye(hidden.shape[1]), hidden.T @ labels
        )

    def features(self, phase, speed):
        angle = 2 * np.pi * np.asarray(phase)
        inputs = np.stack([np.sin(angle), np.cos(angle), (np.asarray(speed) - .21) / .09], axis=-1)
        hidden = np.tanh(inputs @ self.weights + self.bias)
        return np.concatenate([hidden, np.ones_like(hidden[..., :1])], axis=-1)

    def __call__(self, phase, speed):
        return (self.features(phase, speed) @ self.readout).reshape(4, 2)


def make_model(step, friction):
    limbs = []
    actuators = []
    for index, name in enumerate(PAWS):
        hip_x = .145 if index < 2 else -.145
        hip_y = .036 if index % 2 == 0 else -.036
        knee_limits = "-2.55 -0.08" if index < 2 else "0.08 2.55"
        limbs.append(f"""
          <body pos="{hip_x} {hip_y} 0">
            <joint name="{name}_hip" axis="0 1 0" range="-1.65 1.65"/>
            <geom type="capsule" fromto="0 0 0 0 0 -{LINK}" size=".013" mass=".085"/>
            <body pos="0 0 -{LINK}">
              <joint name="{name}_knee" axis="0 1 0" range="{knee_limits}"/>
              <geom type="capsule" fromto="0 0 0 0 0 -{LINK}" size=".009" mass=".052"/>
              <geom name="{name}" type="sphere" pos="0 0 -{LINK}" size="{FOOT_RADIUS}" mass=".018"/>
            </body>
          </body>""")
        for joint in ("hip", "knee"):
            actuators.append(f'<position joint="{name}_{joint}"/>')

    platform = ""
    if step:
        platform = (f'<geom class="terrain" type="box" pos="{EDGE+2} 0 {step/2}" '
                    f'size="2 .4 {step/2}"/>')
    xml = f"""
    <mujoco>
      <compiler angle="radian"/>
      <option timestep="{DT}" integrator="implicitfast" gravity="0 0 -9.81"/>
      <default>
        <joint damping=".05" armature=".001"/>
        <geom contype="2" conaffinity="1" friction="{friction} .01 .001"/>
        <position kp="50" kv="1.1" forcerange="-4 4"/>
        <default class="terrain"><geom contype="1" conaffinity="2"/></default>
      </default>
      <worldbody>
        <geom class="terrain" type="plane" size="4 .6 .01"/>
        {platform}
        <body name="torso" pos="0 0 {DEPTH + FOOT_RADIUS}">
          <joint name="x" type="slide" axis="1 0 0" damping="0" armature="0"/>
          <joint name="z" type="slide" axis="0 0 1" damping="0" armature="0"/>
          <joint name="pitch" axis="0 1 0" damping="0" armature="0"/>
          <geom name="belly" type="ellipsoid" size=".197 .066 .060" mass="2.4"/>
          <geom name="head" type="sphere" pos=".197 0 .026" size=".053" mass=".28"/>
          {''.join(limbs)}
        </body>
      </worldbody>
      <actuator>{''.join(actuators)}</actuator>
    </mujoco>"""
    return mujoco.MjModel.from_xml_string(xml)


def joint_targets(toes):
    # Solve the opposite elbow/knee flexion of fore- and hindlegs.
    x = toes[:, 0]
    depth = DEPTH - toes[:, 1]
    cos_knee = np.clip((x*x + depth*depth) / (2*LINK*LINK) - 1, -1, 1)
    knee = np.array([-1, -1, 1, 1]) * np.arccos(cos_knee)
    hip = np.arctan2(-x, depth) - knee / 2
    return np.column_stack([hip, knee]).reshape(-1)


@dataclass
class Trial:
    distance: float
    crossed: bool
    fell: bool
    slip: float
    frames: list


class StepPreview:
    """Estimate the receiving surface once per swing using a short forward terrain probe."""

    offsets = np.array([.46, .96, .60, .10])
    hips = np.array([.145, .145, -.145, -.145])
    duty = .64

    def __init__(self):
        self.on = np.zeros(4)
        self.to = np.zeros(4)
        self.was_swing = np.zeros(4, dtype=bool)

    def adjust(self, toes, phase, root_x, speed, surface_height):
        leg_phase = (phase + self.offsets) % 1
        swing = leg_phase > self.duty
        self.on[~swing & self.was_swing] = self.to[~swing & self.was_swing]
        lift = swing & ~self.was_swing
        landing_x = root_x + self.hips + speed*PERIOD*(1-leg_phase + self.duty/2)
        self.to[lift] = surface_height(landing_x[lift] + FOOT_RADIUS)
        self.was_swing = swing
        fraction = np.clip((leg_phase - self.duty) / (1 - self.duty), 0, 1)
        # Resolve the riser early in swing, then keep the current stance level.
        ramp = np.clip(fraction / .40, 0, 1)
        ground = self.on + (self.to-self.on)*ramp*ramp*(3-2*ramp)
        result = toes.copy()
        result[:, 1] += ground - ground.mean()
        return result


def simulate(target, step, friction, speed, initial_phase, collect=False, preview=False):
    model = make_model(step, friction)
    data = mujoco.MjData(model)
    foot_ids = [model.geom(p).id for p in PAWS]
    knee_ids = model.geom_bodyid[foot_ids]
    hip_ids = model.body_parentid[knee_ids]
    paws = set(foot_ids)
    torso_parts = {model.geom(n).id for n in ("belly", "head")}
    control_dt = DT * CONTROL_STEPS
    cycle = round(PERIOD / control_dt)
    toes = [target((initial_phase + k / cycle) % 1, speed) for k in range(cycle)]
    targets = [joint_targets(v) for v in toes]
    previewer = StepPreview()

    def surface_height(x):
        return np.where((x > EDGE) & (x < EDGE + 4), step, 0)

    data.qpos[3:] = targets[0]
    jac = np.empty((3, model.nv))
    force = np.empty(6)
    slip = []
    frames = []
    fell = False
    for tick in range(round(6. / control_dt)):
        k = tick % cycle
        if preview:
            corrected = previewer.adjust(
                toes[k], (initial_phase + k / cycle) % 1, data.qpos[0], speed, surface_height
            )
            data.ctrl[:] = joint_targets(corrected)
        else:
            data.ctrl[:] = targets[k]
        for _ in range(CONTROL_STEPS):
            mujoco.mj_step(model, data)
        mujoco.mj_forward(model, data)
        for contact_index, contact in enumerate(data.contact):
            body_geom = next((int(g) for g in contact.geom if model.geom_contype[g] == 2), None)
            if body_geom in torso_parts:
                fell = True
            if body_geom not in paws:
                continue
            mujoco.mj_contactForce(model, data, contact_index, force)
            if force[0] < 1:
                continue
            mujoco.mj_jac(model, data, jac, None, contact.pos, model.geom_bodyid[body_geom])
            # Resolve the material-point velocity into the two contact tangents.
            slip.append(np.linalg.norm(contact.frame.reshape(3, 3)[1:] @ jac @ data.qvel))
        if collect and tick % 4 == 0:
            legs = np.stack((data.xpos[hip_ids], data.xpos[knee_ids], data.geom_xpos[foot_ids]), axis=1)
            frames.append((data.time, data.xpos[1, [0, 2]].copy(), data.qpos[2],
                           data.geom("head").xpos[[0, 2]].copy(), legs[:, :, [0, 2]]))
    # Both hip sockets must have passed the edge horizontally by the end.
    crossed = data.qpos[0] - abs(.145 * math.cos(data.qpos[2])) > EDGE
    return Trial(float(data.qpos[0]), crossed, fell, np.mean(slip) if slip else math.nan, frames)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=141)
    parser.add_argument("--gif", type=Path, help="save a same-scale comparison from three simulated runs")
    args = parser.parse_args()
    network = GaitNetwork(args.seed)
    test = np.random.default_rng(args.seed + 1)
    residual = []
    for phase, speed in zip(test.uniform(0, 1, 400), test.uniform(.12, .30, 400)):
        residual.extend(np.linalg.norm(network(phase, speed) - reference(phase, speed), axis=1))
    if args.gif:
        from preview import write_comparison
        examples = [simulate(network, h, .9, .22, 0, collect=True, preview=aware)
                    for h, aware in ((0, False), (.04, False), (.04, True))]
        write_comparison(args.gif, EDGE, examples)
    print(f"held-out mean toe target error = {1000*np.mean(residual):.2f} mm")
    print("controller  ground      runs  distance[m]  cleared  fell  contact slip[mm/s]")
    for controller, target in (("teacher", reference), ("network", network), ("preview", network)):
        for ground, height, friction in (("flat", 0, .9), ("slippery", 0, .12),
                                         ("step_4cm", .04, .9), ("step_8cm", .08, .9)):
            runs = [simulate(target, height, friction, speed, phase, preview=controller == "preview")
                    for speed in (.16, .22, .28) for phase in (0., .25, .5, .75)]
            print(f"{controller:10s}  {ground:10s}  {len(runs):4d}  "
                  f"{np.mean([r.distance for r in runs]):11.3f}  "
                  f"{sum(r.crossed and not r.fell for r in runs):7d}  "
                  f"{sum(r.fell for r in runs):4d}  {1000*np.mean([r.slip for r in runs]):18.2f}")


if __name__ == "__main__":
    main()
