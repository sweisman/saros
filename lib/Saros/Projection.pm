package Saros::Projection;

use strict;
use warnings;
use Math::Trig qw(acos asin deg2rad rad2deg pi tan);
use POSIX qw(floor);

# Constructor
# Args:
#   type       => 'mercator' | 'azimuthal_equidistant'
#   width      => pixel width of image/canvas
#   height     => pixel height of image/canvas
#
# Extent (the geographic area the image covers):
#   For Mercator:
#     extent_west, extent_east   => longitude bounds (degrees, default -180/180)
#     extent_north, extent_south => latitude bounds (degrees, default 80/-80)
#   For Azimuthal Equidistant:
#     center_lat, center_lon     => projection center (default 90, 0)
#     extent_radius              => angular radius in degrees (default 180 = full globe)
#
# Image region (pixel area within the image that the extent maps to):
#   image_x, image_y            => top-left pixel of the map region (default 0, 0)
#   image_w, image_h            => pixel dimensions of the map region (default = width, height)
#
sub new {
    my ($class, %o) = @_;
    my $self = bless {
        type   => $o{type}   // 'mercator',
        width  => $o{width}  // 540,
        height => $o{height} // 420,

        # Mercator extent
        extent_west  => $o{extent_west}  // -180,
        extent_east  => $o{extent_east}  //  180,
        extent_north => $o{extent_north} //   80,
        extent_south => $o{extent_south} //  -80,

        # Azimuthal equidistant extent
        center_lat    => $o{center_lat}    // 90,
        center_lon    => $o{center_lon}    // 0,
        extent_radius => $o{extent_radius} // 180,

        # Image region (sub-rectangle of image that is the map)
        image_x => $o{image_x} // 0,
        image_y => $o{image_y} // 0,
        image_w => $o{image_w},  # undef = use full width
        image_h => $o{image_h},  # undef = use full height
    }, $class;

    $self->{image_w} //= $self->{width};
    $self->{image_h} //= $self->{height};

    return $self;
}

# Update pixel dimensions (e.g. after loading an image)
sub set_dimensions {
    my ($self, $w, $h) = @_;
    my $old_w = $self->{width};
    my $old_h = $self->{height};
    $self->{width}  = $w;
    $self->{height} = $h;
    # Scale image region proportionally if it was full-image
    if ($self->{image_w} == $old_w && $self->{image_h} == $old_h
        && $self->{image_x} == 0 && $self->{image_y} == 0) {
        $self->{image_w} = $w;
        $self->{image_h} = $h;
    }
    return $self;
}

sub width  { $_[0]->{width}  }
sub height { $_[0]->{height} }

# Project (lat, lon) in degrees → (x, y) pixel coordinates
# Returns (undef, undef) if point is outside the map extent
sub project {
    my ($self, $lat, $lon) = @_;
    if ($self->{type} eq 'azimuthal_equidistant') {
        return $self->_azimuthal_equidistant($lat, $lon);
    }
    return $self->_mercator($lat, $lon);
}

# Inverse: (x, y) pixel → (lat, lon) degrees
sub inverse {
    my ($self, $x, $y) = @_;
    if ($self->{type} eq 'azimuthal_equidistant') {
        return $self->_azimuthal_equidistant_inv($x, $y);
    }
    return $self->_mercator_inv($x, $y);
}

# ── Mercator ──────────────────────────────────────────────

