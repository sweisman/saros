package Saros::Engine;

use strict;
use warnings;
use Math::Trig qw(asin atan tan pi);
use Saros::Calendar qw(jd_to_date jd_to_ut_hours chopdigits);
use Saros::Coordinates qw(sun_position moon_position equatorial_to_geographic);
use Saros::DeltaT qw(delta_t);

my $PI2     = 2 * pi;
my $PIHALF  = pi / 2;
my $PI3HALF = 3 * pi / 2;
my $D1      = 1236.853086;
my $D0      = 0.827361;

# WGS84 ellipsoid
my $WGS84_A = 6378.137;     # equatorial radius [km]
my $WGS84_B = 6356.752314;  # polar radius [km]
# Sphere (original model)
my $SPHERE_R = 6371;        # mean radius [km]

# Constructor
# Args:
#   use_delta_t => 0|1 (default 1)
#   earth_model => 'wgs84' | 'sphere' (default 'wgs84')
sub new {
    my ($class, %opts) = @_;
    bless {
        use_delta_t => $opts{use_delta_t} // 1,
        earth_model => $opts{earth_model} // 'wgs84',
    }, $class;
}

# ── Earth model helpers ──────────────────────────────────

# Returns (a, b) — semi-major and semi-minor axes
sub _earth_axes {
    my ($self) = @_;
    if ($self->{earth_model} eq 'wgs84') {
        return ($WGS84_A, $WGS84_B);
    }
    return ($SPHERE_R, $SPHERE_R);
}

# Ray-ellipsoid intersection
#
# Given a ray:  P(t) = origin + t * dir
# and ellipsoid: (x/a)^2 + (y/a)^2 + (z/b)^2 = 1
#
# Substituting the ray equation into the ellipsoid equation gives
# a standard quadratic in t:
#
#   A*t^2 + B*t + C = 0
#
# where, using s = (a/b)^2 for the axis ratio:
#
#   A = dx^2 + dy^2 + s * dz^2
#   B = 2*(ox*dx + oy*dy + s * oz*dz)
#   C = ox^2 + oy^2 + s * oz^2 - a^2
#
# The discriminant B^2 - 4AC tells us:
#   < 0 : ray misses the ellipsoid entirely
#   = 0 : ray is tangent (grazes the surface)
#   > 0 : ray pierces the ellipsoid at two points
#
# We take the smaller positive t, which gives the nearest
# intersection point (the side of Earth facing the shadow).
#
# For a sphere (a = b), this reduces to the original code's
# approach since s = 1 and a = r_E.
#
# Returns: arrayref [x, y, z] of intersection point, or undef
#
sub _ray_earth_intersect {
    my ($self, $origin, $dir) = @_;
    my ($a, $b) = $self->_earth_axes;

    # s = (a/b)^2 — scales the z-component to account for flattening
    # When a = b (sphere), s = 1 and this is standard ray-sphere
    my $s = ($a / $b) ** 2;

    my ($ox, $oy, $oz) = @$origin;
    my ($dx, $dy, $dz) = @$dir;

    # Quadratic coefficients
    my $A = $dx*$dx + $dy*$dy + $s * $dz*$dz;
    my $B = 2 * ($ox*$dx + $oy*$dy + $s * $oz*$dz);
    my $C = $ox*$ox + $oy*$oy + $s * $oz*$oz - $a*$a;

    my $disc = $B*$B - 4*$A*$C;
    return undef if $disc < 0;  # ray misses Earth

    my $sqrt_disc = sqrt($disc);
    # Two solutions: t1 <= t2
    my $t1 = (-$B - $sqrt_disc) / (2 * $A);
    my $t2 = (-$B + $sqrt_disc) / (2 * $A);

    # We want the nearest intersection in the forward direction
    my $t = ($t1 > 0) ? $t1 : ($t2 > 0) ? $t2 : return undef;

    return [
        $ox + $t * $dx,
        $oy + $t * $dy,
        $oz + $t * $dz,
    ];
}

