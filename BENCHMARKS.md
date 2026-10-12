# NIF benchmarks

`bench/bench.luau` times the package through its public modules: opening, decoding, reading
through one table, dumping, the array views, saving, the checker, the scene, the tree, the fixes,
and the multi-version reader, on the suite's two files (`all_types.nif`, every record type once,
16 KB; `random_objects.nif`, eight shapes, 233 KB) and on files built in the bench for what those
two don't hold: a grid of 4,096 vertices as strips, the same grid skinned to eight bones, and the
geometry an edit derives. A warm workload is warmed up, sized to a batch of about a tenth of a
second, and reported as the median of seven batches with a full collection between them. A
`cold:` workload is the median of seven fresh processes running `bench/cold.luau`, timed inside
the script from its first `require`: what a tool that runs once pays, most of it compiling the
modules it needs. Every call's answer is compared with one pinned in the file.

```sh
jess run --capability filesystem.read --capability process.spawn \
  --package jpk/nif --package-path jpk jpk/nif/bench/bench.luau [filter] [jess binary]
```

Without the binary (and `process.spawn`) the cold workloads are skipped.

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-12.
- Binary: the verified release build of Jess on l3i 2.0.1 (Luau 0.742), the same one for both
  sides.
- Base: `4bdc0f3`, the package before the move, with this bench. Head: `91e130d`.
- Protocol: the whole bench against an export of base, then of head, five times over, back to
  back under one lock; each cell is the median of its five runs. A difference under 5 percent is
  called no change. The run was made twice: with glibc's allocator as it comes, and with
  `MALLOC_TRIM_THRESHOLD_` and `MALLOC_MMAP_THRESHOLD_` at 1 GiB, so freed pages are kept (see the
  note on the save rows).

