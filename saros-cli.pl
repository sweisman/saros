#!/usr/bin/perl
# ============================================================
# Saros CLI - command-line eclipse calculator with image output
# ============================================================

use strict;
use warnings;
use Getopt::Long;
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Saros::Engine;
use Saros::Projection;

my $HAS_GD = eval { require GD; 1 } // 0;

# ── Options ───────────────────────────────────────────────

my %opt = (
    from        => undef,
    to          => undef,
    'no-delta-t'=> 0,
    sphere      => 0,
    # map output
    map         => undef,      # output image path (enables image generation)
    'map-bg'    => undef,      # background map image (JPEG)
    'map-fmt'   => 'png',      # output format: png | jpg
    # projection
    projection  => 'mercator', # mercator | azimuthal_equidistant
    # mercator extent (undef = not specified, derive from context)
    'extent-west'  => undef,
    'extent-east'  => undef,
    'extent-north' => undef,
    'extent-south' => undef,
    # azimuthal equidistant extent (undef = not specified)
    'center-lat'    => undef,
    'center-lon'    => undef,
    'extent-radius' => undef,
    # image region (pixels within image that the map covers)
    'image-x' => undef,
    'image-y' => undef,
    'image-w' => undef,
    'image-h' => undef,
    # output image dimensions (when no background image)
    width  => undef,
    height => undef,
    help   => 0,
);

GetOptions(
    'from=i'           => \$opt{from},
    'to=i'             => \$opt{to},
    'no-delta-t'       => \$opt{'no-delta-t'},
    'sphere'           => \$opt{sphere},
    'map=s'            => \$opt{map},
    'map-bg=s'         => \$opt{'map-bg'},
    'map-fmt=s'        => \$opt{'map-fmt'},
    'projection=s'     => \$opt{projection},
    'extent-west=f'    => \$opt{'extent-west'},
    'extent-east=f'    => \$opt{'extent-east'},
    'extent-north=f'   => \$opt{'extent-north'},
    'extent-south=f'   => \$opt{'extent-south'},
    'center-lat=f'     => \$opt{'center-lat'},
    'center-lon=f'     => \$opt{'center-lon'},
    'extent-radius=f'  => \$opt{'extent-radius'},
    'image-x=i'        => \$opt{'image-x'},
    'image-y=i'        => \$opt{'image-y'},
    'image-w=i'        => \$opt{'image-w'},
    'image-h=i'        => \$opt{'image-h'},
    'width=i'          => \$opt{width},
    'height=i'         => \$opt{height},
    'help'             => \$opt{help},
) or usage();

usage() if $opt{help} || !defined $opt{from} || !defined $opt{to};

if ($opt{map} && !$HAS_GD) {
    die "ERROR: GD.pm is required for image output (--map). Install it or omit --map.\n";
}

unless ($opt{projection} =~ /^(mercator|azimuthal_equidistant)$/) {
    die "ERROR: Unknown projection '$opt{projection}'. Use 'mercator' or 'azimuthal_equidistant'.\n";
}

# ── Engine setup ──────────────────────────────────────────

my $earth_model = $opt{sphere} ? 'sphere' : 'wgs84';
my $engine = Saros::Engine->new(
    use_delta_t => !$opt{'no-delta-t'},
    earth_model => $earth_model,
);

print "Saros 2.0 — Solar Eclipse Calculator\n";
print "ΔT correction: " . ($opt{'no-delta-t'} ? "OFF" : "ON") . "\n";
print "Earth model: $earth_model\n";
print "Projection: $opt{projection}\n";
print "Scanning $opt{from} – $opt{to}...\n\n";

# ── Compute ───────────────────────────────────────────────

my $candidates = $engine->find_eclipse_candidates($opt{from}, $opt{to});

if (@$candidates == 0) {
    print "No eclipse candidates found.\n";
    exit 0;
}

printf "Found %d eclipse candidate(s):\n\n", scalar @$candidates;

# Collect all central line points for image output
my @all_central_points;

for my $nm (@$candidates) {
    printf "═══ %02d/%02d/%d  (β = %.4f°) ═══\n",
        $nm->{day}, $nm->{month}, $nm->{year}, $nm->{beta};

    my $line = $engine->calculate_central_line($nm);
    my @central = grep { $_->{phase} eq 'central' && defined $_->{geo_lon} } @$line;

    if (@central) {
        printf "  %-8s  %10s  %10s\n", 'UT', 'Lon', 'Lat';
        printf "  %-8s  %10s  %10s\n", '--------', '----------', '----------';
        for my $pt (@central) {
            printf "  %-8s  %+10.4f  %+10.4f\n",
                $pt->{h_m_time}, $pt->{geo_lon}, $pt->{geo_lat};
        }
        push @all_central_points, @central;
    } else {
        my @any = grep { $_->{phase} ne 'noeclipse' } @$line;
        if (@any) {
            printf "  No central phase — %d partial/noncentral point(s)\n", scalar @any;
        } else {
            print "  No eclipse data computed for this candidate.\n";
        }
    }
    print "\n";
}

