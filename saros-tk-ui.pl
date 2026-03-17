#!/usr/bin/perl
# ============================================================
# Saros - Solar Eclipse Calculator (Tk GUI)
# Refactored from original by Sebastian Harl (2003-2004)
# ============================================================

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/lib";

use Tk;

use Saros::Engine;
use Saros::Projection;
use Saros::Calendar qw(chopdigits);

# ── Configuration ─────────────────────────────────────────

my $VERSION = "2.0";
my $WORLDMAP = $ENV{SAROS_WORLDMAP}
    // "$RealBin/world.jpg";
my $AZMAP = $ENV{SAROS_AZMAP} // "$RealBin/azimuthal-map.jpg";

my $HAS_JPEG = eval { require Tk::JPEG; 1 } // 0;
my $HAS_GD   = eval { require GD; 1 }       // 0;

# ── Color palette for eclipse paths ──────────────────────

my @PATH_COLORS = (
    '#ff0033',  # neon red
    '#ff00ff',  # magenta
    '#ffffff',  # white
    '#ff6600',  # neon orange
    '#cc00ff',  # purple
    '#ffff00',  # neon yellow
    '#ff0099',  # hot pink
    '#00ff66',  # neon green
    '#3300ff',  # electric blue
    '#ff3399',  # rose
    '#9900ff',  # violet
    '#00ffcc',  # neon mint
);

# ── State ─────────────────────────────────────────────────

my $engine = Saros::Engine->new(use_delta_t => 1, earth_model => 'wgs84');
my $projection_type = 'azimuthal_equidistant';
my $current_year = (localtime)[5] + 1900;
my ($from_year, $to_year) = ($current_year, $current_year + 1);
my @eclipse_candidates;     # { nm => ..., number => N, color => ..., plotted => 0|1, central_line => [...] }
my $map_photo;              # keep Tk Photo alive for canvas
my $status_msg = "Enter a year range and click Calculate.";
my $show_sun_path = 0;

# Map extent overrides (empty = use defaults)
my %extent = (
    merc_west  => '', merc_east  => '',
    merc_north => '', merc_south => '',
    az_center_lat => '90', az_center_lon => '0',
    az_radius     => '180',
    az_img_x => '62', az_img_y => '402', az_img_w => '1116', az_img_h => '1116',
    merc_img_x => '', merc_img_y => '', merc_img_w => '', merc_img_h => '',
);

# ── Main Window ───────────────────────────────────────────

my $mw = MainWindow->new(-title => "Saros $VERSION - Solar Eclipse Calculator");
$mw->attributes('-zoomed', 1);
$mw->protocol('WM_DELETE_WINDOW', sub { $mw->destroy; exit 0 });

# ── Menu ──────────────────────────────────────────────────

my $mb = $mw->Menu;
$mw->configure(-menu => $mb);

my $file_menu = $mb->cascade(-label => 'File', -tearoff => 0);
if ($HAS_GD) {
    my $img_menu = $file_menu->cascade(-label => 'Save Map Image', -tearoff => 0);
    $img_menu->command(-label => 'As JPEG...', -command => sub { save_image('jpg') });
    $img_menu->command(-label => 'As PNG...',  -command => sub { save_image('png') });
}
$file_menu->command(-label => 'Save Eclipse List...', -command => \&save_eclipse_list);
$file_menu->separator;
$file_menu->command(-label => 'Quit', -command => sub { $mw->destroy; exit 0 },
    -accelerator => 'Ctrl+Q');

my $settings_menu = $mb->cascade(-label => 'Settings', -tearoff => 0);
my $proj_menu = $settings_menu->cascade(-label => 'Projection', -tearoff => 0);
$proj_menu->radiobutton(-label => 'Mercator',
    -variable => \$projection_type, -value => 'mercator',
    -command => \&redraw_map);
$proj_menu->radiobutton(-label => 'Azimuthal Equidistant',
    -variable => \$projection_type, -value => 'azimuthal_equidistant',
    -command => \&redraw_map);
$settings_menu->command(-label => 'Map Extent...', -command => \&edit_extent);

my $help_menu = $mb->cascade(-label => 'Help', -tearoff => 0);
$help_menu->command(-label => 'About Saros', -command => \&show_about);

# ── Keybindings ───────────────────────────────────────────

$mw->bind('<Control-Key-q>' => sub { $mw->destroy; exit 0 });
$mw->bind('<Return>' => \&do_calculate);

# ── Layout ────────────────────────────────────────────────
# Structure:
#   Row 0: input bar (year range, calculate, options)
#   Row 1: [eclipse checkbox list | map canvas] (main area, expands)
#   Row 2: status bar

