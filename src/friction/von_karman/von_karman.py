"""Kármán momentum-integral boundary layer from the Majdalani-Xuan quartic.

The guessed profile is the Majdalani-Xuan quartic, u/U = g(xi) = (5 xi - 3 xi^3 + xi^4)/3 with xi = y/delta and
g = 1 beyond the edge xi = 1 (White and Majdalani 2022, Table 4-1, p.158). It closes the flat-plate momentum
integral C_f = 2 d(theta)/dx (Eq. 4-10), with theta = ALPHA*delta and wall shear mu*U*BETA/delta.

Derivation of ALPHA, BETA, delta, theta, C_f and avg C_f: Benjamin Moors, the author's own; checked by Claude Code.

delta, theta, C_f and avg_C_f are the closed form. march_delta is the numerical comparison: RK4 on
d(delta)/dx = nu*BETA/(U*ALPHA*delta), started from the closed form at x0 > 0.

Usage
-----
    >>> from src.friction.von_karman import von_karman as vk
    >>> nu = 0.00107/1025                          # SWD salt water, m^2/s
    >>> vk.delta(0.1, 2.0, nu)                     # m, at x = 0.1 m and U = 2 m/s
    >>> vk.avg_C_f(2.0*0.5/nu)                     # over L = 0.5 m
    >>> x, d = vk.march_delta(0.01, 0.5, 2.0, nu, 0.49/64)
"""

import numpy as np

from src.friction.blasius_shooting.shooting_blasius import rk4_solve
from src.friction.blasius_shooting.skin_and_shear import RE_MAX, _check  # the author's laminar range 0 < Re <= 1e6

# theta/delta = integral of g(1 - g) from 0 to 1, and the wall slope g'(0), both exact for the quartic
ALPHA = 379/2835
BETA = 5/3

# Limit: an approximation to Blasius, about 0.5 % high in C_f (Table 4-1); laminar layer only, below transition.
# Limit: zero pressure gradient, dU/dx = 0 (AI-USE.md section 4, 2026-10-22).


def profile(xi):
    """The Majdalani-Xuan quartic, u/U = (5 xi - 3 xi^3 + xi^4)/3 inside the layer and 1 beyond it.

    Parameters
    ----------
    xi : float or array_like
        y/delta, dimensionless, finite and >= 0.

    Returns
    -------
    float or numpy.ndarray
        u/U, the same shape as xi.

    Raises
    ------
    ValueError
        If xi is empty, not finite or negative.
    """
    xi = np.asarray(xi, dtype=float)
    if xi.size == 0 or not np.all(np.isfinite(xi) & (xi >= 0)):
        raise ValueError("xi must be finite and >= 0")
    # Beyond the edge the quartic is held at its edge value g(1) = (5 - 3 + 1)/3 = 1, exact in floating point;
    # clamping first also keeps xi**4 from overflowing far outside the layer
    xi = np.minimum(xi, 1.0)
    return (5*xi - 3*xi**3 + xi**4)/3


def _laminar(U, x, nu):
    """U, x and nu as float arrays, or ValueError unless each is finite and positive and U*x/nu <= RE_MAX."""
    U, x, nu = (_check(name, value) for name, value in (("U", U), ("x", x), ("nu", nu)))
    _check("Re_x = U*x/nu", U*x/nu, RE_MAX)
    return U, x, nu


def delta(x, U, nu):
    """Boundary-layer thickness of the quartic, delta = sqrt(2 nu BETA x/(U ALPHA)).

    From C_f/2 = d(theta)/dx with theta = ALPHA*delta and C_f/2 = nu*BETA/(U*delta), integrated from delta(0) = 0.

    Parameters
    ----------
    x : float or array_like
        Distance from the leading edge, m, > 0.
    U : float or array_like
        Free-stream speed, m/s, > 0.
    nu : float or array_like
        Kinematic viscosity, m^2/s, > 0.

    Returns
    -------
    float or numpy.ndarray
        delta, m, broadcast over the inputs.

    Raises
    ------
    ValueError
        If any input is empty, not finite or not positive, or U*x/nu is above RE_MAX.
    """
    U, x, nu = _laminar(U, x, nu)
    return np.sqrt(2*nu*BETA*x/(U*ALPHA))


