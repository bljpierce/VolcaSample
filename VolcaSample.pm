##############################################################################
#                                                                            #
#                               VolcaSample.pm                               #
#                                                                            #
#  This module allows Korg Volca Sample pattern sequences to be created and  #
#  for parameter data to be manipulated from within a Perl script. The       # 
#  generated data is encoded as a syrostream file which can then be uploaded #
#  into the Volca Sample.                                                    #
#                                                                            #
#                       Copyright (c) 2018, Barry Pierce                     #
#                                                                            #
##############################################################################

package VolcaSample;
use strict;
use warnings;
use Carp 'croak';
use Fcntl qw(O_CREAT O_WRONLY);
use Config;
use File::Basename;

# the following 3 hashes correspond to the various #define's in
# the volcasample_pattern.h file which is part of the Korg Syro
# SDK library available online at github

my %bit_num_for = (
    motion   => 0x01,
    loop     => 0x02,
    reverb   => 0x04,
    reverse  => 0x08,
    mute     => 0x10,
);


my %param_index_for = (
    level        => 0,
    pan          => 1,
    speed        => 2,
    amp_attack   => 3,
    amp_decay    => 4,
    pitch_int    => 5,
    pitch_attack => 6,
    pitch_decay  => 7,
    start_point  => 8,
    length       => 9,
    hi_cut       => 10,
);


my %motion_param_index_for = (
    level        => 0,
    pan          => 2,
    speed        => 4,
    amp_attack   => 6,
    amp_decay    => 7,
    pitch_int    => 8,
    pitch_attack => 9,
    pitch_decay  => 10,
    start_point  => 11,
    length       => 12,
    hi_cut       => 13,
);

# error checking functions used by the VolcaSample object

sub _check_num_args {
    my $expected = shift;
    croak 'not enough arguments given' if @_ < $expected;
}


sub _check_val_bounds {
    my ($name, $val, $min, $max) = @_;
    
    return if $val eq 'rand';
    
    if ($val < $min || $val > $max) {
        croak "'$name' argument out of bounds (should be between $min & $max)";
    }
}


sub _check_func_names {
    for my $f (@_) {
        if (!grep { $f eq $_ } qw/mute reverb motion reverse/) {
            croak 'unrecognised function name';
        }
    }
}


sub _check_param_name {
    my ($name) = @_;
    
    if (!grep { $name eq $_ } keys %param_index_for) {
        croak 'unrecognised parameter name given';
    }
}


sub _check_param_val {
    my ($param, $val) = @_;
    
    return if $val eq 'rand';
    
    my $err = '';
    if ($param eq 'pan' || $param eq 'pitch_int') {
        if ($val < 1 || $val > 127) {
            $err = "'$param' parameter value is out of range "
                 . "(should be between 1 & 127)";
        }
    }
    elsif ($param eq 'speed') {
        if ($val < 40 || $val > 88) {
            $err = "'speed' parameter value is out of range "
                 . "(should be between 40 & 88)";
        }
    }
    elsif ($val < 0 || $val > 127) {
        $err = "'$param' parameter value is out of range "
             . "(should be between 0 & 127)";
    }
    
    croak $err if $err;
}

# the following 2 functions check that parameter and motion parameter
# values are within the allowed ranges. The allowed ranges were
# obtained from the documentation file in the Korg Syro SDK library 

sub _check_motion_param_val {
    my ($param, $vals) = @_;
    
    if (ref $vals ne 'ARRAY') {
        croak 'Motion parameter value is not an array reference';
    }
    
    if (@$vals < 1) {
        croak 'No motion parameter values given';
    }
    
    if ($param eq 'level' || $param eq 'speed' || $param eq 'pan') {
        if (@$vals < 2) {
            croak "'$param' motion parameter should have 2 values";
        }
    }

    for my $i (0 .. 1) {
        my $v = $vals->[$i];
        next if !defined $v;
        next if defined $v && $v eq 'rand';
        if ($v < 1 || $v > 127) {
            croak "'$param' motion parameter value is out of range"
                . " (should be between 1 & 127)";
        }
    }
}


sub _get_rand_param_val {
    my ($param) = @_;

    my ($min, $max) = (0, 127);

    if ($param eq 'pan' || $param eq 'pitch_int') {
        $min = 1;
    }
    elsif ($param eq 'speed') {
        $min = 40;
        $max = 88;
    }
    
    return int(rand($max - $min)) + $min;
}