# -- Row 0: Input bar
my $input_f = $mw->Frame(-borderwidth => 1, -relief => 'groove');
$input_f->grid('-', -sticky => 'ew', -padx => 0, -pady => 0);

$input_f->Label(-text => 'From:')->pack(-side => 'left', -padx => [10, 4], -pady => 8);
$input_f->Entry(-textvariable => \$from_year, -width => 6)
    ->pack(-side => 'left', -pady => 8);
$input_f->Label(-text => 'To:')->pack(-side => 'left', -padx => [10, 4], -pady => 8);
$input_f->Entry(-textvariable => \$to_year, -width => 6)
    ->pack(-side => 'left', -pady => 8);
$input_f->Button(-text => 'Calculate', -command => \&do_calculate)
    ->pack(-side => 'left', -padx => 12, -pady => 8);

$input_f->Frame(-width => 1, -background => '#999999', -relief => 'flat')
    ->pack(-side => 'left', -fill => 'y', -padx => 6, -pady => 6);

$input_f->Checkbutton(-text => "Sun path", -variable => \$show_sun_path,
    -command => \&redraw_map)
    ->pack(-side => 'left', -padx => 6, -pady => 8);

# -- Row 1: Main area (eclipse list + map)
my $main_f = $mw->Frame;
$main_f->grid('-', -sticky => 'nsew', -padx => 0, -pady => 0);

# Eclipse checkbox list (left side of main area)
my $list_f = $main_f->Frame(-borderwidth => 1, -relief => 'groove');
$list_f->pack(-side => 'left', -fill => 'y', -padx => 0, -pady => 0);

my $list_header_f = $list_f->Frame->pack(-fill => 'x', -pady => [4, 0]);
$list_header_f->Label(-text => 'Eclipses', -font => ['sans', 9, 'bold'])
    ->pack(-side => 'left', -padx => [8, 0]);

my $btn_f = $list_header_f->Frame->pack(-side => 'right', -padx => 4);
$btn_f->Button(-text => 'All', -font => ['sans', 7], -padx => 3, -pady => 0,
    -command => \&select_all_eclipses)->pack(-side => 'left', -padx => 1);
$btn_f->Button(-text => 'None', -font => ['sans', 7], -padx => 3, -pady => 0,
    -command => \&deselect_all_eclipses)->pack(-side => 'left', -padx => 1);

# Scrollable frame for checkboxes using Canvas + Frame pattern
my $cb_canvas = $list_f->Canvas(-width => 170, -highlightthickness => 0);
my $cb_scrollbar = $list_f->Scrollbar(-orient => 'vertical', -command => ['yview', $cb_canvas]);
$cb_canvas->configure(-yscrollcommand => ['set', $cb_scrollbar]);
$cb_scrollbar->pack(-side => 'right', -fill => 'y', -pady => [0, 4]);
$cb_canvas->pack(-side => 'left', -expand => 1, -fill => 'both', -padx => 4, -pady => [0, 4]);

my $cb_frame = $cb_canvas->Frame;
$cb_canvas->createWindow(0, 0, -window => $cb_frame, -anchor => 'nw', -tags => 'cb_win');
$cb_frame->bind('<Configure>' => sub {
    $cb_canvas->configure(-scrollregion => [$cb_canvas->bbox('all')]);
});

# Map canvas (right side of main area, scrollable for large images)
my $map_f = $main_f->Frame(-borderwidth => 1, -relief => 'sunken');
$map_f->pack(-side => 'left', -expand => 1, -fill => 'both', -padx => 0, -pady => 0);

my $map_canvas = $map_f->Scrolled('Canvas',
    -scrollbars => 'osoe',
    -background => '#1a1a2e',
)->pack(-expand => 1, -fill => 'both');
my $map_canvas_inner = $map_canvas->Subwidget('scrolled');

# Rescale map when canvas resizes
$map_canvas_inner->bind('<Configure>' => sub { redraw_map() });

# -- Row 2: Status bar
my $status_f = $mw->Frame(-borderwidth => 0);
$status_f->grid('-', -sticky => 'ew', -padx => 0, -pady => 0);

$status_f->Label(
    -anchor => 'w', -textvariable => \$status_msg,
    -padx => 8, -font => ['sans', 8], -relief => 'sunken',
)->pack(-expand => 1, -fill => 'x');

# Grid weights: main area expands vertically
$mw->gridRowconfigure(0, -weight => 0);
$mw->gridRowconfigure(1, -weight => 1);
$mw->gridRowconfigure(2, -weight => 0);
$mw->gridColumnconfigure(0, -weight => 1);

