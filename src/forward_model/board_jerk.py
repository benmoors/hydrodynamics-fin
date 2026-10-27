"""The jerk cost J of the forward model's run, Charles et al. (2026) Eq 4-7, from Step 1's a = dV/dt.

Named board_jerk for now, but it is the jerk cost alone, not the paper's whole Board-Jerk: the run is a straight glide
with no turns. It will be renamed. Nothing here is compared with the paper's values; that is later work.

The paper's equations (Charles et al. 2026, Results in Engineering 29:108868, p.6), cited, not claimed:

    j = da/dt                                                    (Eq 4)
    J = integral_0^T C j^2/2 dt                                  (Eq 5)
    C = T^5/D^2                                                  (Eq 6)
    D = sqrt(sum over x, y, z of (double integral_0^T a_i dt)^2) (Eq 7)

There is one axis here, the acceleration along the face, so Eq 7 is D = |integral_0^T integral_0^t a ds dt|. It is
taken literally: the double integral of a, with no starting speed, so V0 T is not in D (the author's D_a).
J is dimensionless: j^2 dt is in m^2 s^-5 and T^5/D^2 in s^5 m^-2.

The numerics are the author's choices (AI-USE.md section 4). j is np.gradient of a on t. Eq 7 is Simpson twice:
scipy's cumulative_simpson inside, composite Simpson outside. Eq 5 is composite Simpson, so the number of
intervals must be even (3 s at h = 0.001 s is 3000).

The author's exact cases, used by the tests. Derivation: Benjamin Moors (AI-USE.md section 4, 2026-10-27).
For linear acceleration a = a0 + beta t, so j = beta:

    D_b = V0 T + a0 T^2/2 + beta T^3/6,    D_a = |a0 T^2/2 + beta T^3/6|,    J_linear = beta^2 T^6/(2 D^2)

and for sinusoidal acceleration:

    D_b = V0 T + A T/omega,    D_a = |A T/omega|,    J_sinusoidal = A^2 omega^2 T^6/(4 D^2)

The sinusoid is a = A sin(omega t) with omega T = n pi. That is Claude Code's completion, confirmed by the author:
both of his sinusoid results need sin(omega T) = 0. With D_a, J_sinusoidal = (n pi)^4/4, whatever A and T.

Usage
-----
    >>> from src.forward_model import board_jerk as bj
    >>> from src.forward_model import forward_model as fm
    >>> t, V, a, complete = fm.simulate()      # the author's run: 20 -> 0 deg over 3 s from 6 m/s, h = 0.001 s
    >>> bj.jerk_cost(t, a, complete)           # J, dimensionless
    >>> bj.displacement(t, a)                  # D, m
"""

import numpy as np
from scipy.integrate import cumulative_simpson, simpson

from src.forward_model import forward_model as fm

# Limit: one axis, the acceleration along the face. No lateral or normal acceleration, no turns, no pitch.
# Limit: D is Eq 7 taken literally (D_a): it leaves out V0 T. On the author's run D_a = 2.657 m and J = 64.58; the
#        displacement V0 T + D_a = 20.657 m would give J = 1.068, 60 times smaller.
# Limit: np.gradient is second order inside and first order at the two end nodes.
# Limit: a comes from forces that are PCHIP in V and theta, which is C1, so j is continuous but its slope jumps at the
#        data's knots (each whole m/s, each 5 deg).
# Limit: T is the 3 s glide, not a wave from take-off to kick-out as in the paper, and J is not compared with the
#        paper's values.