sub _get_rand_motion_val {
    my ($param) = @_;
    
    my $v = int(rand(126)) + 1;
    
    if ($param ne 'speed') {
        $v += 128;
    }

    return $v;
}

# the following 2 functions return hashes which correspond to the
# VolcaSample_Part_Data and VolcaSample_Pattern_Data structs defined
# in the volcasample_pattern.h file

sub _init_part_href {
    my $p = {
        samp_num => 0,
        step_on  => 0,
        accent   => 0,
        reserved => 0xff00,
        level    => 0x7f,
        params   => [127, 64, 64, 0, 127, 64, 0, 127, 0, 127, 127],
        funcs    => 0,
        motion   => [],
    };
    
    for (0 .. 223) {
        push @{ $p->{motion} }, 0;
    }
    
    return $p;
}


sub _init_pattern_href {
    return {
        header      => 0x54535450,
        dev_code    => 0x33b8,
        active_step => 0xffff,
        parts       => [],
        footer      => 0x44455450,
    };
}


sub new {
    my $self = bless {}, shift;
    
    $self->{patterns   } = [];
    $self->{pattern_num} = 0;
    $self->{part_num   } = 0;
    $self->{modified   } = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    
    for (1 .. 10) {
        my $p = _init_pattern_href();
        for (1 .. 10) {
            push @{ $p->{parts} }, _init_part_href();
        }
        push @{ $self->{patterns} }, $p;
    }
    
    return $self;
}


sub _get_part_href {
    my ($self) = @_;
    # hide all this dereferencing in a helper method :)
    my $i = $self->{pattern_num};
    my $j = $self->{part_num};
    
    return $self->{patterns}[$i]{parts}[$j];
}


sub _update_modified {
    my ($self) = @_;
    # keep track of which patterns have been modified
    $self->{modified}[$self->{pattern_num}]++;
}


sub set_pattern {
    _check_num_args(2, @_);
    my ($self, $pattern_num) = @_;
    _check_val_bounds('pattern number', $pattern_num, 1, 10);
    
    $self->{pattern_num} = $pattern_num - 1;
}


sub set_part {
    _check_num_args(2, @_);
    my ($self, $part_num) = @_;
    _check_val_bounds('part number', $part_num, 1, 10);
    
    $self->{part_num} = $part_num - 1;
}


sub set_funcs {
    _check_num_args(2, @_);
    my $self = shift;
    _check_func_names(@_);
    
    my $p  = $self->_get_part_href();
    for my $f (@_) {
        my $bn = $bit_num_for{$f};
        $p->{funcs} |= $bn;
    }
    
    $self->_update_modified();
}


sub set_sample {
    _check_num_args(2, @_);
    my ($self, $samp_num) = @_;
    _check_val_bounds('sample number', $samp_num, 0, 99);
    
    if ($samp_num eq 'rand') {
        $samp_num = int rand 99;
    }
    
    my $p = $self->_get_part_href();
    
    $p->{samp_num} = $samp_num;
    
    $self->_update_modified();
}


sub set_step {
    _check_num_args(2, @_);
    my ($self, $step_num) = @_;
    _check_val_bounds('step number', $step_num, 1, 16);
    
    my $p = $self->_get_part_href();
    
    $p->{step_on} |= 2 ** ($step_num - 1);
    
    $self->_update_modified();
}


sub set_steps {
    _check_num_args(2, @_);
    my ($self, $steps) = @_;
    
    if (ref $steps ne 'HASH') {
        croak 'array reference of steps required as argument';
    }
    
    my $p = $self->_get_part_href();
    
    for my $sn (0 .. @$steps - 1) {
        if ($steps->[$sn]) {
            $p->{step_on} |= 2 ** $sn;
        }
    }
    
    $self->_update_modified();
}


sub set_params {
    _check_num_args(3, @_);
    my ($self, %params) = @_;
    
    for my $param (keys %params) {
        my $val = $params{$param};
        _check_param_name($param);
        _check_param_val($param, $val);
        my $p = $self->_get_part_href();
        my $i = $param_index_for{$param};
        if ($val eq 'rand') {
            $val = _get_rand_param_val($param);
        }
        $p->{params}[$i] = $val;
    }
    
    $self->_update_modified();
}


