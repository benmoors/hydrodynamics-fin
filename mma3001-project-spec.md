# MMA3001 Numerical Methods and Machine Learning – Project Specification & Syllabus Reference

This document compiles the complete syllabus structure, course requirements, grading rubrics, and detailed individual project specifications for **MMA3001 (Numerical Methods and Machine Learning)**. It is structured specifically as a context injector and prompt instruction sheet for **Claude Code** (or any engineering coding agent) to develop, validate, and document a high-scoring, accreditably defensible individual project.

---

## Part 1: MMA3001 Unit Overview & Weekly Syllabus

### Course Learning Outcomes (CLOs)
*   **LO1:** Assess the suitability and limitations of machine learning for current and emerging engineering applications, demonstrating awareness of future directions in engineering practice [170].
*   **LO2:** Demonstrate effective use of numerical analysis and machine learning tools to develop defensible solutions to open-ended engineering problems [170, 183].
*   **LO3:** Apply appropriate mathematical and numerical techniques to solve common engineering problems, and evaluate program performance, error, stability, and accuracy [170, 183].

### Weekly Topic Map & Numerical Tools
The following weekly schedule maps the required unit knowledge, Jupyter notebook exercises, and specific Python/SciPy modules taught in the unit [152, 153, 155]:

| Week | Core Topics Covered [152, 153] | Associated Jupyter Notebooks [153, 155] | Key Python Libraries & Functions Taught |
| :--- | :--- | :--- | :--- |
| **Week 1** | Digital Data Management, Documentation, Git, AI Ethics, & Automated Code Testing [152, 153] | `1.2 Data Management`, `1.3 Documenting Code`, `1.4 AI Use`, `1.5 Testing & Debugging` [155] | `git`, `pytest`, `pdb`, `pdoc`, `colab-print` (Mermaid diagrams) [159] |
| **Week 2** | Computer Architecture, Hardware Limits, Numerical Errors, & Linear Systems [152, 153] | `2.1 Optimisation & Profiling`, `2.2 Numerical Errors`, `2.3 Systems of Equations` [153, 154] | `line_profiler`, `scalene`, `likwid`, floating-point precision, LU Decomposition, SVD [159, 196, 199] |
| **Week 3** | Interpolation, Data Noise, Overfitting, Splines, & 2D Regular/Scattered Grids [152, 169] | `3.1 Interpolation vs Extrapolation`, `3.2 Noise & Overfitting`, `3.4 Splines`, `3.5 2D Interpolation` | `numpy.polynomial`, `scipy.interpolate` (`CubicSpline`, `PchipInterpolator`, `Akima1DInterpolator`, `RegularGridInterpolator`, `griddata`) |
| **Week 4** | **Mid-Semester Test 1 (25% of Mark)** (Covers Weeks 1–3) [166] | *Revision and solutions to practice tests* [158] | No new programming libraries introduced |
| **Week 5** | Machine Learning Regression, Data Pipelines, Holdout Sets, & Chronological Splits [152] | `5.1 Linear Regression`, `5.2 Decision Trees`, `5.4 Neural Networks`, `5.5 Performance Evaluation` [153, 154, 155] | `scikit-learn` (`LinearRegression`, `DecisionTreeRegressor`, `MLPRegressor`, `SVR`, `Pipeline`, `StandardScaler`, `train_test_split`) |
| **Week 6** | Numerical Integration, Newton-Cotes, Romberg Integration, & Gaussian Quadrature [152] | `6.1 Newton-Cotes`, `6.2 Integration Error`, `6.3 Romberg & Richardson`, `6.4 Gaussian Quadrature` [153, 154, 155] | `scipy.integrate` (`trapezoid`, `simpson`, `cumulative_trapezoid`, `fixed_quad`, `dblquad`, `nquad`) |
| **Week 7** | Numerical Differentiation & Ordinary Differential Equations (ODEs) [152] | `7.1 Finite Differences`, `7.2 ODE IVPs`, `7.3 Euler's Method`, `7.4 Runge-Kutta Methods` [153, 154, 155] | `numpy.gradient`, `scipy.signal.savgol_filter`, `scipy.integrate.solve_ivp` |
| **Week 8** | **Mid-Semester Test 2 (25% of Mark)** (Covers Weeks 5–7) [166] | *Project planning and selection finalized* [163] | Focus shifts to individual project workflows |
| **Week 9** | Improving ODE Accuracy, Numerical Stability, Stiff Systems, & Multistep Methods [152] | `9.1 ODE Accuracy`, `9.2 Stiff ODEs`, `9.3 Multistep Methods` | Multi-step solvers, stability region plotting, step-size control |
| **Week 10** | ODEs in Machine Learning, Neural ODEs, & Physics Informed Neural Networks (PINNs) [152] | `10.1 PINNs`, `10.2 ODEs in ML` [154] | Solving differential equations using deep learning backends |
| **Week 11** | Partial Differential Equations (PDEs), Finite Differences, Boundary Conditions [152] | `11.1 PDEs`, `11.2 Dirichlet & Neumann`, `11.3 Crank-Nicholson` [154, 155] | Time-marching finite differences, implicit solvers, sparse matrices |
| **Week 12** | **Mid-Semester Test 3 (25% of Mark)** (Covers Weeks 9–11) [167] | *SWOTVAC Revision / Code Finalisation* [152] | Study for written/calculation assessments |
| **Week 14** | **Project Presentation & Interview (25% of Mark)** [167] | *Individual Technical Defences* [167, 220] | Interactive terminal demonstrations of GitHub and code |

