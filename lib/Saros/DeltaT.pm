package Saros::DeltaT;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(delta_t delta_t_centuries);

# ΔT (TT - UT) in seconds
# Based on Espenak & Meeus polynomial expressions
# Reference: https://eclipse.gsfc.nasa.gov/SEhelp/deltatpoly2004.html
#
# Returns ΔT in seconds for a given decimal year.

sub delta_t {
    my ($year) = @_;

    if ($year < -500) {
        my $u = ($year - 1820.0) / 100.0;
        return -20 + 32 * $u * $u;
    }
    elsif ($year < 500) {
        my $u = $year / 100.0;
        return 10583.6
            + (-1014.41 + (33.78311 + (-5.952053
            + (-0.1798452 + (0.022174192
            + 0.0090316521 * $u) * $u) * $u) * $u) * $u) * $u;
    }
    elsif ($year < 1600) {
        my $u = ($year - 1000.0) / 100.0;
        return 1574.2
            + (-556.01 + (71.23472 + (0.319781
            + (-0.8503463 + (-0.005050998
            + 0.0083572073 * $u) * $u) * $u) * $u) * $u) * $u;
    }
    elsif ($year < 1700) {
        my $t = $year - 1600;
        return 120 + (-0.9808 + (-0.01532 + (1.0 / 7129.0) * $t) * $t) * $t;
    }
    elsif ($year < 1800) {
        my $t = $year - 1700;
        return 8.83 + (0.1603 + (-0.0059285 + (0.00013336
            + (-1.0 / 1174000.0) * $t) * $t) * $t) * $t;
    }
    elsif ($year < 1860) {
        my $t = $year - 1800;
        return 13.72 + (-0.332447 + (0.0068612 + (0.0041116
            + (-0.00037436 + (0.0000121272
            + (-0.0000001699 + 0.000000000875 * $t) * $t) * $t) * $t) * $t) * $t) * $t;
    }
    elsif ($year < 1900) {
        my $t = $year - 1860;
        return 7.62 + (0.5737 + (-0.251754 + (0.01680668
            + (-0.0004473624 + (1.0 / 233174.0) * $t) * $t) * $t) * $t) * $t;
    }
    elsif ($year < 1920) {
        my $t = $year - 1900;
        return -2.79 + (1.494119 + (-0.0598939 + (0.0061966
            - 0.000197 * $t) * $t) * $t) * $t;
    }
    elsif ($year < 1941) {
        my $t = $year - 1920;
        return 21.20 + (0.84493 + (-0.076100 + 0.0020936 * $t) * $t) * $t;
    }
    elsif ($year < 1961) {
        my $t = $year - 1950;
        return 29.07 + (0.407 + (-1.0 / 233.0 + (1.0 / 2547.0) * $t) * $t) * $t;
    }
    elsif ($year < 1986) {
        my $t = $year - 1975;
        return 45.45 + (1.067 + (-1.0 / 260.0 + (-1.0 / 718.0) * $t) * $t) * $t;
    }
    elsif ($year < 2005) {
        my $t = $year - 2000;
        return 63.86 + (0.3345 + (-0.060374 + (0.0017275
            + (0.000651814 + 0.00002373599 * $t) * $t) * $t) * $t) * $t;
    }
    elsif ($year < 2050) {
        my $t = $year - 2000;
        return 62.92 + (0.32217 + 0.005589 * $t) * $t;
    }
    elsif ($year < 2150) {
        return -20 + 32 * (($year - 1820.0) / 100.0) ** 2
            - 0.5628 * (2150 - $year);
    }
    else {
        my $u = ($year - 1820.0) / 100.0;
        return -20 + 32 * $u * $u;
    }
}

# Convert ΔT from seconds to Julian centuries (for use in engine)
sub delta_t_centuries {
    my ($year) = @_;
    return delta_t($year) / (86400.0 * 36525.0);
}

1;

__END__

=head1 NAME

Saros::DeltaT - ΔT (TT - UT) polynomial approximation

=head1 SYNOPSIS

    use Saros::DeltaT qw(delta_t);

    my $dt_seconds  = delta_t(2024);        # ~69.4 seconds
    my $dt_centuries = delta_t_centuries(2024);

=head1 DESCRIPTION

Implements the Espenak & Meeus polynomial expressions for ΔT,
covering -500 CE to 2150 CE with extrapolation beyond.

ΔT = TT - UT, where TT is Terrestrial Time and UT is Universal Time.
The original saros.pl used UT throughout without correction;
applying ΔT significantly improves accuracy for historical eclipses.

=cut