sub set_motion_params {
    _check_num_args(4, @_);
    my ($self, $step_num, %params) = @_;
    _check_val_bounds('step number', $step_num, 1, 16);
    
    for my $param (keys %params) {
        _check_param_name($param);
        _check_motion_param_val($param, $params{$param});
        my $v1 = $params{$param}->[0];
        my $v2 = $params{$param}->[1];
        if ($param ne 'speed') {
            $v1 += 128;
            $v2 += 128 if defined $v2;
        }
        if ($v1 eq 'rand') {
            $v1 = _get_rand_motion_val($param);
        }
        if (defined $v2 && $v2 eq 'rand') {
            $v2 = _get_rand_motion_val($param);
        }
        my $i = $motion_param_index_for{$param};
        my $p = $self->_get_part_href();
        if ($param eq 'level' || $param eq 'pan' || $param eq 'speed') {
            $p->{motion}[($i*16)       + $step_num - 1] = $v1;
            $p->{motion}[(($i+1) * 16) + $step_num - 1] = $v2;
        }
        else {
            $p->{motion}[($i*16) + $step_num - 1] = $v1;
        }
    }
    
    $self->_update_modified();
}


sub get_pattern {
    return shift->{pattern_num} + 1;
}


sub get_part {
    return shift->{part_num} + 1;
}


sub get_sample {
    my $p = shift->_get_part_href();
    
    return $p->{samp_num};
}


sub step_is_on {
    _check_num_args(2, @_);
    my ($self, $step_num) = @_;
    _check_val_bounds('step number', $step_num, 1, 16);
    
    my $p = $self->_get_part_href();
    
    return $p->{step_on} & 2 ** ($step_num - 1) ? 1 : 0; 
}


sub func_is_on {
    _check_num_args(2, @_);
    my ($self, $func) = @_;
    _check_func_names($func);
    
    my $p  = $self->_get_part_href();
    my $bn = $bit_num_for{$func};
    
    return $p->{funcs} & $bn ? 1 : 0;
}


sub get_param_val {
    _check_num_args(2, @_);
    my ($self, $param) = @_;
    _check_param_name($param);
    
    my $p = $self->_get_part_href();
    my $i = $param_index_for{$param};
    
    return $p->{params}[$i];
}


sub get_motion_param_val {
    _check_num_args(3, @_);
    my ($self, $step_num, $param) = @_;
    _check_val_bounds('step number', $step_num, 1, 16);
    _check_param_name($param);
    
    my $p = $self->_get_part_href();
    my $i = $motion_param_index_for{$param};
    
    if ($param eq 'level' || $param eq 'speed' || $param eq 'pan') {
        return $p->{motion}[($i*16) + $step_num - 1],
               $p->{motion}[(($i+1) * 16) + $step_num - 1];
    }
    else {
        return $p->{motion}[($i*16) + $step_num - 1];
    }
}


sub _make_part_binary_blob {
    my ($self, $part) = @_;
    
    return pack
        'v v v C2 C C11 C x11 C224',
        $part->{samp_num},
        $part->{step_on},
        0,
        0xff,
        0,
        0x7f,
        @{ $part->{params} },
        $part->{funcs},
        @{ $part->{motion} };
        
}


sub _write_patterns {
    my $self = shift;
    my $file = shift;
    # generate the binary files that will store the pattern
    # and parameter data
    for my $pattern_num (@_) {
        my $ps = '';
        my @patterns = @{ $self->{patterns} };
        my $pattern = $patterns[$pattern_num - 1];
        for my $part (@{ $pattern->{parts} }) {
            $ps .= $self->_make_part_binary_blob($part);
        }
        my $s = pack
            'V v x2 v x22 a2560 x28 V',
            $pattern->{header},
            $pattern->{dev_code},
            $pattern->{active_step},
            $ps,
            $pattern->{footer};
        my $f = $file . "_pattern$pattern_num.dat"; 
        sysopen my $fh, $f, O_CREAT | O_WRONLY or croak "$!";
        syswrite $fh, $s;
        close $fh;
    }
}