---

## Part 2: Individual Project Requirements & Assessment Criteria

The individual project is a major computational engineering deliverable worth **25% of the total unit mark** [202]. It must represent an open-ended, accreditably rigorous, and defensible computational implementation under version control [180, 202, 204].

### Required Deliverables
1.  **Written Project Report (5–10 pages maximum, via Moodle):** Outlining the engineering problem, inputs/outputs, computational solution, baseline comparisons, validation, and performance profiling [217].
2.  **Zipped Clone of GitHub Repository (via Moodle):** Must contain a functional master/main branch with clean directory architecture, an orienting README, automated test files (`pytest`), HTML code documentation (`pdoc`), a licensing agreement, and a complete code-commit history demonstrating version control usage [218, 219].
3.  **Live Technical Presentation & Q&A Interview (8 mins total):** Consists of a 5-minute technical slide presentation and a 3-minute Q&A defense. You must demonstrate live code usability, explain numerical stability, discuss sources of error, and defend technical choices [220, 221].

### Key Grading Rubric Categories & Excellence Standards [223-232]

#### 1. Engineering Problem, Inputs, & Outputs (Weight: 10) [223]
*   **Excellence Standard:** Precise definition of an engineering problem relevant to mechanical or aerospace engineering [205, 223]. Complete specifications for all top-level and function-level inputs and outputs, including data types (e.g., Float64 arrays), physical units, operating ranges, and mathematical domains [209, 223]. Explicit, justified strategies for handling missing data, `NaN` inputs, or out-of-bounds features [209, 223].

#### 2. GitHub Repository Structure, Commits, & README (Weight: 10) [225]
*   **Excellence Standard:** Logical folder structure (e.g., `/data`, `/src`, `/tests`, `/docs`). A README that provides a clear orientation, environment setup guides, package dependencies, and explicit workflow reproduction commands [225]. Version control must show consistent, meaningful commit messages and evidence of branching [219, 225].

#### 3. Inline Comments, Docstrings, & HTML Documentation (Weight: 10) [227]
*   **Excellence Standard:** Highly readable code where inline comments explain *intent* rather than restating the code [227]. All functions/classes must contain standard, complete **Google, NumPy, or Sphinx docstrings** describing arguments, types, return values, and raised exceptions [227]. Automated HTML documentation generated using tools like `pdoc` or `Sphinx` must be in sync with the source code [219, 227].

#### 4. Computational Solution & Alternative Baselines (Weight: 20) [230, 231]
*   **Excellence Standard:** Rigorous technical justification for the selected numerical/ML methods [230]. Implementation of a primary solution alongside **at least one credible baseline or alternative approach** for comparative benchmarking [210, 230]. Quantitative comparison addressing accuracy, computational runtime, memory requirements, and scalability [211, 230].

#### 5. Validation and Engineering Credibility (Weight: 25) [229]
*   **Excellence Standard:** Rigorous validation demonstrating strong engineering judgment [229]. Incorporates a **withheld test split (minimum 20%)** separate from training [173, 229]. Quantitative evaluation using appropriate performance metrics (RMSE, MAE, $R^2$) [175, 229]. Code verification using automated tests (`pytest`) that evaluate integration/differentiation on controlled, analytical test signals with known exact mathematical solutions [187, 219]. Explicitly details failure modes and what the validation cannot establish [212, 229].

