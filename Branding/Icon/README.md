# Helm app icon — Icon Composer source

Two flat, geometric icon options for Helm, built as layered vector art for Apple's
**Icon Composer** (Xcode 26): a **ship's wheel** ("helm") and a **sailboat** (a
sloop, matching the symbol used inside the app). Pick one. The shapes are plain
flat fills: Icon Composer applies the Liquid Glass material, specular highlights
and shadow itself, so do NOT bake gradients/glow/shadow into these files. Both
share the same `#0F3D5F` background and 1024×1024 canvas.

## Files
**Shared**
- `Layer1-Background.svg` — full-bleed `#0F3D5F` square (deep ocean blue). Or set
  this colour as Icon Composer's background fill instead (adapts per appearance).

**Ship's wheel**
- `Layer2-Spokes.svg` — the 8 white spokes + rounded handle tips (transparent bg).
- `Layer3-Rim-Hub.svg` — the white rim ring + centre hub (transparent bg).
- `Helm-Icon-Composite.svg` — flattened reference (masked square; not for import).

**Sailboat**
- `Sailboat-Layer2-Sails.svg` — the white mainsail + jib (transparent bg).
- `Sailboat-Layer3-Hull.svg` — the white hull (transparent bg).
- `Sailboat-Composite.svg` — flattened reference (masked square; not for import).

All files share a 1024×1024 canvas and are pre-aligned, so the layers stack
exactly when imported.

## Import into Icon Composer
1. New icon → 1024 canvas.
2. **Background:** either import `Layer1-Background.svg`, OR (better) skip it and
   set Icon Composer's background fill to `#0F3D5F` — a tool-set fill adapts across
   the Light / Dark / Tinted / Clear appearances; a baked square doesn't.
3. Add a layer and import `Layer2-Spokes.svg`.
4. Add a layer above it and import `Layer3-Rim-Hub.svg`.
5. The foreground is pure white, so it tints cleanly in Tinted / mono appearances.
   Nudge the two foreground layers' depth/shadow to taste, then toggle each
   appearance to check legibility.
6. Export the `.icon`.

## Notes / knobs
- Keeping spokes and rim+hub as **two** foreground layers gives Icon Composer a
  little depth/parallax between them. Merge into one layer if you prefer a single
  flat glass element.
- If Icon Composer (or your vector editor) renders the strokes oddly, "outline
  strokes" / expand them to filled paths first — the geometry is unchanged.
- Easy tweaks: spoke count (`Layer2` lines), stroke weights (`stroke-width`),
  wheel size (radii), background colour (`#0F3D5F`).
