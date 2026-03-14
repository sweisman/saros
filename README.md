# Saros - Solar Eclipse Calculator

Saros calculates the occurrence and geographic paths of solar eclipses. Given a range of years, it identifies new moons where a solar eclipse is geometrically possible, then computes the central line - the path traced on Earth's surface by the axis of the Moon's shadow.

The project is a refactored and extended version of a 2003 high school mathematics project by Sebastian Harl (Adam-Kraft-Gymnasium Schwabach), originally written as a monolithic Perl/Tk application. This version separates computation from presentation, adds several physical corrections, and supports multiple map projections and output formats.

## Principles

**Separation of concerns.** The astronomical computation engine has no knowledge of any user interface. It accepts parameters and returns data structures. The GUI and CLI are thin consumers of that engine. This makes the algorithms testable in isolation and allows new frontends (web, API, etc.) without touching the math.

**Correctness over performance.** The perturbation series are truncated (this is not JPL-grade ephemeris work), but within that scope, the code applies ΔT correction and WGS84 ellipsoidal Earth geometry by default, both of which were absent from the original. These are the two largest sources of systematic error in the original code.

**Configurability.** Map images, projections, geographic extents, and image regions are all parameterized rather than hardcoded. The code auto-detects what it can (image dimensions) and applies sensible defaults for the rest, reporting its assumptions so the user knows what to override.

**Fidelity to the original algorithm.** The core orbital mechanics - the trigonometric series for lunar and solar positions, the shadow cone geometry - are preserved from the original Facharbeit. The refactoring reorganizes and corrects but does not replace the underlying approach.

## Physical Model

### Coordinate Systems

All computation happens in **Earth-centered equatorial Cartesian coordinates** (x, y, z in kilometers). The Sun and Moon are positioned using ecliptic orbital elements (mean anomalies, elongations, node distances) computed as trigonometric series in time. These ecliptic coordinates are rotated into the equatorial frame using the obliquity of the ecliptic at the given epoch.

### Shadow Geometry

The Sun and Moon are modeled as spheres at known distances with known radii. The shadow is a pair of cones:

- **Umbra cone** - converges behind the Moon (total/annular eclipse on the ground)
- **Penumbra cone** - diverges behind the Moon (partial eclipse on the ground)

The central line is found by casting a ray from the Moon in the Sun-to-Moon direction and intersecting it with the Earth. The eclipse phase at each time step is determined by whether the shadow axis ray hits Earth's surface (central eclipse) or Earth falls within the penumbra cone (partial eclipse).

### Earth Model

Two models are available, selectable at runtime:

- **WGS84** (default) - The Earth is an oblate ellipsoid with equatorial radius 6378.137 km and polar radius 6356.752 km. The ray-ellipsoid intersection is a quadratic equation with the z-component scaled by (a/b)². Ground point latitude is geodetic (accounts for the tilt of the surface normal due to flattening), not geocentric. This shifts the central line by up to ~20 km at mid-latitudes compared to a sphere.

- **Sphere** - Mean radius 6371 km. Matches the original code's behavior. Faster, simpler, useful for comparison.

### ΔT Correction

The orbital element series are expressed in Terrestrial Time (TT), but the output needs to be in Universal Time (UT) for geographic coordinates to be correct. ΔT = TT - UT is a measured quantity that grows with time due to tidal deceleration of Earth's rotation. The code implements the Espenak & Meeus polynomial approximation covering -500 CE to 2150 CE. For historical eclipses, ΔT can be tens of minutes, shifting the central line by hundreds of kilometers. ΔT correction is on by default and can be disabled for comparison with the original code's output.

### Map Projections

Two projections are supported:

- **Mercator** - Conformal cylindrical projection. The default, matching the original code. Configurable geographic extent (west/east longitude, north/south latitude). Latitude is clamped at the configured bounds to avoid the polar singularity.

