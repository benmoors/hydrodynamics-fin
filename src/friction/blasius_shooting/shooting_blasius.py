import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
from scipy.integrate import solve_ivp
from pathlib import Path

# Conditions for Blasius
INITIAL_f = 0.0
INITIAL_df = 0.0
FINAL_df = 1.0
ETA_0 = 0.0
ETA_MAX = 10.0
GUESS_ddf = 0.0
GUESS2_ddf = 5.0

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

def exact_blasius(eta):
    '''Exact Blasius solution extracted from White & Majdalani Table 4-3.'''

    # Finding value within table through conversion
    distances = np.abs(white_eta - eta)
    if np.min(distances) > STEP_SIZE:
        raise ValueError("Submerge scaled is not in the table")
    index = np.argmin(distances)

    return white_f[index], white_df[index], white_ddf[index], white_dddf[index]

#RK4 from MMA3001 notebook 7.4
def rk4_solve(rhs, initial, eta_array, step_size):
    '''Fixed-step RK4 for y' = rhs(eta, y) from initial over eta_array.
    Returns the state at every point of eta_array, shape (len(eta_array), len(initial))'''
    BLASIUS_RK4 = np.zeros((len(eta_array), len(initial)))
    BLASIUS_RK4[0] = np.array(initial)

    # RK4 loop
    for i in range(len(eta_array)-1):
        eta = eta_array[i]
        k1 = rhs(eta, BLASIUS_RK4[i])
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
        precision: Stopping criteria determined by the user

    Returns:
        s_new: Root of the function f(x)
        num_iter: Number of iterations taken to find the root
    """
    f_old = f(s_old)
    if not np.isfinite(f_old):
        raise ValueError("Secant method failed to converge")
    f_init = f(s_init)
    if not np.isfinite(f_init):
        raise ValueError("Secant method failed to converge")

    f_array = np.array([f_old, f_init])
    s_array = np.array([s_old, s_init])

    for k in range(max_iter):
        f_old, f_init = f_array[k], f_array[k+1]
        s_old, s_init = s_array[k], s_array[k+1]
        if np.abs(f_init-f_old) < np.finfo(float).eps:
            raise ValueError("Secant method failed to converge")

        s_new = s_init - f_init*(s_init - s_old) / (f_init - f_old)  # estimate first guess of s_new

        if not np.isfinite(s_new) or s_new <= 0:
            raise ValueError("Secant method failed to converge")

        f_new = f(s_new)
        s_array = np.append(s_array, s_new)
        f_array = np.append(f_array, f_new)

        if not np.isfinite(f_new):
            raise ValueError("Secant method failed to converge")

        if np.abs(f_new) < precision:
            return s_new, k+1, s_array, f_array

    # return s_new as the root and iteration counter
    return s_new, k+1, s_array, f_array

# Adding the secant method to help find the next guess
if __name__ == "__main__":
    s_star, num_iter, s_history, f_history = secant_for_shooting(F, GUESS_ddf, GUESS2_ddf)
    print(f"Secant method found root at s = {s_star} in {num_iter} iterations, F(s*) = {f_history[-1]}")
    print(f"Check = {s_star - white_ddf[0]:.6f}")
