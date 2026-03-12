package Saros::Calendar;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(jd_to_date date_to_jd jd_to_ut_hours chopdigits);

# Julian Day Number to calendar date
# Handles Julian/Gregorian calendar reform (JD 2299161 = Oct 15, 1582)
sub jd_to_date {
    my ($jd) = @_;
    my $jd0 = int($jd + 0.5);
    my $c1;

    if ($jd0 < 2299161) {
        $c1 = $jd0 + 1524;
    } else {
        my $c0 = int(($jd0 - 1867216.25) / 36524.25);
        $c1 = $jd0 + ($c0 - int($c0 / 4)) + 1525;
    }

    my $c2 = int(($c1 - 122.1) / 365.25);
    my $c3 = 365 * $c2 + int($c2 / 4);
    my $c4 = int(($c1 - $c3) / 30.6001);

    my $day   = $c1 - $c3 - int(30.6001 * $c4);
    my $month = $c4 - 1 - 12 * int($c4 / 14);
    my $year  = $c2 - 4715 - int((7 + $month) / 10);
    my $hour  = 24 * ($jd + 0.5 - $jd0);

    return ($day, $month, $year, $hour);
}

# Calendar date to Julian Day Number
sub date_to_jd {
    my ($year, $month, $day, $hour) = @_;
    $hour //= 0;

    my ($y, $m);
    if ($month <= 2) {
        $y = $year - 1;
        $m = $month + 12;
    } else {
        $y = $year;
        $m = $month;
    }

    my $b;
    my $jd_greg = int(365.25 * ($y + 4716)) + int(30.6001 * ($m + 1)) + $day - 1524.5;
    if ($jd_greg >= 2299161) {
        my $a = int($y / 100);
        $b = 2 - $a + int($a / 4);
    } else {
        $b = 0;
    }

    return $jd_greg + $b + $hour / 24.0;
}

# Convert JD to UT hours and formatted HH:MM string
sub jd_to_ut_hours {
    my ($jd) = @_;
    my $jd0 = int($jd + 0.5);
    my $hour = 24 * ($jd + 0.5 - $jd0);

    my $mins = chopdigits($hour) * 60;
    $mins = int($mins);
    my $hours = int($hour);

    my $h_m = sprintf("%02d:%02d", $hours, $mins);
    return ($hour, $h_m);
}

# Extract fractional part of a number (always positive)
sub chopdigits {
    my ($arg) = @_;
    $arg -= int($arg);
    $arg += 1 if ($arg < 0);
    return $arg;
}

1;

__END__

=head1 NAME

Saros::Calendar - Julian Day and calendar date conversions

=head1 SYNOPSIS

    use Saros::Calendar qw(jd_to_date date_to_jd chopdigits);

    my ($day, $month, $year, $hour) = jd_to_date($jd);
    my $jd = date_to_jd(2024, 4, 8, 12.0);

=cut