# ── Initialize map ────────────────────────────────────────

# ── Initialize: draw map and calculate default range ──────

draw_map_background();
do_calculate();

# ── Run ───────────────────────────────────────────────────

MainLoop;

# ══════════════════════════════════════════════════════════
# Callbacks
# ══════════════════════════════════════════════════════════

sub _rebuild_engine {
    $engine = Saros::Engine->new(
        use_delta_t => 1,
        earth_model => 'wgs84',
    );
}

sub do_calculate {
    unless (defined $from_year && defined $to_year
            && $from_year =~ /^-?\d+$/ && $to_year =~ /^-?\d+$/) {
        $status_msg = "Please enter valid year numbers.";
        return;
    }
    if ($to_year < $from_year) {
        $status_msg = "Error: 'From' year must be <= 'To' year.";
        return;
    }

    # Clear old checkboxes
    for my $child ($cb_frame->children) {
        $child->destroy;
    }
    @eclipse_candidates = ();

    $status_msg = "Calculating new moons $from_year-$to_year...";
    $mw->update;

    my $all = $engine->find_new_moons($from_year * 1, $to_year * 1);

    my $eclipse_num = 0;
    my $partial_count = 0;
    for my $nm (@$all) {
        next unless $nm->{eclipse_possible};
        my $date = sprintf("%d-%02d-%02d", $nm->{year}, $nm->{month}, $nm->{day});
        $status_msg = "Checking $date...";
        $mw->update;
        if ($engine->has_central_line($nm)) {
            $eclipse_num++;
            my $color = $PATH_COLORS[($eclipse_num - 1) % scalar @PATH_COLORS];
            my $label = sprintf "%d-%02d-%02d", $nm->{year}, $nm->{month}, $nm->{day};
            push @eclipse_candidates, {
                nm           => $nm,
                number       => $eclipse_num,
                color        => $color,
                label        => $label,
                plotted      => 0,
                central_line => undef,
            };
        } else {
            $partial_count++;
        }
    }

    # Build checkbox list
    for my $ec (@eclipse_candidates) {
        my $f = $cb_frame->Frame->pack(-fill => 'x', -anchor => 'w');

        # Color swatch
        my $swatch = $f->Canvas(-width => 12, -height => 12,
            -highlightthickness => 0);
        $swatch->pack(-side => 'left', -padx => [4, 0], -pady => 1);
        $swatch->createRectangle(1, 1, 12, 12, -fill => $ec->{color}, -outline => '');

        my $cb = $f->Checkbutton(
            -text     => sprintf("%2d  %s", $ec->{number}, $ec->{label}),
            -font     => ['monospace', 9],
            -anchor   => 'w',
            -command  => sub {
                $ec->{plotted} = $ec->{plotted} ? 0 : 1;
                on_checkbox_toggle($ec);
            },
        )->pack(-side => 'left', -padx => 2);
        $ec->{_cb} = $cb;  # keep reference for select_all/deselect_all
    }

    # Clear any cached computation from previous runs
    for my $ec (@eclipse_candidates) {
        $ec->{central_line} = undef;
        $ec->{sun_track} = undef;
    }

    draw_map_background();

    my $n = scalar @eclipse_candidates;
    $status_msg = "$n central eclipse(s) found" .
        ($partial_count ? ", $partial_count partial-only skipped. " : ". ") .
        ($n ? "Check boxes to plot paths." : "");
}

sub on_checkbox_toggle {
    my ($ec) = @_;
    if ($ec->{plotted} && !$ec->{central_line}) {
        $status_msg = "Computing central line for #$ec->{number} $ec->{label}...";
        $mw->update;
        $ec->{central_line} = $engine->calculate_central_line($ec->{nm});
        $ec->{sun_track} = $engine->calculate_subsolar_track($ec->{nm}, $ec->{central_line});
    }
    redraw_map();
}

sub select_all_eclipses {
    for my $ec (@eclipse_candidates) {
        $ec->{plotted} = 1;
        $ec->{_cb}->select if $ec->{_cb};
        on_checkbox_toggle($ec);
    }
}

sub deselect_all_eclipses {
    for my $ec (@eclipse_candidates) {
        $ec->{plotted} = 0;
        $ec->{_cb}->deselect if $ec->{_cb};
    }
    redraw_map();
}

# ── Map Drawing ───────────────────────────────────────────

