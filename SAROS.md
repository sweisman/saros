# Eclipse Prediction: History and Method

## The Saros Cycle

The Babylonians discovered the Saros cycle by the 7th or 8th century BCE, likely earlier, through meticulous record-keeping on clay tablets. The cycle is 18 years, 11 days, and 8 hours: after one Saros period, the Sun, Moon, and lunar node return to nearly the same relative geometry, producing a similar eclipse.

The extra ~8 hours shifts each recurrence roughly 120° west in longitude. After three Saros cycles (54 years, 33 days — an "Exeligmos"), the path returns to a similar longitude. The Babylonians could predict *when* a solar eclipse was likely, but not *where* on Earth it would be visible.

## Greek and Medieval Refinements

Hipparchus (~150 BCE) developed an improved lunar theory, and Ptolemy (~150 CE) systematized it in the *Almagest*. They could predict the time of a solar eclipse reasonably well and estimate its magnitude for a given location, but could not draw a path across the Earth. They lacked both the mathematical framework and accurate enough lunar parallax measurements.

For roughly 2,000 years the state of the art was: "a solar eclipse will happen around this date, and it might be visible from our region."

Abraham Zacuto and Regiomontanus produced eclipse almanacs in the 15th century that were accurate enough to predict lunar eclipses to within hours. Columbus famously used one of these almanacs to predict the lunar eclipse of February 29, 1504, coercing the Arawak people in Jamaica into providing food and supplies to his stranded crew by claiming his god would make the Moon disappear.

## The Besselian Method (19th Century)

The jump from "when" to "where" required two breakthroughs:

- **Isaac Newton's** gravitational theory (late 17th century) provided accurate enough lunar and solar positions.
- **Edmond Halley** (1715) produced the first map of a predicted solar eclipse path across England, using Newton's lunar theory. This was a genuinely new kind of prediction — not just the time, but the ground track.
- **Friedrich Bessel** (1820s–1830s) formalized the method still used today. The "Besselian elements" describe the Moon's shadow axis relative to a fundamental plane through Earth's center.

### The Shadow Cone

The geometry is straightforward: construct a cone tangent to both the Sun and the Moon. Because the Sun is much larger, the cone's apex falls between the two bodies. Extend the cone past the Moon toward the Earth; where its interior intersects the surface, you get the path of totality.

The shadow on the ground is narrow (typically 100–200 km) not because the Moon is small — the Moon is ~3,474 km in diameter — but because the Sun is not a point source. The Sun and Moon subtend nearly the same angular size (~0.5°), so the umbral cone converges to a near-point just before reaching the Earth's surface. If the Sun were a point source, the Moon would cast a full 3,474 km shadow.

When the Moon is slightly farther from Earth (smaller angular size than the Sun), the umbral cone closes before reaching the surface — that is an annular eclipse.

A second, wider penumbral cone (tangent to both bodies but crossing between them) defines the region of partial eclipse.

### What Has Changed Since Bessel

The geometric formulation is roughly 200 years old. What has improved is the quality of the inputs:

- **Lunar and solar ephemerides** — from hand-computed perturbation series to JPL's numerically integrated DE series.
- **ΔT correction** — TT (Terrestrial Time) vs. UT (Universal Time) diverge due to tidal deceleration of Earth's rotation. For historical eclipses, ΔT can be tens of minutes, shifting the central line by hundreds of kilometers.
- **Earth figure** — from a perfect sphere to the WGS84 reference ellipsoid, correcting path positions by up to ~20 km at mid-latitudes.

## Provenance of This Code

The core eclipse calculation is from **Sebastian Harl's 2003 Facharbeit** (secondary school research paper), *Saros: Berechnung von Sonnenfinsternissen* ("Saros: Calculation of Solar Eclipses"), written at Adam-Kraft-Gymnasium in Schwabach, Germany. It was released as open source under the GNU GPL v2.

Harl's code implements the Besselian shadow-cone intersection directly: it computes lunar and solar positions via truncated trigonometric perturbation series, constructs the shadow axis, and finds where the umbral and penumbral cones intersect the Earth's surface. This is not JPL-grade ephemeris work, but the geometric approach is the same one Bessel formalized two centuries ago.

This version preserves the original orbital mechanics and adds:

- **ΔT correction** using the Espenak & Meeus polynomial expressions (NASA/TP-2006-214141).
- **WGS84 ellipsoidal Earth** geometry (geodetic latitude correction).
- Mercator and azimuthal equidistant map projections with configurable extents.
- A Tk graphical interface and a GD-based command-line interface.

## Possible Improvements

### Better Ephemerides (biggest potential impact)

The current code uses a small custom perturbation series from Harl's 2003 paper — 5 terms for the Sun, 14 for the Moon. These are not a standard catalog. Replacing them with ELP2000/82 (Moon) or VSOP87 (Sun) would add hundreds of terms and bring positional accuracy from arc-minutes down to arc-seconds. Central line positions would improve from ±20–50 km to ±1–2 km. This is the only change that would produce a noticeable improvement at map scale, but it would be significant work — transcribing hundreds of series coefficients or linking to an external ephemeris library.

### Variable Lunar Distance

The Moon's distance is currently fixed at 384,400 km. It actually varies by ~6% due to orbital eccentricity. This directly affects shadow cone geometry — it determines whether an eclipse is total vs. annular and how wide the path of totality is. Accounting for this would improve path width accuracy.

### Atmospheric Refraction

Not modeled. Bending of sunlight through the atmosphere slightly extends eclipse contact times and shifts the edges of the path by a few km at the margins.

### Topography and Elevation

The Earth is treated as a smooth ellipsoid. Mountain ranges can shift local contact times by seconds. Only matters for precise local predictions, not map-scale visualization.

### Assessment

For plotting eclipse paths on a map — showing where and when — the current accuracy is adequate. Paths land in the right place and match the NASA Five Millennium Eclipse Catalog visually. The ±20–50 km uncertainty is well within the line width on any reasonable map scale.

Only the ephemeris upgrade would produce a visible improvement on the map. The remaining improvements matter only for planning observation sites down to a specific field or hilltop, which is better served by dedicated tools such as Xavier Jubier's interactive eclipse maps.

## References

- Espenak, F. & Meeus, J. — *Five Millennium Canon of Solar Eclipses: -1999 to +3000*. NASA/TP-2006-214141.
- Espenak, F. & Meeus, J. — [Polynomial Expressions for Delta T](https://eclipse.gsfc.nasa.gov/SEhelp/deltatpoly2004.html).
- Harl, S. — *Saros: Berechnung von Sonnenfinsternissen* (Facharbeit, Adam-Kraft-Gymnasium Schwabach, 2003).
- [NASA Five Millennium Eclipse Catalog](https://eclipse.gsfc.nasa.gov/SEcat5/SEcatalog.html).