# Check if a point is inside the ellipsoid
# Used for penumbra/umbra radius calculations
sub _point_inside_earth {
    my ($self, $point) = @_;
    my ($a, $b) = $self->_earth_axes;
    my ($x, $y, $z) = @$point;
    return ($x*$x + $y*$y) / ($a*$a) + ($z*$z) / ($b*$b) <= 1.0;
}

# Distance from a point to the ellipsoid surface along a given direction
# Returns the "overshoot" distance (how far past the surface the shadow axis is)
# Negative means the axis is above the surface (no central eclipse at this point)
sub _surface_distance {
    my ($self, $moon, $e_vec, $d0) = @_;
    my ($a, $b) = $self->_earth_axes;

    # Point on shadow axis closest to Earth center
    my @axis_pt = (
        $moon->[0] + $d0 * $e_vec->[0],
        $moon->[1] + $d0 * $e_vec->[1],
        $moon->[2] + $d0 * $e_vec->[2],
    );

    # Radial distance from center, accounting for ellipsoid
    # For a point (x,y,z), its "ellipsoidal radius" is
    # sqrt(x^2 + y^2 + (a/b)^2 * z^2) compared against a
    my $s = ($a / $b) ** 2;
    my $ell_r = sqrt($axis_pt[0]**2 + $axis_pt[1]**2 + $s * $axis_pt[2]**2);

    return $a - $ell_r;  # positive = axis is below surface
}

# ── New Moon Finder ──────────────────────────────────────

# Find all new moons in a year range, flagging possible eclipses
# Returns arrayref of hashrefs:
#   { day, month, year, hour, beta, eclipse_possible, tNM }
sub find_new_moons {
    my ($self, $from_year, $to_year) = @_;
    my @results;

    for my $calc_year ($from_year .. $to_year) {
        push @results, @{ $self->_new_moons_one_year($calc_year) };
    }

    return \@results;
}

# Find only the eclipse candidates
sub find_eclipse_candidates {
    my ($self, $from_year, $to_year) = @_;
    my $all = $self->find_new_moons($from_year, $to_year);
    return [ grep { $_->{eclipse_possible} } @$all ];
}

sub _new_moons_one_year {
    my ($self, $calc_year) = @_;
    my @results;

    for my $i (0 .. 13) {
        my $tNM = (int($D1 * ($calc_year - 2000) / 100) + $i - $D0) / $D1;
        my $beta;

        # Iterate twice for accuracy
        for my $iter (0 .. 1) {
            my $lM = chopdigits(0.374897 + 1325.552410 * $tNM) * $PI2;
            my $lS = $PI2 * chopdigits(0.993133 + 99.997361 * $tNM);
            my $D  = (chopdigits(0.5 + $D0 + $D1 * $tNM) - 0.5) * $PI2;
            my $F  = $PI2 * chopdigits(0.259086 + 1342.227825 * $tNM);

            my $dlamM = (
                22640 * sin($lM) - 4586 * sin($lM - 2*$D)
                + 2370 * sin(2*$D) + 769 * sin(2*$lM)
                - 668 * sin($lS) - 412 * sin(2*$F)
                - 212 * sin(2*$lM - 2*$D)
                - 206 * sin($lM + $lS - 2*$D)
                + 192 * sin($lM + 2*$D)
                - 165 * sin($lS - 2*$D) - 125 * sin($D)
                - 110 * sin($lM + $lS) + 148 * sin($lM - $lS)
                - 55 * sin(2*$F - 2*$D)
            ) / (3600 * 360);

            my $dlamS = (6893 * sin($lS) + 72 * sin(2*$lS)) / (3600 * 360);

            $tNM -= ($D / $PI2 + ($dlamM - $dlamS)) / $D1;

            if ($iter == 1) {
                $beta = (18520 * sin($F + $dlamM * $PI2) - 526 * sin($F - 2*$D)) / 3600.0;
            }
        }

        # tNM is in TT (dynamical time) — keep it for position calculations.
        # Apply ΔT only for calendar display: UT = TT - ΔT
        my $tNM_display = $tNM;
        if ($self->{use_delta_t}) {
            my $approx_year = 2000 + $tNM * 100;
            $tNM_display = $tNM - Saros::DeltaT::delta_t_centuries($approx_year);
        }

        # Convert to calendar date (in UT)
        my $JD = 36525 * $tNM_display + 2451545;
        my ($day, $month, $year, $hour) = jd_to_date($JD);

        next unless $year == $calc_year;

        my $eclipse_possible = (abs($beta) < 1.58) ? 1 : 0;

        push @results, {
            day              => $day,
            month            => $month,
            year             => $year,
            hour             => $hour,
            beta             => $beta,
            eclipse_possible => $eclipse_possible,
            tNM              => $tNM,  # TT, for position calculations
        };
    }

    return \@results;
}

