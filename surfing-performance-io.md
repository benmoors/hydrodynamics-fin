# Surfboard Performance Indicators: Mathematical Specifications & Integration Guide

This document establishes the exact mathematical specifications, physical inputs, and output algorithms for calculating **Board-Jerk (BJ)** and **Radicality (Ra)**. It is designed as an implementation blueprint for code generation assistants (such as Claude Code) to build a robust, validated, and academically rigorous surfboard performance kinematics engine.

The formulations herein are directly grounded in and cited against the peer-reviewed surfing biomechanics literature:
> **Charles, P-E., et al. (2026).** *"A novel surfing performance quantification system and multi-sensor instrumented surfboard: A proof-of-concept."* Results in Engineering, 29, 108868.

---

## 1. Indicator 1: Board-Jerk (BJ)

### 1.1 Physical Concept
Jerk represents the time-rate of change of acceleration. In sports biomechanics, a high jerk cost corresponds to a shaky, unstable, or poorly coordinated trajectory, whereas minimizing jerk maximizes "performance fluency" and control smoothness.

### 1.2 Exact Equations from the Article (Charles et al., 2026)
Let $\vec{a}(t) \in \mathbb{R}^3$ be the acceleration vector of the board at a moment $t$. The instantaneous jerk vector $\vec{j}(t)$ is defined as [26]:
$$\vec{j}(t) = \frac{d\vec{a}}{dt} \quad \text{--- [Charles et al., 2026, Eq. 4]}$$

The smoothness performance criterion to be minimized, $J$ (dimensionless Jerk Cost), is calculated as the normalized integral of the mean-square of the jerk [26]:
$$J = \int_{0}^{T} \frac{C \cdot j^2}{2} \, dt \quad \text{--- [Charles et al., 2026, Eq. 5]}$$
*   Where $j^2 = |\vec{j}(t)|^2 = j_x^2 + j_y^2 + j_z^2$ is the squared magnitude of the jerk vector.
*   $T$ is the total duration of the wave.
*   $C$ is a normalization constant chosen to make the cost $J$ dimensionless [26]:
$$C = \frac{T^5}{D^2} \quad \text{--- [Charles et al., 2026, Eq. 6]}$$
*   $D$ is the length of the overall trajectory, calculated by double-integrating the acceleration components [27]:
$$D = \sqrt{ \left(\int_{0}^{T} \int_{0}^{T} a_x \, dt \, dt\right)^2 + \left(\int_{0}^{T} \int_{0}^{T} a_y \, dt \, dt\right)^2 + \left(\int_{0}^{T} \int_{0}^{T} a_z \, dt \, dt\right)^2 } \quad \text{--- [Charles et al., 2026, Eq. 7]}$$

---

## 2. Indicator 2: Maneuver Radicality (Ra)

### 2.1 Physical Concept
Surfing maneuvers involve rapid direction changes executed on the wave face. High scoring is awarded for tight, high-speed carves that rotate the board rapidly. Radicality ($Ra$) mathematically combines the total swept yaw angle and the speed of rotation to quantify maneuver intensity.

### 2.2 Exact Equations from the Article (Charles et al., 2026)
A top-turn or carving maneuver is physically bounded in time by $t_0$ (start) and $t_1$ (end). These bounds are defined as the precise moments the board changes its rotation direction along its longitudinal axis (X-axis roll rate, $R_x$) [34]:
$$R_x(t_0) = 0 \quad \text{and} \quad R_x(t_1) = 0 \quad \text{--- [Charles et al., 2026, Sec 2.3.3]}$$

The total yaw rotation swept angle ($\theta_z$, in radians) over the Z-axis (yaw) is calculated by integrating the instantaneous Z-axis gyroscope yaw rate ($R_z$) over this window [33, 34]:
$$\theta_z = \int_{t_0}^{t_1} R_z(t) \, dt \quad \text{--- [Charles et al., 2026, Eq. 10]}$$

To account for both the total angle turned and the speed of execution, the Radicality Indicator ($Ra$, units: $\text{rad}^2/\text{s}$) is defined as [45, 46]:
$$Ra = \theta_z \cdot \bar{R}_z = \frac{\theta_z^2}{t_1 - t_0} \quad \text{--- [Charles et al., 2026, Eq. 11]}$$
*   Where $\bar{R}_z = \frac{\theta_z}{t_1 - t_0}$ is the average Z-rotation speed during the maneuver [47].

