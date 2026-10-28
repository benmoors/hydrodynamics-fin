import numpy as np
from scipy.integrate import cumulative_trapezoid

from src.friction.blasius_shooting.shooting_blasius import ETA_ARRAY, FINAL_df, INITIAL_df, INITIAL_f

# Grid: the RK4 grid itself, so h is STEP_SIZE and eta_max is where RK4 applies f'(eta_max) = 1
N = len(ETA_ARRAY) - 1
eta_max = ETA_ARRAY[-1]
h = eta_max/N

# Picard iterations: a fixed count, as this is a comparison
PICARD_ITERATIONS = 20


def thomas(a, b, c, d):
    """Solve a tridiagonal system with the Thomas algorithm (MMA3001 notes 2.3.6).

    Parameters
    ----------
    a : numpy.ndarray
        Sub-diagonal, length n. ``a[0]`` is never read.
    b : numpy.ndarray
        Main diagonal, length n.
    c : numpy.ndarray
        Super-diagonal, length n. ``c[-1]`` is read but never reaches the solution.
    d : numpy.ndarray
        Right-hand side, length n.

    Returns
    -------
    numpy.ndarray
        x such that ``a[i]*x[i-1] + b[i]*x[i] + c[i]*x[i+1] = d[i]`` for every row, length n.
    """
    n = len(b)
    c_prime = np.zeros(n)
    d_prime = np.zeros(n)
    c_prime[0] = c[0]/b[0]
    d_prime[0] = d[0]/b[0]

    # Forward sweep: eliminate the sub-diagonal
    for i in range(1, n):
        m = b[i] - a[i]*c_prime[i-1]
        c_prime[i] = c[i]/m
        d_prime[i] = (d[i] - a[i]*d_prime[i-1])/m

    # Back substitution
    x = np.zeros(n)
    x[-1] = d_prime[-1]
    for i in range(n-2, -1, -1):
        x[i] = d_prime[i] - c_prime[i]*x[i+1]
    return x


def blasius_fd(N=N, h=h, iterations=PICARD_ITERATIONS):
    """Central-difference solution of the Blasius equation for g = f', by Picard iteration.

    Solves g'' + 1/2 f g' = 0 on 0 <= eta <= N*h with g(0) = 0, g(eta_max) = 1 and f(0) = 0.
    Each iteration freezes f, solves a_i g_{i-1} + b_i g_i + c_i g_{i+1} = 0 at the interior
    points i = 1, ..., N-1 with

        a_i = 1 - 1/4 f_i h,    b_i = -2,    c_i = 1/4 f_i h + 1,

    then rebuilds f from g by the cumulative trapezoidal rule from f(0) = 0.

    Parameters
    ----------
    N : int, optional
        Number of steps; the grid has N + 1 points. Defaults to the RK4 grid's 141.
    h : float, optional
        Step size, eta_max/N. Defaults to the RK4 step, 0.1/sqrt(2). The domain is N*h, so to refine
        the grid on a fixed eta_max pass N and h together (e.g. ``blasius_fd(2*N, h/2)``); changing N
        alone changes eta_max.
    iterations : int, optional
        Number of Picard iterations. Defaults to 20.

    Returns
    -------
    g : numpy.ndarray
        u/U = f' at the N + 1 grid points, from the last iteration.
    f : numpy.ndarray
        The scaled stream function at the grid points, rebuilt from that g.
    ddf0 : numpy.ndarray
        f''(0) = g'(0) after each iteration, length ``iterations``, by the second-order
        one-sided difference (-3 g_0 + 4 g_1 - g_2)/(2h).

    Raises
    ------
    ValueError
        If N is not an integer >= 2, h is not a finite positive number, or iterations is not an integer >= 1.
    """
    # A bool is an int to Python, so it is refused by name
    if isinstance(N, bool) or not isinstance(N, (int, np.integer)) or N < 2:
        raise ValueError("N must be an integer >= 2: the f''(0) stencil needs g_0, g_1 and g_2")
    if (isinstance(h, bool) or not isinstance(h, (int, float, np.integer, np.floating))
            or not (np.isfinite(h) and h > 0)):
        raise ValueError("h must be a finite positive number")
    if isinstance(iterations, bool) or not isinstance(iterations, (int, np.integer)) or iterations < 1:
        raise ValueError("iterations must be an integer >= 1")
    f = np.zeros(N+1)  # Picard start: f = 0, so the first g is a straight line
    ddf0 = np.zeros(iterations)
    for k in range(iterations):
        # Central differences for g'' and g', multiplied through by h**2, with f frozen
        a = 1 - 1/4*f[1:N]*h
        b = -2*np.ones(N-1)
        c = 1/4*f[1:N]*h + 1

        # The known g_0 = g(0) and g_N = g(eta_max) move to the right-hand side
        d = np.zeros(N-1)
        d[0] -= a[0]*INITIAL_df
        d[-1] -= c[-1]*FINAL_df
        g = np.concatenate(([INITIAL_df], thomas(a, b, c, d), [FINAL_df]))

        # Rebuild f = integral of g from f(0) = 0
        f = INITIAL_f + cumulative_trapezoid(g, dx=h, initial=0)

        # f''(0) = g'(0)
        ddf0[k] = (-3*g[0] + 4*g[1] - g[2])/(2*h)
    return g, f, ddf0


if __name__ == "__main__":
    # Self-check: thomas agrees with a dense solve on a frozen-f system. The right-hand side is
    # non-zero in every row, so the forward sweep on d is exercised (the Blasius one is zero until the last row)
    f_test = np.linspace(0.0, 8.0, N+1)
    a = 1 - 1/4*f_test[1:N]*h
    b = -2*np.ones(N-1)
    c = 1/4*f_test[1:N]*h + 1
    d = np.linspace(-1.0, 1.0, N-1)
    A = np.diag(b) + np.diag(a[1:], -1) + np.diag(c[:-1], 1)
    assert np.allclose(thomas(a, b, c, d), np.linalg.solve(A, d), rtol=0, atol=1e-12)

    g, f, ddf0 = blasius_fd()
    print(f"Finite difference f''(0) = {ddf0[-1]} after {len(ddf0)} Picard iterations, "
          f"last change = {ddf0[-1] - ddf0[-2]:.1e}")