def theta(x, U, nu):
    """Momentum thickness of the quartic, theta = ALPHA*delta.

    Parameters
    ----------
    x : float or array_like
        Distance from the leading edge, m, > 0.
    U : float or array_like
        Free-stream speed, m/s, > 0.
    nu : float or array_like
        Kinematic viscosity, m^2/s, > 0.

    Returns
    -------
    float or numpy.ndarray
        theta, m, broadcast over the inputs.

    Raises
    ------
    ValueError
        If any input is empty, not finite or not positive, or U*x/nu is above RE_MAX.
    """
    return ALPHA*delta(x, U, nu)


def C_f(Re_x):
    """Local skin-friction coefficient of the quartic, C_f = 2 BETA/sqrt(2 BETA/ALPHA)/sqrt(Re_x).

    Parameters
    ----------
    Re_x : float or array_like
        Local Reynolds number U*x/nu, dimensionless, finite, 0 < Re_x <= RE_MAX.

    Returns
    -------
    float or numpy.ndarray
        C_f = 2*shear_w/(rho*U**2), dimensionless, the same shape as Re_x.

    Raises
    ------
    ValueError
        If Re_x is empty, not finite or outside (0, RE_MAX].
    """
    Re_x = _check("Re_x", Re_x, RE_MAX)
    return 2*BETA/np.sqrt(2*BETA/ALPHA)/np.sqrt(Re_x)


def avg_C_f(Re_L):
    """Average skin-friction coefficient over the wetted length L, avg C_f = 4 BETA/sqrt(2 BETA/ALPHA)/sqrt(Re_L).

    The mean of C_f over 0 <= x <= L, equal to 2*C_f at x = L and to 2*theta(L)/L (Eq. 4-10).

    Parameters
    ----------
    Re_L : float or array_like
        Reynolds number on the wetted length, U*L/nu, dimensionless, finite, 0 < Re_L <= RE_MAX.

    Returns
    -------
    float or numpy.ndarray
        avg C_f, dimensionless, the same shape as Re_L.

    Raises
    ------
    ValueError
        If Re_L is empty, not finite or outside (0, RE_MAX].
    """
    Re_L = _check("Re_L", Re_L, RE_MAX)
    return 4*BETA/np.sqrt(2*BETA/ALPHA)/np.sqrt(Re_L)


def march_delta(x0, x_end, U, nu, h):
    """delta by RK4 on d(delta)/dx = nu*BETA/(U*ALPHA*delta), from x0 to x_end in steps of h.

    The ODE is singular at delta(0) = 0, so the march starts at x0 > 0, and its starting value delta(x0) is taken
    from the closed form, delta(). Only the march from x0 on is numerical.

    Parameters
    ----------
    x0 : float
        Start of the march, m, > 0.
    x_end : float
        End of the march, m, > x0, with U*x_end/nu <= RE_MAX.
    U : float
        Free-stream speed, m/s, > 0.
    nu : float
        Kinematic viscosity, m^2/s, > 0.
    h : float
        RK4 step, m, > 0. (x_end - x0)/h must be a whole number, so grids at h, h/2 and h/4 share their points.

    Returns
    -------
    x : numpy.ndarray
        The grid x0, x0 + h, ..., x_end, m.
    delta_rk4 : numpy.ndarray
        delta at each grid point, m.

    Raises
    ------
    ValueError
        If any input is not finite and positive, x_end <= x0, U*x_end/nu is above RE_MAX, or (x_end - x0)/h is not
        a whole number.
    """
    inputs = {"x0": x0, "x_end": x_end, "U": U, "nu": nu, "h": h}
    for name, value in inputs.items():
        if np.ndim(value) != 0:
            raise ValueError(f"{name} must be a scalar")
    x0, x_end, U, nu, h = (float(_check(name, value)) for name, value in inputs.items())
    if x_end <= x0:
        raise ValueError("x_end must be greater than x0")
    _laminar(U, x_end, nu)
    n = round((x_end - x0)/h)
    if n < 1 or abs(x0 + n*h - x_end) > 1e-12*x_end:
        raise ValueError("(x_end - x0)/h must be a whole number of steps")
    x = x0 + h*np.arange(n + 1)

    def rhs(x_now, state):
        """d(delta)/dx for the state [delta]; autonomous, so x_now is unused."""
        return np.array([nu*BETA/(U*ALPHA*state[0])])

    return x, rk4_solve(rhs, [float(delta(x0, U, nu))], x, h)[:, 0]