def _samples(t, a):
    """t and a as float arrays, or ValueError unless they are one run sampled for composite Simpson."""
    t, a = np.asarray(t), np.asarray(a)
    # A bool would pass as 0 or 1, the same guard as forward_model.theta
    if t.dtype.kind not in "iuf" or a.dtype.kind not in "iuf":
        raise ValueError("t and a must be arrays of numbers (a bool is not)")
    t, a = t.astype(float), a.astype(float)
    if t.ndim != 1 or t.shape != a.shape:
        raise ValueError("t and a must be 1-D arrays of the same length")
    if len(t) < 3:
        raise ValueError("t and a need at least 3 samples")
    if not (np.all(np.isfinite(t)) and np.all(np.isfinite(a))):
        raise ValueError("t and a must be finite")
    if t[-1] - t[0] <= 0:
        raise ValueError("T = t[-1] - t[0] must be > 0")
    # T > 0 alone would let a t that doubles back through to np.gradient
    if np.any(np.diff(t) <= 0):
        raise ValueError("t must be strictly increasing")
    if (len(t) - 1) % 2:
        raise ValueError("Simpson needs an even number of intervals, so an odd number of samples")
    return t, a


def displacement(t, a):
    """D, Eq 7 along one axis: |integral_0^T integral_0^t a ds dt|, by Simpson twice.

    Parameters
    ----------
    t : array_like
        Time, s, finite and strictly increasing, with at least 3 samples and an even number of intervals.
        T = t[-1] - t[0] > 0. It need not start at 0.
    a : array_like
        Acceleration along the face at each t, m/s^2, finite, the same length as t.

    Returns
    -------
    float
        D, m, >= 0. It is 0 only when the double integral is.

    Raises
    ------
    ValueError
        If t or a is not numeric (a bool is not) or not 1-D, their lengths differ, there are fewer than 3 samples, a
        value is not finite, T <= 0, t is not strictly increasing, or the number of intervals is odd.

    Usage
    -----
        >>> displacement([0.0, 1.5, 3.0], [1.0, 0.25, -0.5])   # a = 1 - 0.5 t: 2.25 m
    """
    t, a = _samples(t, a)
    # The inner integral is the speed gained since t[0]; Eq 7 takes no starting speed, so V0 is not added
    gained = cumulative_simpson(a, x=t, initial=0.0)
    return abs(float(simpson(gained, x=t)))


def jerk_cost(t, a, complete):
    """J, Eq 4-6: the dimensionless jerk cost of one run.

    Parameters
    ----------
    t : array_like
        Time, s: as displacement. simulate() gives 0, 0.001, ..., 3 s.
    a : array_like
        Acceleration along the face, m/s^2: as displacement. simulate()'s a is E15 at each node.
    complete : bool
        simulate()'s flag. It must be True: J and C need the whole run from 0 to T.

    Returns
    -------
    float
        J, dimensionless, >= 0.

    Raises
    ------
    ValueError
        If complete is not True, if D = 0 (C = T^5/D^2 is undefined there), or for any reason displacement raises.

    Usage
    -----
        >>> t, V, a, complete = fm.simulate()
        >>> jerk_cost(t, a, complete)
    """
    # A run that left the force data stopped before T, so its J would be over a different T
    if not isinstance(complete, (bool, np.bool_)) or not complete:
        raise ValueError("complete must be True: J needs the whole run, and this one stopped before T")
    t, a = _samples(t, a)
    T, D = t[-1] - t[0], displacement(t, a)
    # trajectory.py set C = 1 here; the author's choice is to refuse
    if D == 0:
        raise ValueError("D = 0, so C = T^5/D^2 is undefined")
    j = np.gradient(a, t)
    return float(simpson(T**5/D**2*j**2/2, x=t))


if __name__ == "__main__":
    t, V, a, complete = fm.simulate()
    T, D = t[-1] - t[0], displacement(t, a)
    print(f"theta {fm.THETA_START} -> {fm.THETA_END} deg over {fm.T_RUN} s; V0 {fm.V0_RUN} m/s; h {fm.H} s; "
          f"complete: {complete}")
    print(f"T = {T:.6g} s, D = {D:.6g} m, C = {T**5/D**2:.6g} s^5/m^2, J = {jerk_cost(t, a, complete):.6g}")