- **Azimuthal Equidistant** - All points are at their true distance and direction from the projection center. Configurable center point and angular radius. Centered on the North Pole with 180° radius, this produces the Gleason map layout. Centered on an eclipse's midpoint with a smaller radius, it gives a regional view with minimal distortion.

Both projections support an **image region** parameter - the pixel rectangle within the image that the map actually occupies. This handles map images with borders, titles, legends, or other non-map content.

## Project Structure

```
saros/
├── README.md
├── COPYING                     GNU GPL v3
├── saros-cli.pl                Command-line interface
├── saros-tk-ui.pl              Tk graphical interface
├── gleason-ae.jpg              Default azimuthal equidistant map background
├── lib/
│   └── Saros/
│       ├── Calendar.pm         Julian Day ↔ calendar date conversions
│       ├── Coordinates.pm      Sun/Moon positions, coordinate transforms
│       ├── DeltaT.pm           ΔT polynomial approximation
│       ├── Engine.pm           New moon finder, central line calculator
│       └── Projection.pm       Map projections with configurable extents
└── t/
    └── 01_engine.t             Test suite
```

### Module Responsibilities

**`Saros::Calendar`** - Converts between Julian Day Numbers and calendar dates (day, month, year, hour). Handles the Julian/Gregorian calendar reform at JD 2299161 (October 15, 1582). Also provides `chopdigits()`, which extracts the fractional part of a number (used throughout the orbital calculations).

**`Saros::DeltaT`** - Returns ΔT in seconds for a given decimal year using the Espenak & Meeus piecewise polynomial. Also provides `delta_t_centuries()` which converts to Julian centuries for direct addition to the time parameter used by the engine.

**`Saros::Coordinates`** - Computes Sun and Moon positions as 3D Cartesian vectors in the equatorial frame. Provides the ecliptic-to-equatorial rotation and the equatorial-to-geographic conversion (right ascension and declination to longitude and latitude via Greenwich Sidereal Time).

**`Saros::Engine`** - The main computation module. `find_new_moons()` scans a year range and returns all new moon dates with their ecliptic latitude β, flagging those where |β| < 1.58° as eclipse candidates. `has_central_line()` performs a fast check with 15-minute coarse steps, returning true as soon as a central phase is found — used to filter out partial-only eclipses without full computation. `calculate_central_line()` takes a candidate and steps through time in 5-minute increments, performing the full shadow geometry calculation at each step. Returns an array of points with phase, time, and geographic coordinates. `calculate_subsolar_track()` computes the subsolar point (where the Sun is directly overhead) for the duration of centrality. Contains the ray-ellipsoid intersection and geodetic latitude conversion.

**`Saros::Projection`** - Converts geographic coordinates (latitude, longitude) to pixel coordinates and back. Encapsulates the projection type, geographic extent, and image region. Both `project()` and `inverse()` are provided.

### Data Flow

```
User input (year range)
    │
    ▼
Saros::Engine::find_new_moons()
    │  iterates lunations, computes β for each
    │  applies ΔT correction (for display only; TT retained for computation)
    │  returns array of new moon records
    │
    ▼
Saros::Engine::has_central_line()
    │  fast filter: 15-min coarse steps, returns true on first central hit
    │  discards partial-only eclipses without full computation
    │
    ▼
Saros::Engine::calculate_central_line()
    │  for a selected candidate:
    │  steps through ±6 hours in 5-min increments
    │  at each step:
    │    Saros::Coordinates → Sun, Moon positions (3D vectors)
    │    shadow cone geometry → phase determination
    │    ray-Earth intersection → ground point
    │    equatorial → geographic coordinate conversion
    │  returns array of {time, phase, lon, lat} records
    │
    ▼
Saros::Engine::calculate_subsolar_track()  (optional)
    │  computes where the Sun is directly overhead during centrality
    │  returns array of {geo_lon, geo_lat} records
    │
    ▼
Output layer (CLI text, CLI image, or Tk GUI)
    │  Saros::Projection → pixel coordinates
    │  render to screen (Tk::Canvas) or file (GD)
```

## Running

### Prerequisites

