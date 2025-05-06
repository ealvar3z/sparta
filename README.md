### sparta (barebones tiling wm)

A very lean and spartan tiling wm that does one thing: put pixels on the screen. 

Inspiration came from:

    - jorisvink/coma
    - tinywm
    - wmii

Use at your own peril; PRs are welcome!

### Dependencies

1. **luajit** - the runtime
1. **shxkd**  - keybinding demon (cough ... daemon)

*(Only these two. No C compiling, no toolchains.)*

### Installation

```shell
git clone
cd sparta
make install    #  see Makefile for PREFIX changes
```

### Usage

- write an .xinitrc
- startx it

### Configuration

```sh
man sxhkd
/CONFIGURATION
```

### Contributing

sparta is minimal by design. Therefore:

- keep patches < 50 sloc
- no new dependencies
- honor the spartan ethos


