# bench/results

Raw measurement logs, one directory per day:

```
bench/results/<YYYY-MM-DD>/<benchmark>.txt
```

`<benchmark>` is the thing that was measured, not the command that measured it
— `p0a.txt` for a phase's before/after table, `boot.txt` for a
`hastur boot`, `ctfe.txt` for `bench/ctfe_latency.sh`. A file may hold several
scenarios of one benchmark; it must not mix benchmarks, because the point of
the layout is that two dates of the same name are directly comparable.

Every file starts with a header, so a number is never separated from the
machine that produced it (JIT.md 12):

```
commit:   <git rev-parse HEAD>
branch:   <git branch --show-current>
os:       <name and version>  <arch>
cpu:      <model>
nim:      <nim --version, first line>
cc:       <cc --version, first line>
mode:     <what was varied: --vfs:disk, -d:release, backend, …>
command:  <the exact command line>
runs:     <how many, and how they were reduced: median of 3, best of 5, …>
```

Then the numbers, as a table or as the tool's own output pasted verbatim.
Verbatim is preferred where the tool already prints something machine-readable
(`nifmake-report …`, `hastur boot`'s per-stage lines): a reduced number that
disagrees with a log is a number nobody can check.

Rules that keep the files worth keeping:

- **Say what you compared against.** A phase's file records the baseline and
  the new number side by side, both measured on the same machine in the same
  session — not the new number against a figure quoted from a previous day.
- **Say what else was running.** These are wall times on a developer machine;
  a build competing for cores can double them. If the machine was not quiet,
  the header says so and the conclusion leans on the ratio, not the absolute.
- **Three runs minimum** for anything under a second, reduced by median, with
  the raw runs kept in the file.
- **Never edit a past day's file.** A number that turns out to be wrong gets a
  correction in the current day's file naming the one it corrects.
