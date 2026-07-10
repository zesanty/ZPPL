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

You will find the binary in ```./zig-out/bin/ZPPL```:
 + Not passing any arguments will run the REPL enviroment

## Run REPL enviroment
```
zig build run
```
## Run tests
```
zig build test --summary all
```

# TODO
- lots of general cleanups code
    - some static polymorphism on machine.zig
    - lazy parser
- Maybe:
  + some optimization on comptime?
  + more distributions...
