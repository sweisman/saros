package Saros::Coordinates;

use strict;
use warnings;
use Math::Trig qw(asin atan tan deg2rad rad2deg pi);
use Saros::Calendar qw(chopdigits);
use Exporter 'import';

our @EXPORT_OK = qw(
    ecliptic_to_equatorial
    equatorial_to_geographic
    sun_position
    moon_position
    obliquity
);

my $PI2 = 2 * pi;

# Obliquity of the ecliptic at time t (Julian centuries since J2000)
# Returns radians
sub obliquity {
    my ($t) = @_;
    return $PI2 * (0.065109142 - 3.613e-5 * $t);
}

# Sun ecliptic coordinates at time t (centuries since J2000)
# Returns ($lambda_deg, $beta_deg, $cartesian_equatorial_xyz_km)
sub sun_position {
    my ($t) = @_;

    # Mean anomaly [rad]
    my $lS = chopdigits(0.9931266 + 99.9973604 * $t) * $PI2;

    # Perturbation in ecliptic longitude ['']
    my $dlam = 6893 * sin($lS) + 72 * sin(2 * $lS)
        + 6.4  * sin($PI2 * (0.6983 + 0.0561 * $t))
        + 1.87 * sin($PI2 * (0.5764 + 0.4174 * $t))
        + 0.27 * sin($PI2 * (0.4189 + 0.3306 * $t))
        + 0.20 * sin($PI2 * (0.3581 + 2.4814 * $t));

    # Ecliptic longitude [degrees]
    my $lambda = 282.94031 + rad2deg($lS)
        + (6191.2 * $t + 1.1 * $t * $t + $dlam) / 3600.0;

    # Ecliptic latitude [degrees] — effectively 0 for the Sun
    my $beta = 0;

    # Earth-Sun distance [km] — dominant eccentricity correction (e=0.016708)
    my $mS = 149597870 * (1 - 0.016708 * cos($lS) - 0.000141 * cos(2 * $lS));

    # Convert to equatorial cartesian [km]
    my $xyz = _ecliptic_to_equatorial_cartesian($lambda, $beta, $mS, $t);

    return ($lambda, $beta, $xyz);
}

# Moon ecliptic coordinates at time t (centuries since J2000)
# Returns ($lambda_deg, $beta_deg, $cartesian_equatorial_xyz_km)
sub moon_position {
    my ($t) = @_;
    my $D0 = 0.827361;
    my $D1 = 1236.853086;

    # Mean anomaly of Moon [rad]
    my $lM = chopdigits(0.374897 + 1325.552410 * $t) * $PI2;
    # Mean longitude [revolutions]
    my $L0 = chopdigits(0.606433 + 1336.855225 * $t - 3.1389e-6 * $t * $t);
    # Node distance [rad]
    my $F = $PI2 * chopdigits(0.259086 + 1342.227825 * $t);
    # Mean elongation [rad]
    my $D = $PI2 * (chopdigits(0.5 + $D0 + $D1 * $t) - 0.5);
    # Mean anomaly of Sun [rad]
    my $lS = chopdigits(0.9931266 + 99.9973604 * $t) * $PI2;

    # Perturbation terms
    my $S = $PI2 * chopdigits(3.14e-4 * sin(2 * $F) + 4.17e-4 * sin($lS));
    my $N = -526 * sin($F - 2 * $D) + 44 * sin($F + $lM - 2 * $D)
          - 31 * sin($F - $lM - 2 * $D);

    # Perturbation in ecliptic longitude [revolutions]
    my $dlam = chopdigits(
        (22640 * sin($lM) - 4586 * sin($lM - 2 * $D)
        + 2370 * sin(2 * $D) + 769 * sin(2 * $lM)
        - 668 * sin($lS) - 412 * sin(2 * $F)
        - 212 * sin(2 * $lM - 2 * $D)
        - 206 * sin($lM + $lS - 2 * $D)
        + 192 * sin($lM + 2 * $D)
        - 165 * sin($lS - 2 * $D) - 125 * sin($D)
        - 110 * sin($lM + $lS) + 148 * sin($lM - $lS)
        - 55 * sin(2 * $F - 2 * $D)) / (3600 * 360)
    );

    # Ecliptic longitude [degrees]
    my $lambda = ($L0 + $dlam) * 360;

    # Ecliptic latitude [degrees]
    my $beta = (18520 * sin($F + $dlam * $PI2 + $S) + $N) / 3600.0;

    # Moon-Earth distance [km] — Meeus Ch.47 Table 47.A (Σr, units: 0.001 km)
    # Eccentricity factor for terms with M (Sun's anomaly) dependence
    my $E  = 1 - 0.002516 * $t - 0.0000074 * $t * $t;
    my $E2 = $E * $E;
    my @dr_terms = (
        # D   M   M'  F    coeff (0.001 km)
        [ 0,  0,  1,  0,  -20905355],
        [ 2,  0, -1,  0,   -3699111],
        [ 2,  0,  0,  0,   -2955968],
        [ 0,  0,  2,  0,    -569925],
        [ 0,  1,  0,  0,      48888],
        [ 0,  0,  0,  2,      -3149],
        [ 2,  0, -2,  0,     246158],
        [ 2, -1, -1,  0,    -152138],
        [ 2,  0,  1,  0,    -170733],
        [ 2, -1,  0,  0,    -204586],
        [ 0,  1, -1,  0,    -129620],
        [ 1,  0,  0,  0,     108743],
        [ 0,  1,  1,  0,     104755],
        [ 2,  0,  0, -2,      10321],
        [ 0,  0,  1, -2,      79661],
        [ 4,  0, -1,  0,     -34782],
        [ 0,  0,  3,  0,     -23210],
        [ 4,  0, -2,  0,     -21636],
        [ 2,  1, -1,  0,      24208],
        [ 2,  1,  0,  0,      30824],
        [ 1,  0, -1,  0,      -8379],
        [ 1,  1,  0,  0,     -16675],
        [ 2, -1,  1,  0,     -12831],
        [ 2,  0,  2,  0,     -10445],
        [ 4,  0,  0,  0,     -11650],
        [ 2,  0, -3,  0,      14403],
        [ 0,  1, -2,  0,      -7003],
        [ 2, -1, -2,  0,      10056],
        [ 1,  0,  1,  0,       6322],
        [ 2, -2,  0,  0,      -9884],
        [ 0,  1,  2,  0,       5751],
        [ 2, -2, -1,  0,      -4950],
        [ 2,  0,  1, -2,       4130],
        [ 4, -1, -1,  0,      -3958],
        [ 3,  0, -1,  0,       3258],
        [ 2,  1,  1,  0,       2616],
        [ 4, -1, -2,  0,      -1897],
        [ 0,  2, -1,  0,      -2117],
        [ 2,  2, -1,  0,       2354],
        [ 4,  0,  1,  0,      -1423],
        [ 0,  0,  4,  0,      -1117],
        [ 4, -1,  0,  0,      -1571],
        [ 1,  0, -2,  0,      -1739],
        [ 0,  0,  2, -2,      -4421],
        [ 2,  0, -1, -2,       8752],
    );
    my $sum_r = 0;
    for my $term (@dr_terms) {
        my ($td, $tm, $tmp, $tf, $coeff) = @$term;
        my $Ef = (abs($tm) == 2) ? $E2 : (abs($tm) == 1) ? $E : 1;
        $sum_r += $coeff * $Ef * cos($td*$D + $tm*$lS + $tmp*$lM + $tf*$F);
    }
    my $mM = 385000.56 + $sum_r / 1000;

    # Convert to equatorial cartesian [km]
    my $xyz = _ecliptic_to_equatorial_cartesian($lambda, $beta, $mM, $t);

    return ($lambda, $beta, $xyz);
}