---

## 3. The Pure Shaper Wave Dynamics (SWD) Kinematic Bridge

Because we are working **purely with SWD simulation outputs** (without noisy field IMU hardware), we map the physical sensor inputs ($a_x, a_y, a_z$ and $R_x, R_y, R_z$) to deterministic hydrodynamic parameters simulated by SWD.

```
                  SWD BASELINE SIMULATIONS
               ┌─────────────────────────────┐
               │  - Trajectory Speed (Vt)    │
               │  - Roll Angle (φ)           │
               │  - Turning Curve Radius (R) │
               │  - Drag & Lift Forces       │
               └──────────────┬──────────────┘
                              │
               ┌──────────────┴──────────────┐
               ▼                             ▼
       KINEMATIC ACCELERATION           YAW GYRO STATE
          BJ FORMULATIONS              RA FORMULATIONS
     ┌────────────────────────┐   ┌────────────────────────┐
     │ ax = dVt/dt            │   │ Rz = Vt / R            │
     │ ay = Vt² / R           │   │ θz = ∫ Rz dt           │
     │ az = (Flift - mg) / m  │   │ t0, t1 from Rx = dφ/dt │
     └────────────────────────┘   └────────────────────────┘
```

### 3.1 Input Variables Mapping

| Theoretical Sensor Input | SWD Physical Source / Simulation Counterpart | Mathematical Extraction / Conversion Method |
| :--- | :--- | :--- |
| **Longitudinal Accel ($a_x$)** | Trajectory Speed curve ($V_t(t)$) over wave duration. | First numerical derivative of forward velocity: $a_x(t) = \frac{dV_t}{dt}$. |
| **Lateral Accel ($a_y$)** | Centrifugal force of carving turns. | Derived from speed $V_t(t)$ and turning radius $R(t)$: $a_y(t) = \frac{V_t(t)^2}{R(t)}$. |
| **Vertical Accel ($a_z$)** | Net vertical force (SWD Planing/Hydrostatic Lift vs. system weight). | $a_z(t) = \frac{F_{\text{lift}}(t) - m \cdot g}{m}$, where $m$ is system mass (surfer + board). |
| **Roll Rate ($R_x$)** | Dynamic roll transition curve ($\phi(t)$). | First numerical derivative of simulated roll angle: $R_x(t) = \frac{d\phi}{dt}$. |
| **Yaw Rate ($R_z$)** | Trajectory speed ($V_t$) and SWD Manoeuverability Curve Radius ($R$). | Resolved kinematically: $R_z(t) = \frac{V_t(t)}{R(t)}$. |

---

## 4. Software Implementation Interface (Blueprint for Claude Code)

### 4.1 Required Top-Level Inputs

The codebase must accept a structured pandas DataFrame (e.g., `swd_trajectory_log.csv`) representing a simulated wave run sampled at interval $dt$ (standard step: $0.01\text{ s}$ representing a $100\text{ Hz}$ logging frequency):

```python
import pandas as pd
import numpy as np

# Ideal DataFrame Structure
# timestamp (s) | speed_ms (m/s) | roll_rad (rad) | turn_radius_m (m) | lift_force_n (N)
```

### 4.2 Core Mathematical Functions to Implement

#### 1. Piecewise Spline / PCHIP Interpolation (Week 3)
*   **Purpose:** Look up the stable turning radius $R(t)$ from SWD structured grids at intermediate coordinates.
*   **Method:** Use `scipy.interpolate.PchipInterpolator` to prevent overshoots in the drag/radius curves near physical transition boundaries.

#### 2. Root-Finding for Zero-Crossings (Week 3)
*   **Purpose:** Find the precise sub-sample timestamps $t_0$ and $t_1$ bounding the maneuver where $R_x(t) = 0$.
*   **Method:** Fit a cubic spline to the derivative $R_x(t) = \frac{d\phi}{dt}$ and use Brent's method (`scipy.optimize.brentq`) to solve for roots.