# ── Central Line Calculator ──────────────────────────────

# Calculate the central line for an eclipse
# Args: $nm_data - hashref from find_new_moons (needs tNM field)
# Returns arrayref of hashrefs:
#   { day, month, year, h_m_time, phase, geo_lon, geo_lat }
sub calculate_central_line {
    my ($self, $nm_data) = @_;
    my $tNM = $nm_data->{tNM};
    my @results;

    my $r_M = 1738;          # radius Moon [km]
    my $r_S = 696000;        # radius Sun [km]
    my ($r_E_a, $r_E_b) = $self->_earth_axes;
    my $qday = 0.25 / 36525; # quarter day in centuries
    my $dt = 5 / (60 * 24 * 36525);  # 5 min in centuries

    my $start = $tNM - $qday;
    my $end   = $tNM + $qday;

    # Coarse pass to find the central window, then refine step size
    my ($first_central_t, $last_central_t);
    for (my $t = $start; $t <= $end; $t += $dt) {
        my (undef, undef, $sun_xyz)  = sun_position($t);
        my (undef, undef, $moon_xyz) = moon_position($t);
        my $m = $moon_xyz;
        my @d = ($m->[0] - $sun_xyz->[0], $m->[1] - $sun_xyz->[1], $m->[2] - $sun_xyz->[2]);
        my $dist = sqrt($d[0]**2 + $d[1]**2 + $d[2]**2);
        my @e = map { $_ / $dist } @d;
        if ($self->_ray_earth_intersect($m, \@e)) {
            $first_central_t //= $t;
            $last_central_t = $t;
        }
    }

    # Use finer steps for short-duration eclipses (target at least 30 central points)
    if (defined $first_central_t) {
        my $duration = $last_central_t - $first_central_t;
        if ($duration > 0) {
            my $fine_dt = $duration / 30;
            $dt = $fine_dt if $fine_dt < $dt;
        }
    }

    for (my $t = $start; $t <= $end; $t += $dt) {
        my (undef, undef, $sun_xyz)  = sun_position($t);
        my (undef, undef, $moon_xyz) = moon_position($t);

        my $s = $sun_xyz;
        my $m = $moon_xyz;

        # Unit vector from Sun to Moon (shadow direction)
        my @d = ($m->[0] - $s->[0], $m->[1] - $s->[1], $m->[2] - $s->[2]);
        my $dist = sqrt($d[0]**2 + $d[1]**2 + $d[2]**2);
        my @e = map { $_ / $dist } @d;

        # d0: parameter along shadow axis closest to Earth center
        # (projection of -moon_vector onto shadow direction)
        my $d0 = -($m->[0]*$e[0] + $m->[1]*$e[1] + $m->[2]*$e[2]);

        # Shadow cone radii at distance d0 from Moon along axis
        my $rH = (($r_M * $dist) / ($r_M + $r_S) + $d0)
                 * tan(asin(($r_M + $r_S) / $dist));
        my $rK = (($r_M * $dist) / ($r_S - $r_M) - $d0)
                 * tan(asin(($r_S - $r_M) / $dist));
        $rK = abs($rK);

        # How far the shadow axis is from Earth's surface
        my $p0 = $self->_surface_distance($m, \@e, $d0);

        # Determine phase from shadow geometry
        # p0 > 0 means the shadow axis passes through/below the surface.
        # The ray intersection test is the definitive check for central eclipse
        # (shadow axis actually hits the surface on the sunlit side).
        # p0 > -rH means Earth is within the penumbra cone (partial eclipse).
        my $phase;
        my $hit = $self->_ray_earth_intersect($m, \@e);
        if ($hit) {
            $phase = 'central';
        } elsif ($p0 > -$rH) {
            $phase = 'partial';
        } else {
            next;  # no eclipse
        }

        my ($geo_lon, $geo_lat);

        if ($phase eq 'central') {
            # Convert cartesian hit point to geographic coordinates
            #
            # For the ellipsoid, geographic (geodetic) latitude is NOT
            # simply atan(z / sqrt(x^2+y^2)).  That gives geocentric
            # latitude.  Geodetic latitude accounts for the surface
            # normal direction:
            #
            #   tan(lat_geodetic) = (z / sqrt(x^2+y^2)) * (a/b)^2
            #
            # This is because the surface normal of the ellipsoid at
            # point (x,y,z) tilts away from the radial direction due
            # to flattening.  The (a/b)^2 factor is ~1.0067 — small
            # but it shifts latitude by up to ~0.19° (~21 km) at 45°.
            #
            my ($px, $py, $pz) = @$hit;

            # Right ascension (equatorial longitude) — same for
            # sphere or ellipsoid since it's just the angle in the
            # equatorial plane
            my $alpha = atan2($py, $px);

            # Geodetic latitude on ellipsoid
            my $r_xy = sqrt($px*$px + $py*$py);
            my $lat_geocentric = atan2($pz, $r_xy);
            my $lat_geodetic;
            if ($self->{earth_model} eq 'wgs84') {
                # tan(geodetic) = tan(geocentric) * (a/b)^2
                $lat_geodetic = atan(($r_E_a / $r_E_b)**2
                                    * tan($lat_geocentric));
            } else {
                $lat_geodetic = $lat_geocentric;
            }

            ($geo_lon, $geo_lat) = equatorial_to_geographic(
                $alpha, $lat_geodetic, $t
            );
        }

        # Convert time to calendar (apply ΔT for UT display)
        my $t_display = $t;
        if ($self->{use_delta_t}) {
            my $approx_year = 2000 + $t * 100;
            $t_display = $t - Saros::DeltaT::delta_t_centuries($approx_year);
        }
        my $JD = 36525 * $t_display + 2451545;
        my ($day, $month, $year, $hour) = jd_to_date($JD);
        my (undef, $h_m) = jd_to_ut_hours($JD);

        push @results, {
            day      => $day,
            month    => $month,
            year     => $year,
            hour     => $hour,
            h_m_time => $h_m,
            phase    => $phase,
            geo_lon  => $geo_lon,
            geo_lat  => $geo_lat,
        };
    }

    return \@results;
}

