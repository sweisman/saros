#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More tests => 12;

# ── Load modules ──────────────────────────────────────────

use_ok('Saros::Calendar');
use_ok('Saros::DeltaT');
use_ok('Saros::Coordinates');
use_ok('Saros::Projection');
use_ok('Saros::Engine');

# ── Calendar round-trip ───────────────────────────────────

{
    my $jd = Saros::Calendar::date_to_jd(2024, 4, 8, 12.0);
    my ($d, $m, $y, $h) = Saros::Calendar::jd_to_date($jd);
    is($d, 8,    'Calendar round-trip: day');
    is($m, 4,    'Calendar round-trip: month');
    is($y, 2024, 'Calendar round-trip: year');
}

# ── ΔT sanity ─────────────────────────────────────────────

{
    my $dt = Saros::DeltaT::delta_t(2000);
    ok($dt > 60 && $dt < 70, "DeltaT(2000) = $dt is in expected range ~63-64s");
}

# ── Eclipse detection: 2024 ───────────────────────────────

{
    my $engine = Saros::Engine->new(use_delta_t => 1);
    my $candidates = $engine->find_eclipse_candidates(2024, 2024);

    ok(scalar(@$candidates) >= 2,
        "Found " . scalar(@$candidates) . " eclipse candidates in 2024 (expect 2)");

    # April 8, 2024 total solar eclipse
    my @april = grep { $_->{month} == 4 && $_->{day} >= 7 && $_->{day} <= 9 }
                @$candidates;
    ok(@april >= 1, 'Found April 2024 eclipse candidate (day=' .
        ($april[0] ? $april[0]->{day} : 'none') . ')');

    # Compute central line for the April eclipse
    if (@april) {
        my $line = $engine->calculate_central_line($april[0]);
        my @central = grep { $_->{phase} eq 'central' && defined $_->{geo_lon} } @$line;
        ok(@central > 0,
            "Central line has " . scalar(@central) . " points");
    } else {
        fail('No April eclipse to compute central line for');
    }
}