# ── Image output ──────────────────────────────────────────

if ($opt{map} && @all_central_points) {
    # Default to bundled world.jpg for Mercator when no --map-bg given
    if (!$opt{'map-bg'} && $opt{projection} eq 'mercator') {
        my $default_bg = "$RealBin/world.jpg";
        $opt{'map-bg'} = $default_bg if -e $default_bg;
    }
    write_map_image(\%opt, \@all_central_points);
}

# ══════════════════════════════════════════════════════════

sub write_map_image {
    my ($o, $points) = @_;

    # Determine image dimensions from background image, explicit size, or defaults
    my ($img, $img_w, $img_h);

    if ($o->{'map-bg'} && -e $o->{'map-bg'}) {
        open my $fh, '<', $o->{'map-bg'}
            or die "ERROR: Cannot open background image $o->{'map-bg'}: $!\n";
        $img = GD::Image->newFromJpeg($fh);
        close $fh;
        ($img_w, $img_h) = $img->getBounds;
        printf "Background image: %s (%dx%d)\n", $o->{'map-bg'}, $img_w, $img_h;
    } else {
        my $is_az = ($o->{projection} eq 'azimuthal_equidistant');
        $img_w = $o->{width}  // ($is_az ? 600 : 800);
        $img_h = $o->{height} // ($is_az ? 600 : 400);
        $img = GD::Image->new($img_w, $img_h);
        my $bg = $img->colorAllocate(26, 26, 46);
        $img->filledRectangle(0, 0, $img_w, $img_h, $bg);
        print "No background image — using ${img_w}x${img_h} canvas.\n";
    }

    # Build projection — apply defaults for anything not explicitly set
    my %proj_args = (
        type   => $o->{projection},
        width  => $img_w,
        height => $img_h,
    );

    if ($o->{projection} eq 'mercator') {
        $proj_args{extent_west}  = $o->{'extent-west'}  // -180;
        $proj_args{extent_east}  = $o->{'extent-east'}  //  180;
        $proj_args{extent_north} = $o->{'extent-north'} //   80;
        $proj_args{extent_south} = $o->{'extent-south'} //  -80;
        printf "Mercator extent: %.1f°W to %.1f°E, %.1f°S to %.1f°N%s\n",
            $proj_args{extent_west}, $proj_args{extent_east},
            $proj_args{extent_south}, $proj_args{extent_north},
            (defined $o->{'extent-west'} ? '' : ' (defaults — override with --extent-*)');
    } else {
        $proj_args{center_lat}    = $o->{'center-lat'}    //  90;
        $proj_args{center_lon}    = $o->{'center-lon'}    //   0;
        $proj_args{extent_radius} = $o->{'extent-radius'} // 180;
        printf "Azimuthal center: %.1f°, %.1f°  radius: %.1f°%s\n",
            $proj_args{center_lat}, $proj_args{center_lon},
            $proj_args{extent_radius},
            (defined $o->{'center-lat'} ? '' : ' (defaults — override with --center-*/--extent-radius)');
    }

    # Image region: defaults to full image
    $proj_args{image_x} = $o->{'image-x'} // 0;
    $proj_args{image_y} = $o->{'image-y'} // 0;
    $proj_args{image_w} = $o->{'image-w'} // $img_w;
    $proj_args{image_h} = $o->{'image-h'} // $img_h;

    if (defined $o->{'image-x'} || defined $o->{'image-y'}
        || defined $o->{'image-w'} || defined $o->{'image-h'}) {
        printf "Image region: (%d,%d) %dx%d within %dx%d image\n",
            $proj_args{image_x}, $proj_args{image_y},
            $proj_args{image_w}, $proj_args{image_h},
            $img_w, $img_h;
    } else {
        printf "Image region: full image (%dx%d)\n", $img_w, $img_h;
    }

    my $proj = Saros::Projection->new(%proj_args);

    # Draw graticule if no background image
    unless ($o->{'map-bg'} && -e $o->{'map-bg'}) {
        my $grid = $img->colorAllocate(51, 51, 85);
        _draw_graticule($img, $proj, $grid, $o->{projection});
    }

    # Plot points
    my $blue = $img->colorAllocate(0, 170, 255);
    my $plotted = 0;

    for my $pt (@$points) {
        my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
        next unless defined $x && defined $y;
        next if $x < 0 || $x > $img_w || $y < 0 || $y > $img_h;
        for my $s (1, 3, 5) {
            $img->arc($x, $y, $s, $s, 0, 360, $blue);
        }
        $plotted++;
    }

    # Save
    my $fmt = lc($o->{'map-fmt'});
    $fmt = 'png' unless $fmt =~ /^(png|jpg)$/;

    open my $fh, '>', $o->{map}
        or die "ERROR: Cannot write $o->{map}: $!\n";
    binmode $fh;
    print $fh ($fmt eq 'jpg' ? $img->jpeg(85) : $img->png);
    close $fh;

    printf "Map saved: %s (%s, %d points plotted)\n", $o->{map}, $fmt, $plotted;
}