my ($map_img_w, $map_img_h) = (540, 420);    # display dimensions (scaled to viewport)
my ($native_img_w, $native_img_h) = (540, 420);  # native image dimensions (for saving)
my $map_display_photo;  # scaled Photo for canvas display

sub _load_map_image {
    my $map_file = ($projection_type eq 'azimuthal_equidistant' && $AZMAP ne '')
        ? $AZMAP : $WORLDMAP;

    # Clean up old photos (avoid double-delete when display == native)
    if ($map_display_photo && $map_display_photo != $map_photo) {
        $map_display_photo->delete;
    }
    $map_display_photo = undef;
    $map_photo->delete if $map_photo;
    $map_photo = undef;

    if ($HAS_JPEG && defined($map_file) && -e $map_file) {
        eval {
            $map_photo = $mw->Photo(-format => 'jpeg', -file => $map_file);
            $native_img_w = $map_photo->width;
            $native_img_h = $map_photo->height;
        };
        if ($@ || !$native_img_w || !$native_img_h) {
            $map_photo = undef;
        }
    }

    # Defaults when no image
    $native_img_w ||= ($projection_type eq 'azimuthal_equidistant') ? 600 : 540;
    $native_img_h ||= ($projection_type eq 'azimuthal_equidistant') ? 600 : 420;

    # AE map: render at full native size, allow scrolling
    # Mercator: scale to fit viewport
    my $scale = 1.0;
    if ($projection_type ne 'azimuthal_equidistant') {
        $mw->update;  # ensure geometry is current
        my $vp_w = $map_canvas_inner->width  || 500;
        my $vp_h = $map_canvas_inner->height || 400;
        my $scale_x = $vp_w / $native_img_w;
        my $scale_y = $vp_h / $native_img_h;
        $scale = ($scale_x < $scale_y) ? $scale_x : $scale_y;
        $scale = 1.0 if $scale > 1.0;  # don't upscale
    }

    $map_img_w = int($native_img_w * $scale);
    $map_img_h = int($native_img_h * $scale);

    # Create scaled display photo if needed
    if ($map_photo && $scale < 1.0) {
        $map_display_photo = $mw->Photo;
        $map_display_photo->copy($map_photo,
            -subsample => int(1 / $scale + 0.5), int(1 / $scale + 0.5));
        $map_img_w = $map_display_photo->width;
        $map_img_h = $map_display_photo->height;
    } elsif ($map_photo) {
        $map_display_photo = $map_photo;
        $map_img_w = $native_img_w;
        $map_img_h = $native_img_h;
    }
}

sub draw_map_background {
    _load_map_image();

    my $c = $map_canvas_inner;
    $c->delete('all');
    $c->configure(-scrollregion => [0, 0, $map_img_w, $map_img_h]);

    if ($map_display_photo) {
        $c->createImage(0, 0, -anchor => 'nw', -image => $map_display_photo);
    } else {
        # Synthesize graticule on dark background
        $c->createRectangle(0, 0, $map_img_w, $map_img_h,
            -fill => '#1a1a2e', -outline => '');
        my $proj = _build_projection($map_img_w, $map_img_h);

        if ($projection_type eq 'azimuthal_equidistant') {
            for my $lat (-75, -60, -45, -30, -15, 0, 15, 30, 45, 60, 75) {
                my @pts;
                for (my $lon = 0; $lon < 362; $lon += 2) {
                    my ($x, $y) = $proj->project($lat, $lon);
                    push @pts, $x, $y if defined $x;
                }
                push @pts, $pts[0], $pts[1] if @pts >= 4;
                $c->createLine(@pts,
                    -fill => '#333355', -width => 1, -tags => 'grid') if @pts >= 4;
            }
            for (my $lon = 0; $lon < 360; $lon += 30) {
                my @pts;
                for (my $lat = -85; $lat <= 85; $lat += 5) {
                    my ($x, $y) = $proj->project($lat, $lon);
                    push @pts, $x, $y if defined $x;
                }
                $c->createLine(@pts,
                    -fill => '#333355', -width => 1, -tags => 'grid') if @pts >= 4;
            }
        } else {
            for my $lat (-60, -30, 0, 30, 60) {
                my ($x1, $y1) = $proj->project($lat, -180);
                my ($x2, $y2) = $proj->project($lat, 180);
                $c->createLine($x1, $y1, $x2, $y2,
                    -fill => '#333355', -tags => 'grid') if defined $y1;
            }
            for (my $lon = -180; $lon <= 180; $lon += 30) {
                my @pts;
                for (my $lat = -79; $lat <= 79; $lat += 5) {
                    my ($x, $y) = $proj->project($lat, $lon);
                    push @pts, $x, $y if defined $x;
                }
                $c->createLine(@pts,
                    -fill => '#333355', -width => 1, -tags => 'grid') if @pts >= 4;
            }
        }
    }
}