Core Perl (5.10+) with `Math::Trig` and `POSIX` (both included in core). Optional modules:

| Module    | Required for                        | Arch Linux package |
|-----------|-------------------------------------|--------------------|
| `Tk`      | GUI (`saros-tk-ui.pl`)              | `perl-tk`          |
| `Tk::JPEG`| Loading JPEG map backgrounds in GUI | included in `perl-tk` |
| `GD`      | Image export (CLI `--map`, GUI)     | `perl-gd`          |

The CLI produces text output with no optional dependencies. Image output requires `GD`.

On Arch Linux:

```bash
sudo pacman -S perl-tk perl-gd
```

### Command-Line Interface

```bash
# Basic: find eclipses and print central line coordinates
perl saros-cli.pl --from 2024 --to 2026

# Generate a map image using a background map
perl saros-cli.pl --from 2024 --to 2026 \
  --map eclipses.png \
  --map-bg /path/to/world_mercator.jpg

# Custom extent - map image covers only Europe
perl saros-cli.pl --from 2024 --to 2030 \
  --map europe.png \
  --map-bg europe.jpg \
  --extent-west -25 --extent-east 45 \
  --extent-north 72 --extent-south 34

# Map image has a 40px border on all sides
perl saros-cli.pl --from 2024 --to 2024 \
  --map out.png --map-bg bordered_map.jpg \
  --image-x 40 --image-y 40 \
  --image-w 720 --image-h 520

# Azimuthal equidistant (Gleason), full globe, no background
perl saros-cli.pl --from 2020 --to 2030 \
  --map gleason.png \
  --projection azimuthal_equidistant \
  --width 800 --height 800

# Northern hemisphere only
perl saros-cli.pl --from 2024 --to 2026 \
  --map north.png \
  --projection azimuthal_equidistant \
  --extent-radius 90

# Spherical Earth, no ΔT (matches original saros.pl behavior)
perl saros-cli.pl --from 2024 --to 2024 --sphere --no-delta-t

# Compare WGS84 vs sphere
perl saros-cli.pl --from 2024 --to 2024 > wgs84.txt
perl saros-cli.pl --from 2024 --to 2024 --sphere > sphere.txt
diff wgs84.txt sphere.txt
```

#### CLI Options Reference

| Option | Description | Default |
|--------|-------------|---------|
| `--from YEAR` | Start year (required) | - |
| `--to YEAR` | End year (required) | - |
| `--no-delta-t` | Disable ΔT correction | ΔT on |
| `--sphere` | Use spherical Earth model | WGS84 |
| `--map FILE` | Output image path (enables image generation) | - |
| `--map-bg FILE` | Background JPEG for the map | - |
| `--map-fmt png\|jpg` | Output image format | `png` |
| `--width N` | Canvas width when no `--map-bg` | 800 (merc) / 600 (az) |
| `--height N` | Canvas height when no `--map-bg` | 400 (merc) / 600 (az) |
| `--projection TYPE` | `mercator` or `azimuthal_equidistant` | `mercator` (CLI) |
| `--extent-west DEG` | Western longitude bound | -180 |
| `--extent-east DEG` | Eastern longitude bound | 180 |
| `--extent-north DEG` | Northern latitude bound | 80 |
| `--extent-south DEG` | Southern latitude bound | -80 |
| `--center-lat DEG` | Azimuthal projection center latitude | 90 |
| `--center-lon DEG` | Azimuthal projection center longitude | 0 |
| `--extent-radius DEG` | Azimuthal angular radius | 180 |
| `--image-x N` | Left pixel of map region within image | 0 |
| `--image-y N` | Top pixel of map region within image | 0 |
| `--image-w N` | Pixel width of map region | image width |
| `--image-h N` | Pixel height of map region | image height |

When `--map-bg` is provided, image dimensions are read from the file. When it is not provided, `--width` and `--height` set the canvas size. When extent options are omitted, the program assumes the image covers the full default geographic range and reports this assumption in its output.