| Workload | Base | Head | Base / head | Base, pages kept | Head, pages kept | Base / head |
|---|---:|---:|---:|---:|---:|---:|
| all_types open | 12.38 µs | 13.83 µs | 0.89x | 12.43 µs | 12.87 µs | no change |
| all_types open + decode | 99.83 µs | 104.40 µs | no change | 98.25 µs | 99.74 µs | no change |
| all_types read into one table a type | 66.41 µs | 66.88 µs | no change | 66.22 µs | 63.34 µs | no change |
| all_types open + dump | 123.12 µs | 130.68 µs | 0.94x | 122.33 µs | 122.25 µs | no change |
| all_types get every element of 67 views | 66.88 µs | 69.15 µs | no change | 66.19 µs | 65.08 µs | no change |
| all_types toTable of 67 views | 25.89 µs | 22.80 µs | 1.14x | 26.83 µs | 21.59 µs | 1.24x |
| all_types open + save untouched | 27.48 µs | 30.27 µs | 0.91x | 28.39 µs | 28.32 µs | no change |
| all_types open + decode + save | 234.00 µs | 240.88 µs | no change | 235.73 µs | 229.85 µs | no change |
| all_types check | 9.17 µs | 9.68 µs | 0.95x | 9.43 µs | 9.05 µs | no change |
| all_types scene | 169.35 µs | 173.23 µs | no change | 170.06 µs | 167.80 µs | no change |
| all_types scene dump | 60.42 µs | 61.94 µs | no change | 61.47 µs | 59.95 µs | no change |
| all_types tree and type counts | 180.01 µs | 192.47 µs | 0.94x | 184.37 µs | 189.08 µs | no change |
| all_types open + fix + save | 131.38 µs | 140.16 µs | 0.94x | 132.92 µs | 132.20 µs | no change |
| all_types header | 0.81 µs | 0.83 µs | no change | 0.82 µs | 0.78 µs | no change |
| all_types cold: open + decode | 194.40 ms | 82.07 ms | 2.37x | 188.44 ms | 79.31 ms | 2.38x |
| all_types cold: read into one table a type | 190.06 ms | 122.76 ms | 1.55x | 186.72 ms | 118.78 ms | 1.57x |
| all_types cold: open + decode + save | 189.04 ms | 143.19 ms | 1.32x | 189.23 ms | 139.37 ms | 1.36x |
| all_types cold: check | 56.43 ms | 42.83 ms | 1.32x | 55.78 ms | 42.11 ms | 1.32x |
| all_types cold: scene | 170.09 ms | 79.41 ms | 2.14x | 164.37 ms | 78.30 ms | 2.10x |
| random_objects open | 3.11 µs | 3.22 µs | no change | 3.08 µs | 3.12 µs | no change |
| random_objects open + decode | 15.79 µs | 16.20 µs | no change | 16.01 µs | 15.92 µs | no change |
| random_objects read into one table a type | 8.96 µs | 9.50 µs | 0.94x | 8.76 µs | 9.33 µs | 0.94x |
| random_objects open + dump | 21.59 µs | 22.15 µs | no change | 21.06 µs | 22.15 µs | no change |
| random_objects get every element of 29 views | 1.21 ms | 1.18 ms | no change | 1.13 ms | 1.13 ms | no change |
| random_objects toTable of 29 views | 287.45 µs | 263.18 µs | 1.09x | 283.35 µs | 258.85 µs | 1.09x |
| random_objects open + save untouched | 34.33 µs | 75.60 µs | 0.45x | 33.76 µs | 35.40 µs | no change |
| random_objects open + decode + save | 66.55 µs | 109.36 µs | 0.61x | 64.47 µs | 69.06 µs | 0.93x |
| random_objects check | 259.81 µs | 106.26 µs | 2.44x | 259.50 µs | 100.85 µs | 2.57x |
| random_objects scene | 449.90 µs | 166.98 µs | 2.69x | 451.09 µs | 153.08 µs | 2.95x |
| random_objects scene dump | 37.98 µs | 38.48 µs | no change | 36.69 µs | 36.29 µs | no change |
| random_objects tree and type counts | 41.31 µs | 41.41 µs | no change | 39.57 µs | 42.71 µs | 0.93x |
| random_objects open + fix + save | 85.40 µs | 119.66 µs | 0.71x | 81.84 µs | 82.32 µs | no change |
| random_objects header | 0.83 µs | 0.86 µs | no change | 0.79 µs | 0.81 µs | no change |
| random_objects cold: open + decode | 66.37 ms | 25.37 ms | 2.62x | 64.18 ms | 25.36 ms | 2.53x |
| random_objects cold: read into one table a type | 78.99 ms | 33.36 ms | 2.37x | 77.49 ms | 32.78 ms | 2.36x |
| random_objects cold: open + decode + save | 65.81 ms | 31.32 ms | 2.10x | 64.82 ms | 31.06 ms | 2.09x |
| random_objects cold: check | 92.92 ms | 53.69 ms | 1.73x | 91.08 ms | 53.73 ms | 1.70x |
| random_objects cold: scene | 93.54 ms | 42.13 ms | 2.22x | 92.89 ms | 42.07 ms | 2.21x |
| random_objects cold: multi-version open | 72.50 ms | 32.54 ms | 2.23x | 71.16 ms | 31.71 ms | 2.24x |
| random_objects multi-version open | 23.31 µs | 24.79 µs | 0.94x | 22.58 µs | 23.76 µs | no change |
| random_objects multi-version open + read every list | 37.31 µs | 38.29 µs | no change | 34.77 µs | 36.40 µs | no change |
| random_objects multi-version tree | 42.91 µs | 44.73 µs | no change | 40.50 µs | 42.13 µs | no change |
| built strips check | 470.77 µs | 181.87 µs | 2.59x | 443.58 µs | 169.99 µs | 2.61x |
| built strips scene | 590.94 µs | 213.33 µs | 2.77x | 577.30 µs | 206.93 µs | 2.79x |
| built strips tree | 10.45 µs | 10.78 µs | no change | 10.07 µs | 10.59 µs | no change |
| built skin check | 425.90 µs | 116.94 µs | 3.64x | 408.57 µs | 111.64 µs | 3.66x |
| built skin scene | 534.35 µs | 279.31 µs | 1.91x | 507.87 µs | 271.33 µs | 1.87x |
| built skin fix | 164.76 µs | 53.35 µs | 3.09x | 154.36 µs | 51.49 µs | 3.00x |
| build a shape of 4096 vertices | 1.49 ms | 787.03 µs | 1.90x | 1.38 ms | 740.90 µs | 1.86x |
| random_objects update bounds | 277.84 µs | 241.82 µs | 1.15x | 265.37 µs | 237.67 µs | 1.12x |
| random_objects compute normals | 773.95 µs | 471.88 µs | 1.64x | 733.34 µs | 453.58 µs | 1.62x |

What moved, and why:

- **The checker and the scene on real geometry, 1.9x to 3.7x.** The checker called a closure for
  every triangle to count them and to find an index past the vertices; the scene read every
  index in a loop, filled missing vertex colors a float at a time, and grew its packed buffers by
  doubling, then trimmed them. Now a triangle list is counted from its length, and the range
  tests are one call each into l3i's data plane (`dream_data_Kind_u16:anyGe`, `maxGe` for skin
  weights, six bytes apart), which runs at about 1 ns an index against 3.5 ns for the loop.
  Strips still have to be walked for their degenerate triangles, but without a call for each,
  and are only looked at index by index when the data plane says one is out of range. The
  scene's five geometry buffers are made once, at their final size, from the runs noted while the
  graph was walked. `all_types.nif` has almost no geometry, so its rows don't move.
- **The fixes on a skin, 3x.** One data plane call a bone says whether any weight is past the
  shape; only a bone with one is listed weight by weight.