sub redraw_map {
    draw_map_background();

    my $c = $map_canvas_inner;
    my $proj = _build_projection($map_img_w, $map_img_h);

    my $plotted = 0;
    for my $ec (@eclipse_candidates) {
        next unless $ec->{plotted} && $ec->{central_line};
        _draw_eclipse_path($c, $proj, $ec);
        $plotted++;
    }

    # Draw all number badges last so they're on top
    for my $ec (@eclipse_candidates) {
        next unless $ec->{plotted} && $ec->{central_line};
        _draw_eclipse_badges($c, $proj, $ec);
    }

    $status_msg = "$plotted eclipse path(s) plotted." if $plotted;
}

sub _draw_eclipse_path {
    my ($c, $proj, $ec) = @_;
    my $color = $ec->{color};
    my $num   = $ec->{number};
    my @line  = @{$ec->{central_line}};

    my @line_pts;
    for my $pt (@line) {
        next unless $pt->{phase} eq 'central' && defined $pt->{geo_lon};
        my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
        next unless defined $x && defined $y;
        next if $x < 0 || $x > $map_img_w || $y < 0 || $y > $map_img_h;
        push @line_pts, $x, $y;
    }

    # Draw black outline then colored line on top
    if (@line_pts >= 4) {
        $c->createLine(@line_pts,
            -fill => '#000000', -width => 4,
            -smooth => 1, -tags => 'eclipse');
        $c->createLine(@line_pts,
            -fill => $color, -width => 2,
            -smooth => 1, -tags => 'eclipse');
    }

    # Draw dots on top
    for (my $i = 0; $i < @line_pts; $i += 2) {
        my ($x, $y) = ($line_pts[$i], $line_pts[$i+1]);
        $c->createOval($x-3, $y-3, $x+3, $y+3,
            -fill => $color, -outline => '#000000', -tags => 'eclipse');
    }

    # Draw subsolar track if enabled
    if ($show_sun_path && $ec->{sun_track}) {
        my @sun_pts;
        for my $pt (@{$ec->{sun_track}}) {
            my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
            next unless defined $x && defined $y;
            next if $x < 0 || $x > $map_img_w || $y < 0 || $y > $map_img_h;
            push @sun_pts, $x, $y;
        }
        if (@sun_pts >= 4) {
            $c->createLine(@sun_pts,
                -fill => '#000000', -width => 4, -dash => [4, 3],
                -tags => 'eclipse');
            $c->createLine(@sun_pts,
                -fill => $color, -width => 2, -dash => [4, 3],
                -tags => 'eclipse');
        }
    }
}

sub _draw_number_badge {
    my ($c, $x, $y, $num, $color) = @_;
    my $r = length("$num") > 1 ? 8 : 7;
    $c->createOval($x - $r, $y - $r, $x + $r, $y + $r,
        -fill => $color, -outline => '#000000', -width => 1, -tags => 'eclipse');
    $c->createText($x, $y,
        -text => "$num", -fill => '#000000',
        -font => ['sans', 7, 'bold'], -anchor => 'center', -tags => 'eclipse');
}

# Draw number badges at START of eclipse path and sun path (called in final pass)
sub _draw_eclipse_badges {
    my ($c, $proj, $ec) = @_;
    my $num   = $ec->{number};
    my $color = $ec->{color};

    # Badge at start of eclipse central line
    my @line = @{$ec->{central_line}};
    for my $pt (@line) {
        next unless $pt->{phase} eq 'central' && defined $pt->{geo_lon};
        my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
        next unless defined $x && defined $y;
        next if $x < 0 || $x > $map_img_w || $y < 0 || $y > $map_img_h;
        _draw_number_badge($c, $x, $y, $num, $color);
        last;
    }

    # Badge at start of sun path
    if ($show_sun_path && $ec->{sun_track}) {
        for my $pt (@{$ec->{sun_track}}) {
            my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
            next unless defined $x && defined $y;
            next if $x < 0 || $x > $map_img_w || $y < 0 || $y > $map_img_h;
            _draw_number_badge($c, $x, $y, $num, $color);
            last;
        }
    }
}

# ── Projection Builder ────────────────────────────────────