# Quick check: does this eclipse have any central line points?
# Uses coarser time steps and returns as soon as one is found.
sub has_central_line {
    my ($self, $nm_data) = @_;
    my $tNM = $nm_data->{tNM};

    my $r_M = 1738;
    my $r_S = 696000;
    my $qday = 0.25 / 36525;
    my $dt = 15 / (60 * 24 * 36525);  # 15 min steps (3x coarser)

    for (my $t = $tNM - $qday; $t <= $tNM + $qday; $t += $dt) {
        my (undef, undef, $sun_xyz)  = sun_position($t);
        my (undef, undef, $moon_xyz) = moon_position($t);

        my $m = $moon_xyz;
        my @d = ($m->[0] - $sun_xyz->[0], $m->[1] - $sun_xyz->[1], $m->[2] - $sun_xyz->[2]);
        my $dist = sqrt($d[0]**2 + $d[1]**2 + $d[2]**2);
        my @e = map { $_ / $dist } @d;

        my $hit = $self->_ray_earth_intersect($m, \@e);
        return 1 if $hit;
    }
    return 0;
}

# Calculate the subsolar point track spanning the central line period.
# The subsolar point is where the Sun is directly overhead on Earth.
# Args: $nm_data, $central_line (arrayref from calculate_central_line)
# Returns arrayref of { geo_lon, geo_lat } hashrefs.
sub calculate_subsolar_track {
    my ($self, $nm_data, $central_line) = @_;
    my $tNM = $nm_data->{tNM};
    my @results;

    # Determine time span from central line points
    my @central = grep { $_->{phase} eq 'central' } @$central_line;
    return \@results unless @central;

    # Find first and last central point indices to get time range
    my $qday = 0.25 / 36525;
    my $dt = 5 / (60 * 24 * 36525);  # 5 min steps
    my $n_steps = int(2 * $qday / $dt);

    # Count which steps are central (matching the central line loop)
    my ($first_step, $last_step);
    my $step = 0;
    for (my $t = $tNM - $qday; $t <= $tNM + $qday; $t += $dt) {
        my (undef, undef, $sun_xyz)  = sun_position($t);
        my (undef, undef, $moon_xyz) = moon_position($t);
        my $m = $moon_xyz;
        my @d = ($m->[0] - $sun_xyz->[0], $m->[1] - $sun_xyz->[1], $m->[2] - $sun_xyz->[2]);
        my $dist = sqrt($d[0]**2 + $d[1]**2 + $d[2]**2);
        my @e = map { $_ / $dist } @d;
        if ($self->_ray_earth_intersect($m, \@e)) {
            $first_step //= $step;
            $last_step = $step;
        }
        $step++;
    }
    return \@results unless defined $first_step;

    # Compute subsolar track for that time range
    my $start = $tNM - $qday + $first_step * $dt;
    my $end   = $tNM - $qday + $last_step * $dt;

    # Use finer steps for short-duration eclipses (target at least 30 points)
    my $duration = $end - $start;
    my $track_dt = $dt;
    if ($duration > 0) {
        my $min_points = 30;
        my $fine_dt = $duration / $min_points;
        $track_dt = $fine_dt if $fine_dt < $dt;
    }

    for (my $t = $start; $t <= $end; $t += $track_dt) {
        my (undef, undef, $sun_xyz) = sun_position($t);
        my ($sx, $sy, $sz) = @$sun_xyz;
        my $alpha = atan2($sy, $sx);
        my $r_xy = sqrt($sx*$sx + $sy*$sy);
        my $delta = atan2($sz, $r_xy);
        my ($geo_lon, $geo_lat) = equatorial_to_geographic($alpha, $delta, $t);
        push @results, { geo_lon => $geo_lon, geo_lat => $geo_lat };
    }

    return \@results;
}