sub make_syro {
    _check_num_args(2, @_);
    my ($self, $file) = @_;
    
    # determine which patterns have been modified
    my @pn;
    for my $i (0 .. @{ $self->{modified} } - 1) {
        if ($self->{modified}[$i]) {
            push @pn, $i+1;
        }
    }
    
    # generate the .dat binary files
    $self->_write_patterns($file, @pn);
    
    # load the .dat files
    # TODO - provide option to delete the .dat files
    my ($name, $path) = fileparse($file);
    opendir(my $dh, $path) or croak "cannot open '$path' for reading";
    my @dat_files = grep { /\.dat/ } readdir $dh;
    closedir $dh;
    
    # generate a string of command line arguments for the
    # syrostream creator program
    my $args = '';
    for my $f (@dat_files) {
        if ($f =~ /$file[_]pattern(\d|\d\d)[.]dat/) {
            $args .= $1 < 10 ? " p0$1:$f" : " p$1:$f";
        }
    } 
   
    # TODO - add support for Windows & MacOS
    my $exe;
    if ($^O eq 'linux') {
        if ($Config{longsize} == 4) {
            $exe = "syro_volcasample_linux.i686";
        }
        elsif ($Config{longsize} == 8) {
            $exe = "syro_volcasample_linux.x86_64";
        }
    }
    else {
        croak 'unsupported operating system';
    }
    
    my $f = $file . '.wav';
    system "./$exe $f $args";
}


1;


__END__

=head1 NAME

VolcaSample

=head1 VERSION

VERSION 0.0001

=head1 SYNOPSIS

use Volcasample;

my $vs = VolcaSample->new();

for my $pattern (1 .. 10) {
    $vs->set_pattern($pattern);
    for my $part (1 .. 10) {
        $vs->set_part($part);
        $vs->set_sample('rand');
        $vs->set_params(
            pan       => 'rand',
            pitch_int => 'rand',
            amp_decay => 'rand',
        );
        for my $sn (1 .. 16) {
            if (rand(1) > 0.5) {
                $vs->set_step($sn);
                $vs->set_funcs('motion');
                $vs->set_motion_params(
                    $sn,
                    speed => [1, 127],
                );
            }
        }
    }
}

$vs->make_syro('patterns');

=head1 DESCIPTION

This module allows Korg Volca Sample pattern sequences to be created and for
parameter data to be manipulated from within a Perl script. The generated
data is encoded as a syrostream file which can then be uploaded into the Volca
Sample.

=head1 CONSTRUCTOR

=head2 new()

Creates a VolcaSample object for encoding Volca Sample sequence pattern and
parameter data. 

Each VolcaSample object contains 10 patterns. Each pattern can contain up to
10 parts. Each part has one sample assigned to it and its own sequence of
sixteen steps. 

=head1 METHODS

Firstly, you need to select a pattern and then select a part within that
pattern:

=head2 set_pattern($pattern_number)

Selects the pattern whose parts you wish to manipulate. $pattern_number should
be a whole number between 1 and 10.

=head2 set_part($part_number)

Selects the part whose parameters and sequencer steps you wish to manipulate.
$part_number should be a whole number between 1 and 10. 

Once a part has been selected the following methods can be used to manipulate
it:

=head2 set_sample($sample_number)

Sets the sample that will be played for the selected part. $sample_number
should be a value between 0 and 99. This assumes you have 100 samples loaded
into your Volca Sample (the factory default). If this is not the case then it
is up to you to provide a sensible value.

=head2 set_funcs(funcs)

Switches on Volca Sample functions. The funcs argument is a list of Volca
Sample function names. Valid names are: 'reverse', 'mute', 'reverb', 'loop'
and 'motion'. For example:

    $vs->set_funcs(qw/reverb reverse/)

will switch on reverb and reverse the playback of the sample.
 
=head2 set_step($step_number)

Turns the step on for the selected part. $step_number corresponds to one of
the sixteen steps on the Volca sample so it should be a whole number between
1 and 16.

=head2 set_steps($steps)