sub _mercator {
    my ($self, $lat, $lon) = @_;
    my $s = $self;

    # Check latitude bounds
    return (undef, undef) if $lat >= $s->{extent_north} || $lat <= $s->{extent_south};

    # Normalize longitude into extent range
    $lon = _normalize_lon($lon);
    my $w = $s->{extent_west};
    my $e = $s->{extent_east};
    # Handle wrapping (e.g. extent_west=170, extent_east=-170 crossing dateline)
    my $lon_span = $e - $w;
    $lon_span += 360 if $lon_span <= 0;
    my $lon_off = $lon - $w;
    $lon_off += 360 if $lon_off < 0;
    return (undef, undef) if $lon_off > $lon_span;

    # Mercator Y for the extent bounds and the point
    my $merc_n = log(tan(pi / 4 + deg2rad($s->{extent_north}) / 2));
    my $merc_s = log(tan(pi / 4 + deg2rad($s->{extent_south}) / 2));
    my $merc_y = log(tan(pi / 4 + deg2rad($lat) / 2));

    # Map to image region pixels
    my $x = $s->{image_x} + ($lon_off / $lon_span) * $s->{image_w};
    my $y = $s->{image_y} + (($merc_n - $merc_y) / ($merc_n - $merc_s)) * $s->{image_h};

    return ($x, $y);
}

sub _mercator_inv {
    my ($self, $x, $y) = @_;
    my $s = $self;

    # Pixel to normalized [0,1] within image region
    my $fx = ($x - $s->{image_x}) / $s->{image_w};
    my $fy = ($y - $s->{image_y}) / $s->{image_h};
    return (undef, undef) if $fx < 0 || $fx > 1 || $fy < 0 || $fy > 1;

    my $lon_span = $s->{extent_east} - $s->{extent_west};
    $lon_span += 360 if $lon_span <= 0;
    my $lon = $s->{extent_west} + $fx * $lon_span;
    $lon = _normalize_lon($lon);

    my $merc_n = log(tan(pi / 4 + deg2rad($s->{extent_north}) / 2));
    my $merc_s = log(tan(pi / 4 + deg2rad($s->{extent_south}) / 2));
    my $merc_y = $merc_n - $fy * ($merc_n - $merc_s);
    my $lat = rad2deg(2 * atan(exp($merc_y)) - pi / 2);

    return ($lat, $lon);
}

# ── Azimuthal Equidistant ─────────────────────────────────

sub _azimuthal_equidistant {
    my ($self, $lat, $lon) = @_;
    my $s = $self;

    my $phi1 = deg2rad($s->{center_lat});
    my $lam0 = deg2rad($s->{center_lon});
    my $phi  = deg2rad($lat);
    my $dlam = deg2rad($lon) - $lam0;

    my $cos_c = sin($phi1) * sin($phi)
              + cos($phi1) * cos($phi) * cos($dlam);
    $cos_c =  1.0 if $cos_c >  1.0;
    $cos_c = -1.0 if $cos_c < -1.0;
    my $c = acos($cos_c);

    # Outside the configured angular extent
    return (undef, undef) if rad2deg($c) > $s->{extent_radius};

    my ($kp_x, $kp_y);
    if ($c == 0) {
        $kp_x = 0;
        $kp_y = 0;
    } else {
        my $k = $c / sin($c);
        $kp_x = $k * cos($phi) * sin($dlam);
        $kp_y = $k * (cos($phi1) * sin($phi)
                     - sin($phi1) * cos($phi) * cos($dlam));
    }

    # Scale: extent_radius maps to half the smaller image region dimension
    my $max_c = deg2rad($s->{extent_radius});
    my $half = ($s->{image_w} < $s->{image_h} ? $s->{image_w} : $s->{image_h}) / 2;
    my $scale = $half / $max_c;

    my $cx = $s->{image_x} + $s->{image_w} / 2;
    my $cy = $s->{image_y} + $s->{image_h} / 2;

    return ($cx - $kp_x * $scale, $cy - $kp_y * $scale);
}