#### 6. Optimisation and Performance Profiling (Weight: 15) [213, 214]
*   **Excellence Standard:** Comprehensive performance profiling using Python profilers (`cProfile`, `line_profiler`, or `Scalene`) to identify memory or CPU bottlenecks [159, 214]. Estimates of **Arithmetic Intensity (AI)** and required FLOPS [187, 214]. Quantitative, evidence-supported trade-offs between speed, grid resolution, and prediction accuracy, culminating in a justified final design [213, 214].

#### 7. AI Use and Critical Reflection (Weight: 10) [214, 215]
*   **Excellence Standard:** A complete, honest disclosure of all material AI use [215, 232]. Critical reflection detailing what tasks AI was used for, how its outputs were verified, errors or unhelpful advice generated, and how it affected technical understanding [215, 232]. The student must remain the clear driver of the design decisions [215, 232].

---

## Part 3: Project Specifications – "Virtual Surfer" Performance Simulator

The self-selected project modeled by this code is a **"Virtual Surfer" Dynamic Performance and Kinematic Simulation Engine**. It is designed to run entirely on simulation data from **Shaper Wave Dynamics (SWD)** to evaluate dynamic performance indicators.

### 1. The Core Engineering Challenge
Physics-based hydrodynamic solvers (like SWD) are computationally intensive and slow to evaluate. A surfboard shaper trying to dynamically evaluate a board's behavior across a continuous envelope of surfer weights, velocities, and turning angles cannot run costly fluid solvers in real time. 
*   **The Solution:** Build a fast, lightweight **Machine Learning Surrogate Model (Response Surface)** trained on discrete SWD hydrodynamic grids [176, 261].
*   **The Dynamic Simulator:** Program a synthetic "Virtual Surfer" trajectory generator that simulates on-wave paths, queries the ML surrogate at high frequencies (e.g., $100\text{ Hz}$), and applies numerical calculus to output dynamic surfing performance indicators: **Board-Jerk (BJ)** (smoothness of ride) and **Radicality (Ra)** (maneuvering intensity) [4].

### 2. High-Level System Data Architecture

```text
[ SWD Baseline Grids ]  ──> [ SVR ML Surrogate ] ──> Fast Physics Solver 
                                                          │
[ Virtual Surfer Path ] ──> [ (V(t), Roll(t)) ] ──────────┼─> [ Query Surrogate ] 
                                                          ▼
                                                   [ Radius R(t) ]
                                                          │
                                                          ▼
                                                [ Yaw Rate R_z(t) ]
                                                          │
                                         ┌────────────────┴────────────────┐
                                         ▼                                 ▼
                             [ Centred Differences ]           [ Simpson's 1/3 Rule ]
                                         │                                 │
                                         ▼                                 ▼
                                  Board-Jerk (BJ)                   Radicality (Ra)
```

---

## Part 4: Detailed Mathematical Formulations & Unit Mappings

### 1. Surfing Radicality Indicator ($Ra$)

#### The Physical Concept [5]:
A carve, bottom-turn, or top-turn maneuver is bounded in time by $t_0$ and $t_1$, which are physically defined as the zero-crossing points where the board's roll rate ($R_x$) crosses zero:
$$R_x(t_0) = R_x(t_1) = 0$$
The maneuver's intensity depends on the total yaw swept angle ($\theta_z$) and the elapsed duration ($t_1 - t_0$):
$$Ra = \frac{\theta_z^2}{t_1 - t_0} \quad [\text{radians}^2/\text{second}]$$
where the yaw swept angle is the definite integral of the yaw rate ($R_z$):
$$\theta_z = \int_{t_0}^{t_1} R_z(t) \, dt$$

#### The Kinematic Bridge to SWD Data:
SWD does not directly simulate transient maneuvers. It outputs a steady-state turning radius ($R$) as a function of trajectory speed ($V_t$) and roll angle ($\phi$). Using circular kinematics:
$$R_z(t) = \frac{V_t(t)}{R(t)}$$
Where $R(t)$ is predicted at every millisecond step by querying the ML surrogate with the simulated surfer's speed $V_t(t)$ and roll angle $\phi(t)$.