Sets the steps for the selected part. The $steps argument must be an array
reference of steps. Each item in the array can have a value of either 0 (step
is off) or 1 (step is on). If an array of less than sixteen steps is given
the missing steps will be given a value of 0. An example of how you might use
this method is:

    $vs->set_steps([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
    
which will set steps 1, 5, 9, 13.

=head2 set_params( param => $val)

Sets the programmable parameters for the selected part. 'param' corresponds
to the one of the eleven step programmable parameter knobs on the Volca
Sample and can be any of the following: 'level', 'speed', 'pan', 'amp_attack',
'amp_decay', 'pitch_int', 'pitch_attack', 'pitch_decay', 'start_point',
'length' or 'hi_cut'.

$val maps to the knob position position for the parameter in question. It can
be a whole number between 0 (off) and 127 (max) for all parameters except
'pan', 'pitch_int' and 'speed'. The minimum value means the knob is turned
hard left and the maximum value means it is turned hard right.  
 
For 'pan' and 'pitch_int', $val can be a value between 1 and 127. A value of
64 corresponds to the centre postion for these parameter knobs.
 
For 'speed' $val can be a value between 40 (-24 semitones) and 88 (+24
semitones). A value of 64 corresponds to the centre position for this
parameter knob.
 
For all parameters $val can be given a value of 'rand' and doing so will
generate an appropriate random value for the respective parameter.
 
More than one parameter can be set at a time by providing additional
param => $val pairs.
 
An example of how you might use this method:
 
    $vs->set_params( pan => 'rand', level => 60 )

will set 'pan' to a random value and the 'level' to a value of 90.

=head2 set_motion_params($step,  param => [] )

Sets the motion sequence parameter data for the selected part.
 
Motion sequencing is the name given for recording the movements (positions)
of the knobs on the Volca Sample. The eleven programmable parameters
mentioned above can all be motion sequenced.
 
'param' can be any of those mentioned above. The 'param' value must be an
array reference containing either one ([$val1]) or two items ([$val1, $val2]). 
For parameters 'level', 'speed' and 'pan' this array reference must contain
two values: the start and end motion sequence data. For example,
 
    $vs->set_motion_params( 2, pan   => [1, 127] ) 
 
will 'pan' the sample from hard left (1) to hard right (127) on step 2. The
values between the start and end of the motion sequence data will be
interpolated giving the impression of a smooth transition.
 
For all other parameters this array reference requires just one value which
is equivalent to the knob position for that parameter. $val1 and $val2 can be
between 1 and 127 or can be given the value of 'rand' in which case a random
value will be generated.
 
More than one motion sequence parameter can be set at a time by providing
additional param => [] pairs. For example,
 
    $vs->set_motion_params(
        1,
        pan     => [127, 1],
        hi_cut  => [90]
    )
    
will 'pan' the sample from hard right to hard left and set the 'hi_cut'
parameter to 90 for step 1.

=head2 make_syro($file_name)

Generates a syrostream file for the pattern and parameter data which
can then be transferred to the Volca Sample. $file_name will be the name
of the syrostream file that will be generated. It will be appended with
the extension '_syro.wav'.

To transfer the syrostream to your Volca Sample unit follow these
instructions:
 
1. Attach a stereo lead from your computers headphone (audio out) port to
the SYNC_IN port on the Volca Sample.
2. Switch your Volca Sample on.
3. Make sure the output sound level on your computer is set to a high
level and that no other sounds are playing.
4. Play the syrostream file generated above with your favorite audio 
player.
5. On successful transfer of your pattern the 'FUNC' button will be
flashing. Press it to stop it flashing and then disconnect the stereo
lead from the SYNC-IN port.
6. Select which  pattern you wish to audition and press PLAY.
 
IMPORTANT! Do not listen to the syrostream file on your speakers or on
headphones. Doing so may damage them or more importantly may damage your
hearing.

If you get an error transferring the data to the Volca Sample, try the
following:

1. Make sure the output sound level is turned up to high.
2. Make sure no other sounds are playing whilst data is being transferred.
3. Make sure the firmware on the Volca Sample is version 1.2 or higher.
   Consult the manufacturers instructions on how to do this.
   
=head2 get_pattern()

Returns the currently selected pattern.

=head2 get_part()

Returns the currently selected part.

=head2 get_sample()

Returns the sample number for the currently selected pattern and part.

=head2 step_is_on($step_num)

Determines whether the given step ($step_num) is on. Returns true if it
is on or false if it is off.

=head2 func_is_on($func_name)

Determines whether the given function ($func_name) is on. Returns true if
it is or false if it is off.

=head2 get_param_val($param)

Returns the value of the given parameter ($param).

=head2 get_motion_param_val($step, $param)

Returns the value(s) of the given motion parameter ($param) for the given
step ($step). Motion parameters 'level', 'speed' and 'pan' return two
values the start and end values. All other parameters return one value.

=head1 AUTHOR

Barry Pierce, bljpierce@gmail.com

=head1 COPYRIGHT & LICENCE

Copyright (c) 2018, Barry Pierce.