# Convert ecliptic (lon_deg, lat_deg, distance_km) to equatorial cartesian
# Returns arrayref [x1, x2, x3] in km
sub _ecliptic_to_equatorial_cartesian {
    my ($lambda_deg, $beta_deg, $dist, $t) = @_;

    my $lam = deg2rad($lambda_deg);
    my $bet = deg2rad($beta_deg);
    my $eps = obliquity($t);

    my $cb = cos($bet);
    my $x_ekl = $dist * $cb * cos($lam);
    my $y_ekl = $dist * $cb * sin($lam);
    my $z_ekl = $dist * sin($bet);

    my $ce = cos($eps);
    my $se = sin($eps);

    return [
        $x_ekl,
        $y_ekl * $ce - $z_ekl * $se,
        $y_ekl * $se + $z_ekl * $ce,
    ];
}

# Equatorial right ascension and declination to geographic coordinates
# $alpha: right ascension [radians]
# $delta: declination [radians]
# $t: time in Julian centuries since J2000
# Returns ($geo_lon, $geo_lat) in degrees
sub equatorial_to_geographic {
    my ($alpha, $delta, $t) = @_;

    my $MJD = 36525 * $t + 51544.5;
    my $UT  = chopdigits($MJD) * 24;
    my $T   = ($MJD - $UT / 24 - 51544.5) / 36525;

    my $theta = 6.697374558
        + 1.0027379093 * $UT
        + 2400.051337 * $T
        + (0.093104 * $T * $T - 0.0000062 * $T * $T * $T) / 3600;

    my $geo_lon = rad2deg($alpha) - 15 * $theta;
    $geo_lon = 360 * chopdigits($geo_lon / 360);
    $geo_lon -= 360 if $geo_lon > 180;

    my $geo_lat = rad2deg($delta) + 0.1924 * sin(2 * $delta);

    return ($geo_lon, $geo_lat);
}

# Exported version of ecliptic_to_equatorial for external use
sub ecliptic_to_equatorial {
    my ($lambda_deg, $beta_deg, $dist, $t) = @_;
    return _ecliptic_to_equatorial_cartesian($lambda_deg, $beta_deg, $dist, $t);
}

1;

__END__

=head1 NAME

Saros::Coordinates - Astronomical coordinate transformations

=head1 DESCRIPTION

Provides Sun and Moon positions in ecliptic coordinates and transforms
to equatorial cartesian and geographic coordinate systems.

All time parameters are in Julian centuries since J2000.0.

=cut