sub _build_projection {
    my ($img_w, $img_h) = @_;
    my %args = (type => $projection_type, width => $img_w, height => $img_h);

    if ($projection_type eq 'mercator') {
        $args{extent_west}  = $extent{merc_west}  if $extent{merc_west}  ne '';
        $args{extent_east}  = $extent{merc_east}  if $extent{merc_east}  ne '';
        $args{extent_north} = $extent{merc_north} if $extent{merc_north} ne '';
        $args{extent_south} = $extent{merc_south} if $extent{merc_south} ne '';
    } else {
        $args{center_lat}    = $extent{az_center_lat} if $extent{az_center_lat} ne '';
        $args{center_lon}    = $extent{az_center_lon} if $extent{az_center_lon} ne '';
        $args{extent_radius} = $extent{az_radius}     if $extent{az_radius}     ne '';
    }

    # Pick image region for current projection type
    my ($ix, $iy, $iw, $ih);
    if ($projection_type eq 'mercator') {
        $ix = $extent{merc_img_x}; $iy = $extent{merc_img_y};
        $iw = $extent{merc_img_w}; $ih = $extent{merc_img_h};
    } else {
        $ix = $extent{az_img_x}; $iy = $extent{az_img_y};
        $iw = $extent{az_img_w}; $ih = $extent{az_img_h};
    }

    # Image region values are calibrated to native image dimensions.
    # Scale uniformly when rendering at different size (e.g. display vs save).
    my $scale = 1;
    if ($native_img_w > 0 && $native_img_h > 0) {
        my $sx = $img_w / $native_img_w;
        my $sy = $img_h / $native_img_h;
        $scale = ($sx < $sy) ? $sx : $sy;
    }
    $args{image_x} = $ix * $scale if $ix ne '';
    $args{image_y} = $iy * $scale if $iy ne '';
    $args{image_w} = $iw * $scale if $iw ne '';
    $args{image_h} = $ih * $scale if $ih ne '';

    return Saros::Projection->new(%args);
}

# ── Extent Editor ─────────────────────────────────────────

sub edit_extent {
    my $dlg = $mw->Toplevel(-title => 'Map Extent Settings');
    $dlg->geometry('+' . ($mw->x + 60) . '+' . ($mw->y + 60));

    my $nb = $dlg->Frame->pack(-fill => 'both', -expand => 1, -padx => 10, -pady => 10);

    my $mf = $nb->Labelframe(-text => 'Mercator Extent (degrees)', -padx => 8, -pady => 5)
        ->pack(-fill => 'x', -pady => 5);
    _extent_row($mf, 'West longitude:',  \$extent{merc_west},  '-180');
    _extent_row($mf, 'East longitude:',  \$extent{merc_east},  '180');
    _extent_row($mf, 'North latitude:',  \$extent{merc_north}, '80');
    _extent_row($mf, 'South latitude:',  \$extent{merc_south}, '-80');

    my $af = $nb->Labelframe(-text => 'Azimuthal Equidistant (degrees)', -padx => 8, -pady => 5)
        ->pack(-fill => 'x', -pady => 5);
    _extent_row($af, 'Center latitude:',  \$extent{az_center_lat}, '90');
    _extent_row($af, 'Center longitude:', \$extent{az_center_lon}, '0');
    _extent_row($af, 'Angular radius:',   \$extent{az_radius},     '180');

    my $mrf = $nb->Labelframe(-text => 'Mercator Image Region (pixels, blank = full image)', -padx => 8, -pady => 5)
        ->pack(-fill => 'x', -pady => 5);
    _extent_row($mrf, 'Left (x):',   \$extent{merc_img_x}, '0');
    _extent_row($mrf, 'Top (y):',    \$extent{merc_img_y}, '0');
    _extent_row($mrf, 'Width:',      \$extent{merc_img_w}, 'image width');
    _extent_row($mrf, 'Height:',     \$extent{merc_img_h}, 'image height');

    my $arf = $nb->Labelframe(-text => 'AE Image Region (pixels, blank = full image)', -padx => 8, -pady => 5)
        ->pack(-fill => 'x', -pady => 5);
    _extent_row($arf, 'Left (x):',   \$extent{az_img_x}, '114');
    _extent_row($arf, 'Top (y):',    \$extent{az_img_y}, '276');
    _extent_row($arf, 'Width:',      \$extent{az_img_w}, '528');
    _extent_row($arf, 'Height:',     \$extent{az_img_h}, '528');

    my $bf = $nb->Frame->pack(-fill => 'x', -pady => 8);
    $bf->Button(-text => 'Reset Defaults', -command => sub {
        $extent{$_} = '' for keys %extent;
    })->pack(-side => 'left', -padx => 5);
    $bf->Button(-text => 'Apply & Redraw', -command => sub {
        redraw_map();
    })->pack(-side => 'left', -padx => 5);
    $bf->Button(-text => 'Close', -command => sub { $dlg->destroy })
        ->pack(-side => 'right', -padx => 5);
}

