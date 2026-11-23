# scidrum

A self-contained performance drum machine for norns. The ZOIA Euroburo runs the
master clock and turns MIDI into CV for a Dreadbox Alecto. The nanoPAD2 (and an
optional 16x8 grid) plays everything.

Full manual: [scidrum-manual.pdf](scidrum-manual.pdf)

## What it does

- Two voices, 16 steps each, with separate lengths so they can run in different meters
- Per step: accent, chance of playing (probability), 1–4 repeats (ratchets) and a mod-lane value (p-lock) on CV 4
- Euclidean fills and rotation from the encoders
- 8 patterns that switch on the next bar, with copy and an undo for clear
- Live recording from the pads, rolls and mutes
- PERF moves you hold down: MIDI beat repeat, audio repeat, tape stop, half and double time, reverse, glitch, fill and DROP
- XY pad controls the ZOIA bitcrusher and decimator
- Follows the ZOIA's MIDI clock. Set tempo by tap (ZOIA button or pad 7) or with E1

## Install

From maiden:

```
;install https://github.com/Goosegoosegoosegoosegoose/scidrum
```

Or copy `scidrum.lua` to `dust/code/scidrum/` on norns.

## Hookup (short version)

| From | To |
|---|---|
| nanoPAD2 USB | norns USB |
| norns TRS MIDI out | ZOIA MIDI in |
| ZOIA MIDI out | norns TRS MIDI in (clock) |
| ZOIA CV out 1 / 2 | Alecto TRIG 1 / 2 |
| ZOIA CV out 3 | Alecto VELO 1 |
| ZOIA CV out 4 | Alecto TUNE 2 (mod lane) |
| Alecto voice 1 / 2 out | ZOIA audio in L / R |
| ZOIA audio out L / R | norns in L / R |

The manual walks through building the ZOIA patch one module at a time.

## Controls

| | |
|---|---|
| K2 | next pad mode: PLAY → STEP V1 → STEP V2 → PERF |
| K3 | run / stop |
| K1 + K2 | arm live recording |
| K1 + K3 | clear (press again to undo) |
| E1 | tempo request to ZOIA · K1: swing |
| E2 / E3 | depends on the mode (see manual) |

**Grid (optional):** rows 1–2 are steps, 3–4 per-step values, 5–6 lengths,
7 patterns and controls, 8 the PERF holds.

## MIDI map

| What | Ch | Number |
|---|---|---|
| Voice 1 trigger + velocity | 10 | note 60 |
| Voice 2 trigger | 11 | note 60 |
| Tap tempo | 15 | note 60 |
| Tempo / mod lane / LFO depth | 16 | CC 14 / 20 / 21 |
| Crush / decimate / delay send / LFO rate | 16 | CC 22 / 23 / 24 / 25 |

You can change all of these in PARAMS.

## Part of S.C.I.E.N.C.E.

The drums-only sibling of [S.C.I.E.N.C.E.](https://github.com/Goosegoosegoosegoosegoose/S.C.I.E.N.C.E.).