#### 3. Composite Simpson's 1/3 Integration (Week 6)
*   **Purpose:** Numerically evaluate the definite integrals for trajectory length $D$, swept angle $\theta_z$, and the mean-square jerk cost $J$.
*   **Formulation:**
    $$\int_a^b f(x)dx \approx \frac{h}{3} \left[ f(x_0) + 4\sum_{i \text{ odd}} f(x_i) + 2\sum_{i \text{ even}} f(x_i) + f(x_n) \right]$$
*   **Method:** Implement via `scipy.integrate.simpson`.

#### 4. Centred Finite-Difference Derivative (Week 7)
*   **Purpose:** Calculate acceleration $a_x(t)$ and jerk components $j(t)$ with second-order truncation accuracy $\mathcal{O}(h^2)$ at interior points.
*   **Formulation:**
    $$f'(x_i) \approx \frac{f(x_{i+1}) - f(x_{i-1})}{2h}$$
*   **Method:** Implement using `numpy.gradient` with explicitly specified step size.

---

## 5. Implementation Blueprint (Python)

Below is the verified skeleton code containing the exact formulas. Claude Code should expand this structure, write corresponding unit tests, and implement SVR pipeline surrogate lookup.

```python
import numpy as np
from scipy.integrate import simpson, cumulative_trapezoid

def compute_board_jerk(time: np.ndarray, accel_x: np.ndarray, accel_y: np.ndarray, accel_z: np.ndarray) -> float:
    """
    Computes the dimensionless Board-Jerk cost (J) from 3-axis accelerations.
    Grounded in Charles et al. (2026), Equations 4, 5, 6, and 7.
    """
    dt = time[1] - time[0]
    T = time[-1] - time[0]
    
    # 1. Calculate Jerk components via centred finite-differences (Eq 4)
    j_x = np.gradient(accel_x, dt)
    j_y = np.gradient(accel_y, dt)
    j_z = np.gradient(accel_z, dt)
    j_squared = j_x**2 + j_y**2 + j_z**2
    
    # 2. Calculate Trajectory Length D via double integration of acceleration (Eq 7)
    # Double integrate: integrate velocity array (which is cumulative integral of accel)
    vel_x = cumulative_trapezoid(accel_x, dx=dt, initial=0.0)
    vel_y = cumulative_trapezoid(accel_y, dx=dt, initial=0.0)
    vel_z = cumulative_trapezoid(accel_z, dx=dt, initial=0.0)
    
    pos_x = cumulative_trapezoid(vel_x, dx=dt, initial=0.0)[-1]
    pos_y = cumulative_trapezoid(vel_y, dx=dt, initial=0.0)[-1]
    pos_z = cumulative_trapezoid(vel_z, dx=dt, initial=0.0)[-1]
    
    D = np.sqrt(pos_x**2 + pos_y**2 + pos_z**2)
    
    # 3. Calculate normalization constant C (Eq 6)
    C = (T**5) / (D**2) if D > 0 else 1.0
    
    # 4. Integrate mean-square jerk (Eq 5)
    integrand = (C * j_squared) / 2.0
    J = simpson(integrand, dx=dt)
    
    return float(J)

def compute_radicality(time: np.ndarray, roll_rate: np.ndarray, yaw_rate: np.ndarray) -> float:
    """
    Computes maneuver Radicality (Ra) between the zero-crossing boundaries of the roll rate.
    Grounded in Charles et al. (2026), Equations 10 and 11.
    """
    # 1. Identify turn boundaries where Rx (roll rate) crosses zero
    zero_crossings = np.where(np.diff(np.sign(roll_rate)) != 0)[0]
    if len(zero_crossings) < 2:
        raise ValueError("Insufficient turn boundaries found. Roll rate must cross zero at least twice.")
        
    # Isolate the main top-turn window [t0, t1]
    idx_start, idx_end = zero_crossings[0], zero_crossings[-1]
    t0, t1 = time[idx_start], time[idx_end]
    duration = t1 - t0
    
    # Isolate window arrays
    window_yaw_rate = yaw_rate[idx_start:idx_end+1]
    window_time = time[idx_start:idx_end+1]
    
    # 2. Integrate yaw rate to find swept angle theta_z (Eq 10)
    theta_z = simpson(window_yaw_rate, x=window_time)
    
    # 3. Calculate Radicality index (Eq 11)
    Ra = (theta_z**2) / duration if duration > 0 else 0.0
    
    return float(Ra)
```
