import numpy as np
import pandas as pd
from pathlib import Path

# Conditions for Blasius
INITIAL_f = 0.0
INITIAL_df = 0.0
FINAL_df = 1.0
ETA_0 = 0.0
ETA_MAX = 10.0
GUESS_ddf = 0.0
GUESS2_ddf = 5.0
# Limit: at s = GUESS2_ddf = 5, f grows as about 6.1 eta, and RK4's real stability bound h f/2 <= 2.785 is crossed
#        once eta_max >~ 22 or h >~ 0.17; F is then not finite and the secant stops. The runs use eta_max 10 and 20
#        at h = 0.1/sqrt(2) (SQA round 2, 2026-10-28; the author kept the guess, AI-USE.md section 4)

# Constants
CONSTANT_K = np.sqrt(2)
CONSTANT_C = np.sqrt(2)

# Step size
STEP_SIZE = 0.1/CONSTANT_C
ETA_ARRAY = np.arange(ETA_0, ETA_MAX, float(STEP_SIZE))

# Blasius ODE initial condition
def blasius_rhs(eta, blasius):
    '''Input is the scaled submerge distance and the Blasius vector as numpy array 1x3
    Output is the scaled Blasius vector

    Returns d/dn where n is the scaled submerge distance,
    Return is in the form of [dF, ddF, and dddF], and dimensionless'''

    # Input is the scaled submerge distance and the Blasius vector as numpy array 1x3
    # Output is the scaled Blasius vector
    # Blasius is as:
    # [F, dF, ddF] where:
    # F is the scaled stream function
    # dF is u/U, i.e., velocity along the board as a fraction of the free-stream speed
    # ddf is the scaled velocity gradient function - i.e., shear
    f = blasius[0]
    df = blasius[1]
    ddf = blasius[2]

    return np.array([
        df,
        ddf,
        -(1/2)*f*ddf
    ])


# extracting data from csv
white_blasius_pd = pd.read_csv(Path(__file__).with_name('blasius_table_white_majdalani_4e.csv'), comment='#')
white_blasius = np.asarray(white_blasius_pd)
white_eta = white_blasius[:, 0]*CONSTANT_C
white_f = white_blasius[:, 2]*CONSTANT_K
white_df = white_blasius[:, 3]*CONSTANT_K/CONSTANT_C
white_ddf = white_blasius[:, 4]*CONSTANT_K/CONSTANT_C**2
white_dddf = white_blasius[:, 5]*CONSTANT_K/CONSTANT_C**3

# Input checks: the author's decision (AI-USE.md section 4, 2026-10-28), after the agy review
def _real_scalar(name, value):
    '''value as a float, or ValueError unless it is one finite real number (a bool would pass as 0 or 1)'''
    if isinstance(value, (bool, np.bool_)) or np.ndim(value) != 0 or np.asarray(value).dtype.kind not in "iuf":
        raise ValueError(f"{name} must be a single finite number (a bool is not)")
    value = float(value)
    if not np.isfinite(value):
        raise ValueError(f"{name} must be a single finite number (a bool is not)")
    return value


def exact_blasius(eta):
    '''Exact Blasius solution extracted from White & Majdalani Table 4-3.
    Raises ValueError if eta is not one finite number, or is not in the table'''
    # A NaN eta made every distance NaN, so the check below passed and argmin returned row 0
    eta = _real_scalar("eta", eta)

    # Finding value within table through conversion
    distances = np.abs(white_eta - eta)
    if np.min(distances) > STEP_SIZE:
        raise ValueError("Submerge scaled is not in the table")
    index = np.argmin(distances)

    return white_f[index], white_df[index], white_ddf[index], white_dddf[index]

#RK4 from MMA3001 notebook 7.4
def rk4_solve(rhs, initial, eta_array, step_size, first_k1=None):
    '''Fixed-step RK4 for y' = rhs(eta, y) from initial over eta_array.
    Returns the state at every point of eta_array, shape (len(eta_array), len(initial))
    first_k1, if given, is rhs(eta_array[0], initial), already worked out by the caller; it is used as the first
    step's k1 instead of calling rhs again, which gives the same result'''
    BLASIUS_RK4 = np.zeros((len(eta_array), len(initial)))
    BLASIUS_RK4[0] = np.array(initial)

    # RK4 loop
    for i in range(len(eta_array)-1):
        eta = eta_array[i]
        k1 = first_k1 if i == 0 and first_k1 is not None else rhs(eta, BLASIUS_RK4[i])
        BLASIUS_trial_2 = BLASIUS_RK4[i] + 0.5*step_size*k1
        k2 = rhs(eta+0.5*step_size, BLASIUS_trial_2)
        BLASIUS_trial_3 = BLASIUS_RK4[i] + 0.5*step_size*k2
        k3 = rhs(eta+0.5*step_size, BLASIUS_trial_3)
        BLASIUS_trial_4 = BLASIUS_RK4[i] + step_size*k3
        k4 = rhs(eta+step_size, BLASIUS_trial_4)
        WEIGHTED_RATE = (k1+2*k2+2*k3+k4)/6


        blasius_rk4_next = BLASIUS_RK4[i]+step_size*WEIGHTED_RATE
        BLASIUS_RK4[i+1] = blasius_rk4_next
    return BLASIUS_RK4