1;

__END__

=head1 NAME

Saros::Engine - Solar eclipse calculation engine

=head1 SYNOPSIS

    use Saros::Engine;

    my $engine = Saros::Engine->new(
        use_delta_t => 1,
        earth_model => 'wgs84',   # or 'sphere'
    );

    my $candidates = $engine->find_eclipse_candidates(2024, 2026);
    for my $nm (@$candidates) {
        my $line = $engine->calculate_central_line($nm);
        # ...
    }

=head1 DESCRIPTION

Pure computational module for solar eclipse detection and central
line calculation.  No UI dependencies.

=head2 Earth Models

B<wgs84> (default): Uses the WGS84 reference ellipsoid
(a=6378.137 km, b=6356.752 km).  Shadow axis intersection is
computed via ray-ellipsoid intersection, and ground point latitude
is geodetic (accounts for surface normal tilt due to flattening).

B<sphere>: Uses a mean spherical Earth (r=6371 km), matching the
original saros.pl behavior.  Faster but less accurate — central
line can be off by ~20 km at mid-latitudes.

=head2 Geometry Overview

The calculation works in Earth-centered equatorial cartesian
coordinates (x, y, z in km).  Sun and Moon positions come from
Saros::Coordinates as 3D vectors.

The shadow is modeled as a cone from the Sun past the Moon.
Its axis direction is the unit vector from Sun to Moon.
The umbra and penumbra cones have half-angles determined by the
Sun, Moon, and their physical radii.

The central line is where the shadow axis pierces the Earth's
surface — a ray-body intersection problem.  For the sphere this
is a simple quadratic.  For the ellipsoid it's the same quadratic
but with scaled z-coordinates.

=cut