sub _extent_row {
    my ($parent, $label, $varref, $placeholder) = @_;
    my $f = $parent->Frame->pack(-fill => 'x', -pady => 2);
    $f->Label(-text => $label, -width => 20, -anchor => 'w')
        ->pack(-side => 'left');
    $f->Entry(-textvariable => $varref, -width => 12)
        ->pack(-side => 'left', -padx => 5);
    $f->Label(-text => "(default: $placeholder)", -foreground => '#666666')
        ->pack(-side => 'left');
}

# ── Save Image ────────────────────────────────────────────

sub save_image {
    my ($type) = @_;
    unless ($HAS_GD) {
        $status_msg = "GD module not available - cannot export images.";
        return;
    }

    # Check if anything is plotted
    my @plotted = grep { $_->{plotted} && $_->{central_line} } @eclipse_candidates;
    unless (@plotted) {
        $status_msg = "No eclipse paths to save. Check some boxes first.";
        return;
    }

    my $file = $mw->getSaveFile(
        -defaultextension => ".$type",
        -filetypes => [[uc($type), ".$type"]],
    );
    return unless $file;

    my $map_file = ($projection_type eq 'azimuthal_equidistant' && $AZMAP ne '')
        ? $AZMAP : $WORLDMAP;

    my ($img, $img_w, $img_h);
    if (defined($map_file) && -e $map_file) {
        open my $fh, '<', $map_file or do {
            $status_msg = "Cannot open $map_file: $!";
            return;
        };
        $img = GD::Image->newFromJpeg($fh);
        close $fh;
        ($img_w, $img_h) = $img->getBounds;
    } else {
        $img_w = ($projection_type eq 'azimuthal_equidistant') ? 600 : 540;
        $img_h = ($projection_type eq 'azimuthal_equidistant') ? 600 : 420;
        $img = GD::Image->new($img_w, $img_h);
        $img->colorAllocate(26, 26, 46);
    }

    my $proj = _build_projection($img_w, $img_h);

    for my $ec (@plotted) {
        _draw_eclipse_path_gd($img, $img_w, $img_h, $proj, $ec);
    }

    # Draw all number badges last so they're on top, at START of paths
    for my $ec (@plotted) {
        _draw_eclipse_badges_gd($img, $img_w, $img_h, $proj, $ec);
    }

    open my $fh, '>', $file or do {
        $status_msg = "Cannot save $file: $!";
        return;
    };
    binmode $fh;
    print $fh ($type eq 'jpg' ? $img->jpeg(85) : $img->png);
    close $fh;
    $status_msg = "Saved " . scalar(@plotted) . " path(s): $file";
}

sub _hex_to_rgb {
    my ($hex) = @_;
    $hex =~ s/^#//;
    return (hex(substr($hex,0,2)), hex(substr($hex,2,2)), hex(substr($hex,4,2)));
}

sub _draw_eclipse_path_gd {
    my ($img, $img_w, $img_h, $proj, $ec) = @_;
    my @rgb   = _hex_to_rgb($ec->{color});
    my $color = $img->colorAllocate(@rgb);
    my $white = $img->colorResolve(255, 255, 255);
    my $num   = $ec->{number};

    my @pts;
    for my $pt (@{$ec->{central_line}}) {
        next unless $pt->{phase} eq 'central' && defined $pt->{geo_lon};
        my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
        next unless defined $x && defined $y;
        next if $x < 0 || $x > $img_w || $y < 0 || $y > $img_h;
        push @pts, [$x, $y];
    }

    my $black = $img->colorResolve(0, 0, 0);

    # Draw black outline then colored line
    for my $i (1 .. $#pts) {
        $img->setThickness(4);
        $img->line($pts[$i-1][0], $pts[$i-1][1],
                   $pts[$i][0],   $pts[$i][1], $black);
        $img->setThickness(2);
        $img->line($pts[$i-1][0], $pts[$i-1][1],
                   $pts[$i][0],   $pts[$i][1], $color);
    }
    $img->setThickness(1);

    # Draw dots
    for my $pt (@pts) {
        $img->filledArc($pt->[0], $pt->[1], 7, 7, 0, 360, $black);
        $img->filledArc($pt->[0], $pt->[1], 5, 5, 0, 360, $color);
    }

    # Subsolar track
    if ($show_sun_path && $ec->{sun_track}) {
        my @spts;
        for my $pt (@{$ec->{sun_track}}) {
            my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
            next unless defined $x && defined $y;
            next if $x < 0 || $x > $img_w || $y < 0 || $y > $img_h;
            push @spts, [$x, $y];
        }
        # Dashed line with black outline: draw every other segment
        for my $i (1 .. $#spts) {
            next if $i % 2 == 0;
            $img->setThickness(4);
            $img->line($spts[$i-1][0], $spts[$i-1][1],
                       $spts[$i][0],   $spts[$i][1], $black);
            $img->setThickness(2);
            $img->line($spts[$i-1][0], $spts[$i-1][1],
                       $spts[$i][0],   $spts[$i][1], $color);
        }
        $img->setThickness(1);
    }
}