#### Unit Topics Applied:
*   **Topic 3.4 (Spline Interpolation):** Physical IMU or simulation paths are sampled at discrete times. The exact zero-crossing where $R_x(t) = 0$ will fall between samples [3.4.5]. We apply **PCHIP or Cubic Spline Interpolation** on our discrete $R_x(t)$ array to precisely identify the sub-millisecond timestamps of $t_0$ and $t_1$ rather than rounding to the nearest sample [174, 3.4.5].
*   **Topic 6.1 (Newton-Cotes Integration):** Once the yaw rate $R_z(t)$ is calculated, we apply **Composite Simpson’s 1/3 Rule** over the bound $[t_0, t_1]$ to compute the swept angle $\theta_z$ with a truncation error of $O(h^4)$ [130, 6.1.7].

---

### 2. Board-Jerk Performance Indicator ($BJ$)

#### The Physical Concept [9]:
Jerk represents the rate of change of linear acceleration ($j = \frac{da}{dt}$). Smoother board control minimizes sudden, jarring corrections. The total dimensionless board-jerk cost $J$ over a wave trajectory of duration $T$ is:
$$J = \int_{0}^{T} \frac{T^5}{D^2} \frac{j^2}{2} \, dt$$
where $D$ represents the total spatial trajectory length calculated by integrating the linear speed over the duration:
$$D = \int_{0}^{T} V(t) \, dt$$

#### Unit Topics Applied:
*   **Topic 7.1 (Finite Differences):** Calculating jerk ($j(t)$) requires taking the numerical derivative of the simulated linear acceleration. We implement a **second-order centred finite-difference stencil** for all interior points of our velocity array to find acceleration, and apply it a second time to find jerk [13, 7.1.4, 7.1.7]:
    $$a_i \approx \frac{V_{i+1} - V_{i-1}}{2h} \quad \text{and} \quad j_i \approx \frac{a_{i+1} - a_{i-1}}{2h}$$
*   **Topic 6.1 (Newton-Cotes Integration):** We compute the trajectory displacement $D$ by numerically integrating the speed $V(t)$ using the **Composite Trapezoidal Rule** (`scipy.integrate.cumulative_trapezoid` or `trapezoid`) [13, 6.1.1, 6.1.9]. We then evaluate the mean-square jerk cost integral using **Simpson’s 1/3 Rule** [6.1.7].

---

### 3. Machine Learning Surrogate Model (Topic 5)

To allow our simulation to run continuously, we train a regressor to act as an instant physical solver [176, 261].
*   **Features ($X$):** Trajectory speed ($V_t$ in m/s) and roll angle ($\phi$ in degrees).
*   **Target ($y$):** turning radius ($R$ in meters) and drag force ($F_{drag}$ in Newtons).
*   **Pipeline Design:** Scikit-learn pipeline wrapping `StandardScaler` and a **Support Vector Regressor (SVR)** with a **Radial Basis Function (RBF) kernel** [5.3.4, 5.3.11].
*   **Hyperparameter Tuning:** Systematically tune regularization ($C$), epsilon-insensitive tube ($\epsilon$), and kernel coefficient ($\gamma$) using cross-validation.
*   **Validation Split:** Withhold **20% of our SWD dataset** as an untouched test set, measuring performance using MAE, RMSE, and $R^2$ to assess generalisation capability [173, 175, 5.5.1].

---

## Part 5: Complete Implementation Architecture & Code Blueprint

The following codebase layout represents a professional, fully reproducible package structure that aligns with Week 1 standards and provides Claude Code with a clear target architecture:

### 1. Repository Directory Structure
```text
mma3001_performance_sim/
├── LICENSE
├── README.md
├── requirements.txt
├── setup.py
├── data/
│   └── swd_hydroscan_grid.csv
├── docs/
│   ├── index.html
│   └── code_documentation.pdf
├── src/
│   ├── __init__.py
│   ├── generator.py
│   ├── surrogate.py
│   ├── physics.py
│   └── main.py
└── tests/
    ├── __init__.py
    └── test_physics.py
```

### 2. Core Python Implementations

#### File: `src/physics.py`
This module handles the core numerical calculus required for Jerk and Radicality:

```python
"""
MMA3001 Surf Performance Physics Engine.

Contains highly optimized functions for numerical integration, finite differences,
and performance indicator calculations, aligned with Topic 6 and 7 concepts.
"""

import numpy as np
from scipy.interpolate import PchipInterpolator


def centred_difference_derivative(y_array: np.ndarray, h: float) -> np.ndarray:
    """
    Calculate the first derivative using a second-order centred difference stencil.
    
    Uses forward/backward differences for boundary points to maintain array size.
    
    Parameters:
        y_array (np.ndarray): The target array to differentiate.
        h (float): The step size (spacing) between samples in seconds.
        
    Returns:
        np.ndarray: Differentiated array of identical shape.
    """
    if len(y_array) < 3:
        raise ValueError("Array length must be >= 3 for centred differences.")
    
    dy = np.zeros_like(y_array)
    # Centred differences for interior points
    dy[1:-1] = (y_array[2:] - y_array[:-2]) / (2.0 * h)
    
    # Boundary points (First-order forward and backward)
    dy[0] = (y_array[1] - y_array[0]) / h
    dy[-1] = (y_array[-1] - y_array[-2]) / h
    
    return dy


def simpsons_composite_rule(y_array: np.ndarray, h: float) -> float:
    """
    Evaluate the definite integral using Simpson's 1/3 composite rule.
    
    Assumes equally spaced samples. If the number of intervals is odd,
    applies the Trapezoidal rule to the final panel to maintain robustness.
    
    Parameters:
        y_array (np.ndarray): Array of integrand values evaluated at nodes.
        h (float): Spacing between nodes (step size).
        
    Returns:
        float: The evaluated definite integral.
    """
    n = len(y_array) - 1
    if n == 0:
        return 0.0
    
    integral = 0.0
    # Check if intervals are even; if odd, integrate last panel via trapezoid
    if n % 2 != 0:
        integral += 0.5 * h * (y_array[-1] + y_array[-2])
        y_slice = y_array[:-1]
        n_panels = n - 1
    else:
        y_slice = y_array
        n_panels = n
        
    if n_panels > 0:
        integral += (h / 3.0) * (
            y_slice[0] + 
            y_slice[-1] + 
            4.0 * np.sum(y_slice[1:-1:2]) + 
            2.0 * np.sum(y_slice[2:-2:2])
        )
        
    return float(integral)


def find_maneuver_bounds(time_array: np.ndarray, rx_array: np.ndarray) -> tuple[float, float]:
    """
    Identify precise zero-crossing timestamps for roll rate (Rx) using PCHIP interpolation.
    
    Parameters:
        time_array (np.ndarray): 1D array of timestamps.
        rx_array (np.ndarray): 1D array of roll rates.
        
    Returns:
        tuple[float, float]: Precise timestamps (t0, t1) of the zero crossings.
    """
    # Fit shape-preserving PCHIP spline to avoid unphysical overshoots
    pchip = PchipInterpolator(time_array, rx_array)
    
    # Find indices where sign changes
    zero_cross_indices = np.where(np.diff(np.sign(rx_array)))[0]
    
    if len(zero_cross_indices) < 2:
        # Fallback default if not enough crossings found
        return float(time_array[0]), float(time_array[-1])
    
    # Interpolate exact roots
    crossings = []
    for idx in zero_cross_indices[:2]:
        t_left = time_array[idx]
        t_right = time_array[idx + 1]
        # Run simple bisection root-finding on the spline
        for _ in range(10):
            t_mid = 0.5 * (t_left + t_right)
            if np.sign(pchip(t_left)) == np.sign(pchip(t_mid)):
                t_left = t_mid
            else:
                t_right = t_mid
        crossings.append(0.5 * (t_left + t_right))
        
    return crossings[0], crossings[1]


def calculate_board_jerk(time_array: np.ndarray, velocity_array: np.ndarray) -> float:
    """
    Evaluate the normalized, dimensionless board-jerk cost (J).
    
    Parameters:
        time_array (np.ndarray): Array of timestamps in seconds.
        velocity_array (np.ndarray): Speed trace array.
        
    Returns:
        float: Dimensionless Jerk Cost index.
    """
    h = float(time_array[1] - time_array[0])
    T = float(time_array[-1] - time_array[0])
    
    # Calculate acceleration and jerk using centred differences
    accel = centred_difference_derivative(velocity_array, h)
    jerk = centred_difference_derivative(accel, h)
    
    # Calculate trajectory length D using Simpson's integration
    D = simpsons_composite_rule(velocity_array, h)
    
    if D == 0:
        return 0.0
        
    # Evaluate Jerk cost integral
    integrand = (jerk ** 2) / 2.0
    jerk_integral = simpsons_composite_rule(integrand, h)
    
    # Normalisation coefficient
    normalization = (T ** 5) / (D ** 2)
    
    return float(normalization * jerk_integral)


def calculate_radicality(time_array: np.ndarray, rz_array: np.ndarray, t0: float, t1: float) -> float:
    """
    Calculate the Surfing Radicality indicator (Ra) across a maneuver.
    
    Parameters:
        time_array (np.ndarray): Timestamps array.
        rz_array (np.ndarray): Calculated yaw rate array.
        t0 (float): Start time of turn.
        t1 (float): End time of turn.
        
    Returns:
        float: Radicality indicator value.
    """
    h = float(time_array[1] - time_array[0])
    
    # Mask arrays within the maneuver boundaries
    maneuver_mask = (time_array >= t0) & (time_array <= t1)
    rz_maneuver = rz_array[maneuver_mask]
    
    # Integrate yaw rate to find swept angle
    swept_angle = simpsons_composite_rule(rz_maneuver, h)
    duration = t1 - t0
    
    if duration == 0:
        return 0.0
        
    return float((swept_angle ** 2) / duration)
```

