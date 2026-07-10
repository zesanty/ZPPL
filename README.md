# ZPPL

Final project for my Intro to Probablistic Programming @ UBA
It's a port of both FOPPL and HOPPL features that were seen during the course.

# Features 
+ micro-matrix/probability lib in zig
+ higher-order functions, recursion, dynamic control flow, closures, functions
+ REPL enviroment with *some* very hopeful safety.

# Requirements

- Zig 0.16.X
- Hope

# Build

## Build the program
```
zig build
```
## Run enviroment
```
zig build run
```
## Run tests
```
zig build test --summary all
```

# TODO
- lots of general cleanups code
- Implementing MH
- Implementing the runTrace 
- Maybe:
  + some optimization on comptime?
  + more distributions...
  + the parser could be more robust