sub _azimuthal_equidistant_inv {
    my ($self, $x, $y) = @_;
    my $s = $self;

    my $max_c = deg2rad($s->{extent_radius});
    my $half = ($s->{image_w} < $s->{image_h} ? $s->{image_w} : $s->{image_h}) / 2;
    my $scale = $half / $max_c;

    my $cx = $s->{image_x} + $s->{image_w} / 2;
    my $cy = $s->{image_y} + $s->{image_h} / 2;

    my $kp_x = ($cx - $x) / $scale;
    my $kp_y = ($cy - $y) / $scale;

    my $rho = sqrt($kp_x * $kp_x + $kp_y * $kp_y);
    return (undef, undef) if $rho > $max_c;
    return ($self->{center_lat}, $self->{center_lon}) if $rho == 0;

    my $c = $rho;
    my $phi1 = deg2rad($s->{center_lat});
    my $lam0 = deg2rad($s->{center_lon});

    my $lat = asin(cos($c) * sin($phi1)
                 + ($kp_y * sin($c) * cos($phi1)) / $rho);
    my $lon = $lam0 + atan2(
        $kp_x * sin($c),
        $rho * cos($phi1) * cos($c) - $kp_y * sin($phi1) * sin($c)
    );

    return (rad2deg($lat), rad2deg($lon));
}

# ── Helpers ───────────────────────────────────────────────

sub _normalize_lon {
    my ($lon) = @_;
    while ($lon >  180) { $lon -= 360 }
    while ($lon < -180) { $lon += 360 }
    return $lon;
}

sub type { $_[0]->{type} }

# Return current extent as a hash (for serialization / display)
sub extent {
    my ($self) = @_;
    if ($self->{type} eq 'azimuthal_equidistant') {
        return (
            center_lat    => $self->{center_lat},
            center_lon    => $self->{center_lon},
            extent_radius => $self->{extent_radius},
            image_x       => $self->{image_x},
            image_y       => $self->{image_y},
            image_w       => $self->{image_w},
            image_h       => $self->{image_h},
        );
    }
    return (
        extent_west  => $self->{extent_west},
        extent_east  => $self->{extent_east},
        extent_north => $self->{extent_north},
        extent_south => $self->{extent_south},
        image_x      => $self->{image_x},
        image_y      => $self->{image_y},
        image_w      => $self->{image_w},
        image_h      => $self->{image_h},
    );
}

1;

__END__

=head1 NAME

Saros::Projection - Map projections with configurable extents

=head1 SYNOPSIS

    use Saros::Projection;

    # Mercator with custom extent — image covers only Europe
    my $proj = Saros::Projection->new(
        type         => 'mercator',
        width        => 1200,       # full image pixel width
        height       => 900,        # full image pixel height
        extent_west  => -25,        # westernmost longitude on image
        extent_east  => 45,         # easternmost longitude on image
        extent_north => 72,         # northernmost latitude on image
        extent_south => 34,         # southernmost latitude on image
        # optional: if the map doesn't fill the whole image
        image_x      => 50,         # left edge of map area in pixels
        image_y      => 30,         # top edge of map area in pixels
        image_w      => 1100,       # map area width in pixels
        image_h      => 840,        # map area height in pixels
    );

    my ($x, $y) = $proj->project(51.5, -0.1);  # London

    # Azimuthal equidistant — hemisphere only
    my $ae = Saros::Projection->new(
        type          => 'azimuthal_equidistant',
        width         => 800,
        height        => 800,
        center_lat    => 90,
        center_lon    => 0,
        extent_radius => 90,   # only show northern hemisphere
    );

=head1 DESCRIPTION

Map projection with full control over which geographic area the
image represents. Defaults to full-globe coverage matching the
image dimensions, so it works out of the box with no configuration.

=head2 Extent Parameters

B<Mercator:>
extent_west, extent_east, extent_north, extent_south define the
geographic bounding box. Default: -180, 180, 80, -80.

B<Azimuthal Equidistant:>
center_lat, center_lon set the projection center. extent_radius
sets the angular radius in degrees. Default: North Pole, 180°
(full globe).

B<Image region:>
image_x, image_y, image_w, image_h define which pixel rectangle
within the image the map extent maps onto. Default: the entire image.
Use this when your image has borders, labels, or legends outside
the map area.

=cut