---

## Part 6: Profiling, Optimization, & Code Credibility

### 1. Estimating Arithmetic Intensity (AI)
To satisfy Week 2 and Section 6 project requirements, we must estimate our code's computational efficiency [187, 214].

#### Example: Arithmetic Intensity of the Centred Difference Function
*   **Operations (FLOPS):**
    For an array of size $N$, interior points calculate: `(y[2:] - y[:-2]) / (2.0 * h)`
    This equals 1 subtraction and 1 division per point.
    $$\text{Total FLOPS} = 2 \times (N-2) \approx 2N \text{ FLOPS}$$
*   **Memory Access (Bytes):**
    Each float is stored in 64-bit precision (8 bytes). For each element, we load `y_array` values and store `dy` values.
    $$\text{Reads} = 8N \text{ Bytes}, \quad \text{Writes} = 8N \text{ Bytes} \implies \text{Total Memory} = 16N \text{ Bytes}$$
*   **Arithmetic Intensity ($I$):**
    $$I = \frac{\text{Compute FLOPS}}{\text{Memory Bytes}} = \frac{2N}{16N} = 0.125 \quad [\text{FLOP/Byte}]$$
    This low ratio indicates that the centred difference function is heavily **memory-bandwidth bound** [198]. Inform Claude Code to prioritize vectorised NumPy operations over slow Python `for` loops to maximize caching efficiency.

### 2. Automated Testing Suite (`tests/test_physics.py`)
To fulfill validation criteria, we write tests evaluating our numerical code on controlled analytical equations [219]:

```python
"""
MMA3001 Testing Suite - Calculus Verification.
"""

import numpy as np
import pytest
from src.physics import centred_difference_derivative, simpsons_composite_rule


def test_centred_difference_sine_wave():
    """
    Verify centred differences on a pure sine wave where analytical derivative is known.
    """
    t = np.linspace(0, 2 * np.pi, 1000)
    h = t[1] - t[0]
    y = np.sin(t)
    
    # Analytical derivative: cos(t)
    expected = np.cos(t)
    actual = centred_difference_derivative(y, h)
    
    # Ignore boundary points due to lower-order fallbacks
    np.testing.assert_allclose(actual[1:-1], expected[1:-1], rtol=1e-4, atol=1e-4)


def test_simpsons_integration_polynomial():
    """
    Verify Simpson's composite rule integrates a cubic polynomial exactly.
    """
    x = np.linspace(0, 3, 101)  # Even intervals
    h = x[1] - x[0]
    y = x ** 3
    
    # Analytical integral of x^3 from 0 to 3 is (3^4)/4 = 20.25
    expected = 20.25
    actual = simpsons_composite_rule(y, h)
    
    assert pytest.approx(actual, rel=1e-6) == expected
```

---

## Part 7: Prompt Directives for Claude Code Execution

When executing this project, Claude Code must adhere to these instruction gates:

1.  **Strict Source Grounding:** All mathematical equations, Course Learning Outcomes, and assessment structures must be verified against this specification sheet. Do not fabricate course policies or grading milestones [180].
2.  **Clean Repository Assembly:** Initialize the project directories exactly as described. Create all python modules with complete, valid code. Do not write placeholders or partial scripts [225].
3.  **Strict Variable Definitions:** All functions must follow NumPy style docstring guides [227]. Detail variable names, types, dimensions, and supported domains explicitly to avoid ambiguity [209].
4.  **Enforce Code Usability:** Run `pytest` locally to confirm all calculus algorithms compile and execute correctly on the analytical waveforms [219].
5.  **Produce the HTML API Documentation:** Ensure that the final repository contains a working generation command for `pdoc` or `Sphinx` to produce high-quality web-ready code interfaces [219, 227].