sub _draw_graticule {
    my ($img, $proj, $color, $proj_type) = @_;

    if ($proj_type eq 'azimuthal_equidistant') {
        # Concentric latitude circles
        for my $lat (-75, -60, -45, -30, -15, 0, 15, 30, 45, 60, 75) {
            my @pts;
            for (my $lon = 0; $lon < 360; $lon += 2) {
                my ($x, $y) = $proj->project($lat, $lon);
                push @pts, $x, $y if defined $x;
            }
            if (@pts >= 4) {
                # Close the circle
                push @pts, $pts[0], $pts[1];
                _draw_polyline($img, \@pts, $color);
            }
        }
        # Meridians
        for (my $lon = 0; $lon < 360; $lon += 30) {
            my @pts;
            for (my $lat = -89; $lat <= 89; $lat += 2) {
                my ($x, $y) = $proj->project($lat, $lon);
                push @pts, $x, $y if defined $x;
            }
            _draw_polyline($img, \@pts, $color) if @pts >= 4;
        }
    } else {
        # Mercator: horizontal latitude lines
        for my $lat (-60, -30, 0, 30, 60) {
            my ($x1, $y1) = $proj->project($lat, -179);
            my ($x2, $y2) = $proj->project($lat,  179);
            $img->line($x1, $y1, $x2, $y2, $color)
                if defined $y1 && defined $y2;
        }
        # Vertical meridians
        for (my $lon = -180; $lon <= 180; $lon += 30) {
            my @pts;
            for (my $lat = -79; $lat <= 79; $lat += 2) {
                my ($x, $y) = $proj->project($lat, $lon);
                push @pts, $x, $y if defined $x;
            }
            _draw_polyline($img, \@pts, $color) if @pts >= 4;
        }
    }
}

sub _draw_polyline {
    my ($img, $pts, $color) = @_;
    for (my $i = 0; $i < $#$pts - 1; $i += 2) {
        $img->line($pts->[$i], $pts->[$i+1],
                   $pts->[$i+2], $pts->[$i+3], $color);
    }
}

sub usage {
    print <<'USAGE';
Usage: saros_cli.pl --from YEAR --to YEAR [options]

Required:
  --from YEAR             Start year
  --to YEAR               End year

Computation:
  --no-delta-t            Disable ΔT correction
  --sphere                Use spherical Earth (default: WGS84)

Map image output (requires GD):
  --map FILE              Output image path (enables image generation)
  --map-bg FILE           Background map image (JPEG)
  --map-fmt png|jpg       Output format (default: png)
  --width N               Canvas width in pixels  (when no --map-bg)
  --height N              Canvas height in pixels (when no --map-bg)

Projection:
  --projection TYPE       mercator (default) or azimuthal_equidistant

Mercator extent (degrees):
  --extent-west  DEG      West longitude  (default: -180)
  --extent-east  DEG      East longitude  (default:  180)
  --extent-north DEG      North latitude  (default:   80)
  --extent-south DEG      South latitude  (default:  -80)

Azimuthal equidistant extent (degrees):
  --center-lat DEG        Center latitude  (default: 90, North Pole)
  --center-lon DEG        Center longitude (default: 0)
  --extent-radius DEG     Angular radius   (default: 180, full globe)

Image region (pixels — area within image the map covers):
  --image-x N             Left edge of map region   (default: 0)
  --image-y N             Top edge of map region    (default: 0)
  --image-w N             Map region width          (default: image width)
  --image-h N             Map region height         (default: image height)

Examples:
  # Text output only
  saros_cli.pl --from 2024 --to 2026

  # Plot on a custom Mercator world map
  saros_cli.pl --from 2024 --to 2026 \
    --map eclipse_2024.png \
    --map-bg /path/to/world_mercator.jpg \
    --extent-west -180 --extent-east 180 \
    --extent-north 85 --extent-south -85

  # Azimuthal equidistant, northern hemisphere only, no bg image
  saros_cli.pl --from 2024 --to 2026 \
    --map eclipse_az.png \
    --projection azimuthal_equidistant \
    --center-lat 90 --extent-radius 90 \
    --width 800 --height 800

  # Map image has 40px border on all sides
  saros_cli.pl --from 2024 --to 2024 \
    --map out.png --map-bg mymap.jpg \
    --image-x 40 --image-y 40 \
    --image-w 720 --image-h 520

  # Sphere model, no ΔT, compare with WGS84
  saros_cli.pl --from 2024 --to 2024 --sphere --no-delta-t
USAGE
    exit 1;
}
