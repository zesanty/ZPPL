# ZPPL

Final project for my Intro to Probablistic Programming @ UBA

It's a port of both FOPPL and HOPPL features that were seen during the course.
## Features

- Supports higher-order functions, recursion, dynamic control flow, closures, and user-defined functions.
- **Inference Engines**:
  - **Likelihood Weighting (LW)**: Evaluates programs to yield weighted sample-value pairs.
  - **Sequential Monte Carlo (SMC)**: Simulates state evolution using particles (defaulting to 1,000 particles) with resampling.
  - **Metropolis-Hastings (MH)**: Leverages Markov Chain Monte Carlo (MCMC) to generate a trace of correlated samples (defaulting to 20,000 steps with a 1,000-step warmup).
- Includes a small terminal raw-mode implementation supporting line editing, signal handling, and command history navigation.

# Requirements

- Zig 0.16.X

# Build

## Build the program
```
zig build
```


## Run REPL enviroment
```
zig build run
```
## Run tests
```
zig build test --summary all
```

# Usage
```
./zig-out/bin/ZPPL <path-to-file> [options]
```
--lw : Execute using Likelihood Weighting (displays the value and its corresponding log-weight).

--smc : Execute using Sequential Monte Carlo (displays sample statistics and empirical posterior mean).

--mh : Execute using Metropolis-Hastings (default) (displays sample statistics and empirical posterior mean).

--seed <seed> or -s <seed> : Set a custom integer seed for the random number generator.

If you run the program without a file path argument, it starts an interactive session.