# Shooting method
def F(s, eta_array=ETA_ARRAY, step_size=STEP_SIZE):
    BLASIUS_RK4 = rk4_solve(blasius_rhs, [INITIAL_f, INITIAL_df, s], eta_array, step_size)
    return BLASIUS_RK4[-1][1]-FINAL_df

# Secant method tolerance & max iterations
TOLERANCE = 1e-6
MAX_ITERATIONS = 1000

# Secant around shooting to improve guess s - adapted from ENG1014
def secant_for_shooting(f, s_old, s_init, max_iter=MAX_ITERATIONS, precision=TOLERANCE):
    """
    Finds a root of the function f(x) using the secant method.

    Args:
        f: Shooting function to be reiterated
        s_init: Initial guess for the root
        s_old: Previous initial guess
        max_iter: Most secant steps taken, an integer >= 1
        precision: Stopping criteria determined by the user, > 0

    Returns:
        s_new: Root of the function f(x)
        num_iter: Number of iterations taken to find the root

    Raises:
        ValueError: if a guess or precision is not one finite number, precision <= 0, max_iter is not an integer
            >= 1, F is not finite at a guess (RK4 diverged), the secant step would divide by zero or gives a
            non-positive f''(0), or max_iter iterations end without |F| < precision
    """
    s_old, s_init = _real_scalar("s_old", s_old), _real_scalar("s_init", s_init)
    # precision <= 0 could never be met, and max_iter < 1 would raise "did not reach" without a single step
    if _real_scalar("precision", precision) <= 0:
        raise ValueError(f"precision must be > 0, got {precision!r}")
    if isinstance(max_iter, (bool, np.bool_)) or not isinstance(max_iter, (int, np.integer)) or max_iter < 1:
        raise ValueError(f"max_iter must be an integer >= 1, got {max_iter!r}")
    f_old = f(s_old)
    if not np.isfinite(f_old):
        raise ValueError(f"F at the first guess s = {s_old} is not finite: RK4 diverged on this grid")
    f_init = f(s_init)
    if not np.isfinite(f_init):
        raise ValueError(f"F at the second guess s = {s_init} is not finite: RK4 diverged, past its stability limit "
                         "for this eta_max and h (see the GUESS2_ddf limit)")

    f_array = np.array([f_old, f_init])
    s_array = np.array([s_old, s_init])

    for k in range(max_iter):
        f_old, f_init = f_array[k], f_array[k+1]
        s_old, s_init = s_array[k], s_array[k+1]
        if np.abs(f_init-f_old) < np.finfo(float).eps:
            raise ValueError(f"F is the same at s = {s_old} and s = {s_init}, so the secant step would divide by "
                             "zero (equal guesses, or a flat F)")

        s_new = s_init - f_init*(s_init - s_old) / (f_init - f_old)  # estimate first guess of s_new

        if not np.isfinite(s_new) or s_new <= 0:
            raise ValueError(f"the secant step gave f''(0) = {s_new}, which is not finite and positive")

        f_new = f(s_new)
        s_array = np.append(s_array, s_new)
        f_array = np.append(f_array, f_new)

        if not np.isfinite(f_new):
            raise ValueError(f"F at the secant's guess s = {s_new} is not finite: RK4 diverged on this grid")

        if np.abs(f_new) < precision:
            return s_new, k+1, s_array, f_array

    # The author's choice (AI-USE.md section 4, 2026-10-28): an unconverged secant raises instead of returning
    raise ValueError(f"the secant did not reach |F| < {precision} in {max_iter} iterations "
                     f"(last |F| = {abs(f_array[-1])})")

# Adding the secant method to help find the next guess
if __name__ == "__main__":
    s_star, num_iter, s_history, f_history = secant_for_shooting(F, GUESS_ddf, GUESS2_ddf)
    print(f"Secant method found root at s = {s_star} in {num_iter} iterations, F(s*) = {f_history[-1]}")
    print(f"Check = {s_star - white_ddf[0]:.6f}")