### Graphical Interface

```bash
perl saros-tk-ui.pl
```

The GUI launches maximized in azimuthal equidistant projection (Gleason map) by default and auto-calculates eclipses for the current year and next year on startup. Only eclipses with a central line (total or annular) are listed; partial-only eclipses are filtered out.

- **Top bar** - Year range input, Calculate button, ΔT checkbox, Earth model selector, Sun path toggle.
- **Left panel** - Scrollable checkbox list of central eclipses, each with a numbered color swatch. Check individual eclipses or use All/None buttons to plot paths on the map. Central lines are computed on demand when an eclipse is first checked.
- **Map area** - Displays the selected map projection with eclipse paths overlaid. Paths are drawn with black outlines and vivid neon colors that cycle through a 12-color palette. Numbered badges appear at the start of each path, drawn in a final pass so they are never obscured by overlapping paths. The AE map renders at full native resolution with scrollbars; the Mercator map scales to fit the viewport on window resize.
- **Sun path overlay** - When enabled, shows the subsolar track (where the Sun is directly overhead) during the period of centrality as a dashed line in the same color as the eclipse path.
- **Status bar** - Current operation feedback.
- **File menu** - Save Map Image as JPEG or PNG (requires `GD`; saves at full native resolution regardless of display scale), Save Eclipse List as numbered text file matching the image.
- **Settings menu** - Projection type (Mercator / Azimuthal Equidistant), Map Extent dialog for configuring geographic bounds, projection center, angular radius, and per-projection image regions.

A Gleason azimuthal equidistant map (`gleason-ae.jpg`) is included as the default AE background, pre-calibrated with image region and center values.

Map background images can be overridden via environment variables:

```bash
export SAROS_WORLDMAP=/path/to/mercator_map.jpg
export SAROS_AZMAP=/path/to/azimuthal_map.jpg
perl saros-tk-ui.pl
```

### Tests

```bash
prove -v t/
```

The test suite validates module loading, calendar round-trips, ΔT plausibility, and eclipse detection against known events (e.g., the April 8, 2024 total solar eclipse).

## Known Limitations

- **Truncated perturbation series.** Positional accuracy is roughly ±2 minutes in time and ±20-50 km in path position. This is adequate for visualization but not for precise local predictions. For sub-kilometer accuracy, use JPL ephemerides (DE440) with Besselian element methods.

- **No topographic correction.** The Earth model is a smooth ellipsoid (or sphere). Surface elevation affects contact times for a specific observer but not the central line position at map scale.

- **ΔT extrapolation.** Beyond 2050, ΔT values are extrapolated and increasingly uncertain. For far-future eclipses the time error grows.

- **Mercator latitude default.** The default Mercator extent clips at ±80° latitude. If your map image extends further, specify `--extent-north` and `--extent-south` explicitly. The program cannot infer geographic bounds from a JPEG.

- **Single-threaded.** Scanning large year ranges (thousands of years) is sequential. The 5-minute time step in `calculate_central_line` could be adaptive for speed, but isn't.

## License

The original Saros was released under the GNU General Public License v2 by Sebastian Harl. This version is licensed under the GNU General Public License v3. See `COPYING` for the full text.

## References

- Espenak, F. & Meeus, J. - *Five Millennium Canon of Solar Eclipses: -1999 to +3000*. NASA/TP-2006-214141.
- Espenak, F. & Meeus, J. - [Polynomial Expressions for Delta T](https://eclipse.gsfc.nasa.gov/SEhelp/deltatpoly2004.html).
- Harl, S. - *Saros: Berechnung von Sonnenfinsternissen* (Facharbeit, Adam-Kraft-Gymnasium Schwabach, 2003).
- [NASA Five Millennium Eclipse Catalog](https://eclipse.gsfc.nasa.gov/SEcat5/SEcatalog.html) - for validation.
- [ΔT (timekeeping)](https://en.wikipedia.org/wiki/%CE%94T_(timekeeping)) - Wikipedia overview.