sub _draw_number_badge_gd {
    my ($img, $x, $y, $num, $color, $black) = @_;
    my $r = length("$num") > 1 ? 10 : 8;
    $img->filledArc($x, $y, $r*2, $r*2, 0, 360, $color);
    $img->arc($x, $y, $r*2, $r*2, 0, 360, $black);
    my $font = GD::gdSmallFont();
    my $tw = $font->width * length("$num");
    my $th = $font->height;
    $img->string($font, $x - int($tw/2), $y - int($th/2), "$num", $black);
}

# Draw number badges at START of eclipse path and sun path (GD, called in final pass)
sub _draw_eclipse_badges_gd {
    my ($img, $img_w, $img_h, $proj, $ec) = @_;
    my @rgb   = _hex_to_rgb($ec->{color});
    my $color = $img->colorResolve(@rgb);
    my $black = $img->colorResolve(0, 0, 0);
    my $num   = $ec->{number};

    # Badge at start of eclipse central line
    for my $pt (@{$ec->{central_line}}) {
        next unless $pt->{phase} eq 'central' && defined $pt->{geo_lon};
        my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
        next unless defined $x && defined $y;
        next if $x < 0 || $x > $img_w || $y < 0 || $y > $img_h;
        _draw_number_badge_gd($img, $x, $y, $num, $color, $black);
        last;
    }

    # Badge at start of sun path
    if ($show_sun_path && $ec->{sun_track}) {
        for my $pt (@{$ec->{sun_track}}) {
            my ($x, $y) = $proj->project($pt->{geo_lat}, $pt->{geo_lon});
            next unless defined $x && defined $y;
            next if $x < 0 || $x > $img_w || $y < 0 || $y > $img_h;
            _draw_number_badge_gd($img, $x, $y, $num, $color, $black);
            last;
        }
    }
}

# ── Save Eclipse List ─────────────────────────────────────

sub save_eclipse_list {
    unless (@eclipse_candidates) {
        $status_msg = "No eclipses to save.";
        return;
    }

    my $file = $mw->getSaveFile(
        -defaultextension => '.txt',
        -filetypes => [['Text files', '.txt'], ['All files', '*']],
    );
    return unless $file;

    open my $fh, '>', $file or do {
        $status_msg = "Cannot save $file: $!";
        return;
    };

    printf $fh "Saros %s - Eclipse List (%s to %s)\n\n", $VERSION, $from_year, $to_year;
    printf $fh "%4s  %-12s  %s\n", '#', 'Date', 'Plotted';
    printf $fh "%s\n", '-' x 28;

    for my $ec (@eclipse_candidates) {
        printf $fh "%4d  %-12s  %s\n",
            $ec->{number}, $ec->{label},
            $ec->{plotted} ? '*' : '';
    }

    close $fh;
    $status_msg = "Saved: $file";
}

# ── About ─────────────────────────────────────────────────

sub show_about {
    my $tl = $mw->Toplevel(-title => 'About Saros');
    $tl->Label(
        -justify    => 'left',
        -padx       => 15,
        -pady       => 15,
        -wraplength => 420,
        -text       => "Saros $VERSION\n\n" .
            "Solar eclipse calculator.\n\n" .
            "Refactored from the original by Sebastian Harl\n" .
            "(Adam-Kraft-Gymnasium Schwabach, 2003).\n\n" .
            "v2.0 improvements:\n" .
            "  - Modular architecture\n" .
            "  - \x{0394}T correction (Espenak & Meeus)\n" .
            "  - WGS84 ellipsoidal Earth model\n" .
            "  - Azimuthal equidistant projection\n\n" .
            "Licensed under the GNU General Public License v3.",
    )->pack;
    $tl->Button(-text => 'Close', -command => sub { $tl->destroy })->pack(-pady => 10);
}