- **Building and editing, 1.1x to 1.9x.** An edit's triangles were a table for each triangle and
  its normals a table of vectors turned into an array a coordinate at a time; they are index
  triples in a buffer (a triangle list's own bytes) and floats written straight into the array.
  A bound's extremes come from six data plane calls (`min` and `max` of each coordinate, twelve
  bytes apart) and its radius from one square root, of the greatest squared distance, where
  there was one for each vertex. The rest of `update bounds` is opening and decoding the file.
- **A cold process, 1.3x to 2.6x.** Loading a module compiles all of it, so what a first use
  costs is what it makes load. The generated readers were split by the shard before this one
  (each record type's `fill`, and `write` and `links`, the structs, the class tables, the array
  kinds' methods: `1500117` to `77588ef`), which took `random_objects` cold `open + decode` from
  66 ms to 50 ms and `all_types`' from 198 ms to 101 ms. The rest, in order, each step the
  median of three alternated runs of the cold rows under the lock (`random_objects`, then
  `all_types`, cold `open + decode`):
  - the edit module is required by the first edit, not by `require '@nif'`: 50.2 to 46.2 ms,
    101.2 to 98.6 ms;
  - the hand-written custom codecs are five modules, each required by the first record that
    asks for one of its codecs: to 36.5 ms and 93.6 ms;
  - each record type's scanner is a module of its own, required the first time `open` meets
    the type: to 29.5 ms, and up to 97.5 ms (see below);
  - every string field is read through one function, `Text.field`. The readers used to intern
    where they read, and l3i compiles that lowering at every place it is written, about 0.75 ms
    a place: fifty readers with a name each paid it one by one. To 24.9 ms and 80.2 ms;
    `read into one table a type` went from 38.4 to 31.8 ms and from 152.3 to 121.3 ms.

  The multi-version reader's custom values are required a part at a time, which is the cold
  `check` and `multi-version open` rows: 35.0 to 31.3 ms for the open, 55.4 to 51.7 ms for the
  check, 49.0 to 41.0 ms for the check of `all_types`, which OpenMW refuses before any part is
  asked for.
- **`toTable`, 1.1x to 1.2x**, from the earlier shard (`9dd9d34`): an array's fields are read
  once, not for every element.

What it cost, on the warm rows that only open and decode:

- A scanner in a module of its own costs a warm `open` about 10 ns a record more than when the
  scanners were one module. `all_types open` is 0.89x in one run above and under the line in the
  other, and was 13.0 µs against 13.9 µs over seven alternated runs of it alone; `open` of
  `random_objects` alone in a loop is 3.0 µs on base and 3.3 µs on head. It is also a trade
  between files: a module costs about a fifth of a millisecond to load whatever its size, so
  `all_types.nif`, which holds 78 of the 112 types and is like no real mesh, pays about 6 ms more
  cold for its scanners than when they were one module, where `random_objects.nif`, with five
  types, pays 8 ms less.
- A string read through `Text.field` is a call where there was none: about 40 ns a string.
  `random_objects read into one table a type` is 0.94x in both runs for it (0.55 µs for the
  file's thirteen names), and the `all_types` rows that decode are up to 6 percent slower in the
  first run and within 3 percent in the second.

Both were kept because a process pays the compiling once, in milliseconds, and the call for
each record, in nanoseconds: a tool has to open some tens of thousands of files before the calls
add up to the compiling they save. Everything else warm did not move: microseconds of generated
straight-line `buffer.read*` and table construction, which the dialect lowers to the loops that
were already there. Rows of code no commit touched (`header`, `scene dump`, `get`) swung by up
to 5 percent between the two runs.

The dialect itself has a price at load that the warm rows don't show: the first comprehension,
reducer, or slice in a module adds 0.2 to 0.7 ms to compiling it (a record pattern adds
nothing). In the checker, the scene, the tree, the fixes, and the header that is paid once by
the tool that uses them, and they are written with it. In the three modules every
`require '@nif'` loads (`init.luau`, `writer.luau`, `custom_scan.luau`) it was 1.4 ms of a 17 ms
require for six constructs in code that runs once a save or once a load, and those are loops
again.

The three `random_objects` save rows read 0.45x to 0.71x with the allocator as it comes and
0.93x to 0.99x with freed pages kept, and are not slower code. Each call allocates the 233 KB
output buffer. glibc returns freed memory at the top of the heap to the kernel and faults it in
again on the next call when the freed buffers end up there, and doesn't when something long-lived
sits above them; which of the two a process gets depends on its allocation history, and loading
modules lazily changed that history. Head's samples of `open + save untouched` in the first run
were 37, 75, 77, 76, and 78 µs. Timed alone in a loop, alternating base and head three times,
`save` of an opened file is 28.9 to 29.5 µs on base and 29.2 to 30.3 µs on head, and
`open + decode + save` 62 to 71 µs on base and 59 to 62 µs on head.
