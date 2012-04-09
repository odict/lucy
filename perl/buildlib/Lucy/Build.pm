# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use warnings;

use lib '../clownfish/perl/blib/arch';
use lib '../clownfish/perl/blib/lib';
use lib 'clownfish/perl/blib/arch';
use lib 'clownfish/perl/blib/lib';

package Lucy::Build;

# We want to subclass Clownfish::CFC::Perl::Build, but Clownfish might not be
# built yet. So we look in 'clownfish/perl/lib' directly and cleanup @INC
# afterwards.
use lib '../clownfish/perl/lib';
use lib 'clownfish/perl/lib';
use base qw( Clownfish::CFC::Perl::Build );
no lib '../clownfish/perl/lib';
no lib 'clownfish/perl/lib';

our $VERSION = 0.003000;
$VERSION = eval $VERSION;

use File::Spec::Functions qw( catdir catfile updir rel2abs );
use File::Path qw( rmtree );
use File::Copy qw( move );
use Config;
use Env qw( @PATH );
use Carp;
use Cwd qw( getcwd );

BEGIN { unshift @PATH, rel2abs( getcwd() ) }

=for Rationale

When the distribution tarball for the Perl binding of Lucy is built, core/,
charmonizer/, and any other needed files/directories are copied into the
perl/ directory within the main Lucy directory.  Then the distro is built from
the contents of the perl/ directory, leaving out all the files in ruby/, etc.
However, during development, the files are accessed from their original
locations.

=cut

my $is_distro_not_devel = -e 'core';
my $base_dir = rel2abs( $is_distro_not_devel ? getcwd() : updir() );

my $CHARMONIZER_ORIG_DIR = catdir( $base_dir, 'charmonizer' );
my $CHARMONIZE_EXE_PATH
    = catfile( $CHARMONIZER_ORIG_DIR, "charmonize$Config{_exe}" );
my $CHARMONY_PATH  = 'charmony.h';
my $LEMON_DIR      = catdir( $base_dir, 'lemon' );
my $LEMON_EXE_PATH = catfile( $LEMON_DIR, "lemon$Config{_exe}" );
my $SNOWSTEM_SRC_DIR
    = catdir( $base_dir, qw( modules analysis snowstem source ) );
my $SNOWSTEM_INC_DIR = catdir( $SNOWSTEM_SRC_DIR, 'include' );
my $SNOWSTOP_SRC_DIR
    = catdir( $base_dir, qw( modules analysis snowstop source ) );
my $UCD_INC_DIR      = catdir( $base_dir, qw( modules unicode ucd ) );
my $UTF8PROC_SRC_DIR = catdir( $base_dir, qw( modules unicode utf8proc ) );
my $CORE_SOURCE_DIR = catdir( $base_dir, 'core' );
my $CLOWNFISH_DIR = catdir( $base_dir, 'clownfish', 'perl' );
my $CLOWNFISH_BUILD  = catfile( $CLOWNFISH_DIR, 'Build' );
my $XS_SOURCE_DIR    = 'xs';
my $LIB_DIR          = 'lib';

sub new {
    my $self = shift->SUPER::new( recursive_test_files => 1, @_ );

    if ( $ENV{LUCY_VALGRIND} ) {
        my $optimize = $self->config('optimize') || '';
        $optimize =~ s/\-O\d+/-O1/g;
        $self->config( optimize => $optimize );
    }

    my $extra_ccflags = $self->extra_compiler_flags;
    if ( $self->config('gccversion') ) {
        if ( $Config{osname} =~ /openbsd/i && !$Config{usethreads} ) {
            push @$extra_ccflags, '-DLUCY_NOTHREADS';
        }
        if ( defined $ENV{LUCY_VALGRIND} ) {
            push @$extra_ccflags, qw( -DLUCY_VALGRIND -fno-inline-functions );
        }
        elsif ( defined $ENV{LUCY_DEBUG} ) {
            push @$extra_ccflags, qw(
                -DLUCY_DEBUG -pedantic -Wall -Wextra -Wno-variadic-macros
            );
        }
    }
    $self->extra_compiler_flags(@$extra_ccflags);

    my $include_dirs = $self->include_dirs;
    push( @$include_dirs,
        $CORE_SOURCE_DIR,
        $XS_SOURCE_DIR,
        $SNOWSTEM_INC_DIR,
        $UCD_INC_DIR,
        $UTF8PROC_SRC_DIR,
    );
    $self->include_dirs($include_dirs);

    my $source_dirs = [];
    push( @$source_dirs,
        $CORE_SOURCE_DIR,
        $XS_SOURCE_DIR,
        $SNOWSTEM_SRC_DIR,
        $SNOWSTOP_SRC_DIR,
        $UTF8PROC_SRC_DIR,
    );
    $self->clownfish_params( source => $source_dirs );

    $self->clownfish_params( autogen_header => $self->autogen_header );

    return $self;
}

sub _run_make {
    my ( $self, %params ) = @_;
    my @command           = @{ $params{args} };
    my $dir               = $params{dir};
    my $current_directory = getcwd();
    chdir $dir if $dir;
    unshift @command, 'CC=' . $self->config('cc');
    if ( $self->config('cc') =~ /^cl\b/ ) {
        unshift @command, "-f", "Makefile.MSVC";
    }
    elsif ( $^O =~ /mswin/i ) {
        unshift @command, "-f", "Makefile.MinGW";
    }
    unshift @command, "$Config{make}";
    system(@command) and confess("$Config{make} failed");
    chdir $current_directory if $dir;
}

# Build the charmonize executable.
sub ACTION_charmonize {
    my $self = shift;
    print "Building $CHARMONIZE_EXE_PATH...\n\n";
    $self->_run_make(
        dir  => $CHARMONIZER_ORIG_DIR,
        args => [],
    );
}

# Run the charmonize executable, creating the charmony.h file.
sub ACTION_charmony {
    my $self = shift;
    $self->dispatch('charmonize');
    return if $self->up_to_date( $CHARMONIZE_EXE_PATH, $CHARMONY_PATH );
    print "\nWriting $CHARMONY_PATH...\n\n";

    # Clean up after charmonize if it doesn't succeed on its own.
    $self->add_to_cleanup("_charm*");
    $self->add_to_cleanup($CHARMONY_PATH);

    # Prepare arguments to charmonize.
    my $flags = join( ' ',
        $self->config('ccflags'),
        @{ $self->extra_compiler_flags },
    );
    $flags =~ s/"/\\"/g;
    my @command = ( $CHARMONIZE_EXE_PATH, $self->config('cc'), $flags );
    if ( $ENV{CHARM_VALGRIND} ) {
        unshift @command, "valgrind", "--leak-check=yes";
    }
    print join( " ", @command ), $/;

    system(@command) and die "Failed to write $CHARMONY_PATH: $!";
}

# Build the charmonizer tests.
sub ACTION_charmonizer_tests {
    my $self = shift;
    $self->dispatch('charmony');
    print "Building Charmonizer Tests...\n\n";
    my $flags = join( " ",
        $self->config('ccflags'),
        @{ $self->extra_compiler_flags },
        '-I' . rel2abs( getcwd() ),
    );
    $flags =~ s/"/\\"/g;
    $self->_run_make(
        dir  => $CHARMONIZER_ORIG_DIR,
        args => [ "DEFS=$flags", "tests" ],
    );
}

# Build the Lemon parser generator.
sub ACTION_lemon {
    my $self = shift;
    print "Building the Lemon parser generator...\n\n";
    $self->_run_make(
        dir  => $LEMON_DIR,
        args => [],
    );
}

sub ACTION_cfc {
    my $self    = shift;
    my $old_dir = getcwd();
    chdir($CLOWNFISH_DIR);
    if ( !-f 'Build' ) {
        print "\nBuilding Clownfish compiler... \n";
        system("$^X Build.PL");
        system("$^X Build code");
        print "\nFinished building Clownfish compiler.\n\n";
    }
    chdir($old_dir);
}

sub ACTION_copy_clownfish_includes {
    my $self = shift;

    $self->dispatch('charmony');

    $self->SUPER::ACTION_copy_clownfish_includes;

    my $inc_dir = catdir( $self->blib, 'arch', 'Clownfish', '_include' );

    # Install charmony.h
    $self->copy_if_modified(
        from => $CHARMONY_PATH,
        to   => catfile( $inc_dir, 'charmony.h' ),
    );

    # Install Lucy/Util/ToolSet.h
    my @toolset_h = qw( Lucy Util ToolSet.h );
    $self->copy_if_modified(
        from => catfile( $CORE_SOURCE_DIR, @toolset_h ),
        to   => catfile( $inc_dir,         @toolset_h ),
    );

    # Install XSBind.h
    $self->copy_if_modified(
        from => catfile( $XS_SOURCE_DIR, 'XSBind.h' ),
        to   => catfile( $inc_dir,       'XSBind.h' ),
    );
}

sub ACTION_clownfish {
    my $self = shift;

    $self->dispatch('charmonizer_tests');
    $self->dispatch('cfc');

    $self->SUPER::ACTION_clownfish;
}

sub ACTION_suppressions {
    my $self       = shift;
    my $LOCAL_SUPP = 'local.supp';
    return
        if $self->up_to_date( '../devel/bin/valgrind_triggers.pl',
        $LOCAL_SUPP );

    # Generate suppressions.
    print "Writing $LOCAL_SUPP...\n";
    $self->add_to_cleanup($LOCAL_SUPP);
    my $command
        = "yes | "
        . $self->_valgrind_base_command
        . "--gen-suppressions=yes "
        . $self->perl
        . " ../devel/bin/valgrind_triggers.pl 2>&1";
    my $suppressions = `$command`;
    $suppressions =~ s/^==.*?\n//mg;
    $suppressions =~ s/^--.*?\n//mg;
    my $rule_number = 1;

    while ( $suppressions =~ /<insert.a.*?>/ ) {
        $suppressions =~ s/^\s*<insert.a.*?>/{\n  <core_perl_$rule_number>/m;
        $rule_number++;
    }

    # Change e.g. fun:_vgrZU_libcZdsoZa_calloc to fun:calloc
    $suppressions =~ s/fun:\w+_((m|c|re)alloc)/fun:$1/g;

    # Write local suppressions file.
    open( my $supp_fh, '>', $LOCAL_SUPP )
        or confess("Can't open '$LOCAL_SUPP': $!");
    print $supp_fh $suppressions;
}

sub _valgrind_base_command {
    return
          "PERL_DESTRUCT_LEVEL=2 LUCY_VALGRIND=1 valgrind "
        . "--leak-check=yes "
        . "--show-reachable=yes "
        . "--num-callers=10 "
        . "--dsymutil=yes "
        . "--suppressions=../devel/conf/lucyperl.supp ";
}

# Run the entire test suite under Valgrind.
#
# For this to work, Lucy must be compiled with the LUCY_VALGRIND environment
# variable set to a true value, under a debugging Perl.
#
# A custom suppressions file will probably be needed -- use your judgment.
# To pass in one or more local suppressions files, provide a comma separated
# list like so:
#
#   $ ./Build test_valgrind --suppressions=foo.supp,bar.supp
sub ACTION_test_valgrind {
    my $self = shift;
    die "Must be run under a perl that was compiled with -DDEBUGGING"
        unless $self->config('ccflags') =~ /-D?DEBUGGING\b/;
    if ( !$ENV{LUCY_VALGRIND} ) {
        warn "\$ENV{LUCY_VALGRIND} not true -- possible false positives";
    }
    $self->dispatch('code');
    $self->dispatch('suppressions');

    # Unbuffer STDOUT, grab test file names and suppressions files.
    $|++;
    my $t_files = $self->find_test_files;    # not public M::B API, may fail
    my $valgrind_command = $self->_valgrind_base_command;
    $valgrind_command .= "--suppressions=local.supp ";

    if ( my $local_supp = $self->args('suppressions') ) {
        for my $supp ( split( ',', $local_supp ) ) {
            $valgrind_command .= "--suppressions=$supp ";
        }
    }

    # Iterate over test files.
    my @failed;
    for my $t_file (@$t_files) {

        # Run test file under Valgrind.
        print "Testing $t_file...";
        die "Can't find '$t_file'" unless -f $t_file;
        my $command = "$valgrind_command $^X -Mblib $t_file 2>&1";
        my $output = "\n" . ( scalar localtime(time) ) . "\n$command\n";
        $output .= `$command`;

        # Screen-scrape Valgrind output, looking for errors and leaks.
        if (   $?
            or $output =~ /ERROR SUMMARY:\s+[^0\s]/
            or $output =~ /definitely lost:\s+[^0\s]/
            or $output =~ /possibly lost:\s+[^0\s]/
            or $output =~ /still reachable:\s+[^0\s]/ )
        {
            print " failed.\n";
            push @failed, $t_file;
            print "$output\n";
        }
        else {
            print " succeeded.\n";
        }
    }

    # If there are failed tests, print a summary list.
    if (@failed) {
        print "\nFailed "
            . scalar @failed . "/"
            . scalar @$t_files
            . " test files:\n    "
            . join( "\n    ", @failed ) . "\n";
        exit(1);
    }
}

# Run all .y files through lemon.
sub ACTION_parsers {
    my $self = shift;
    $self->dispatch('lemon');
    my $y_files = $self->rscan_dir( $CORE_SOURCE_DIR, qr/\.y$/ );
    for my $y_file (@$y_files) {
        my $c_file = $y_file;
        my $h_file = $y_file;
        $c_file =~ s/\.y$/.c/ or die "no match";
        $h_file =~ s/\.y$/.h/ or die "no match";
        next if $self->up_to_date( $y_file, [ $c_file, $h_file ] );
        $self->add_to_cleanup( $c_file, $h_file );
        system( $LEMON_EXE_PATH, '-q', $y_file ) and die "lemon failed";
    }
}

sub ACTION_compile_custom_xs {
    my $self = shift;

    $self->dispatch('parsers');

    $self->SUPER::ACTION_compile_custom_xs;
}

sub autogen_header {
    my $self = shift;
    return <<"END_AUTOGEN";
/***********************************************

 !!!! DO NOT EDIT !!!!

 This file was auto-generated by Build.PL.

 ***********************************************/

/* Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

END_AUTOGEN
}

sub _check_module_build_for_dist {
    eval "use Module::Build 0.38;";
    die "./Build dist reqiures Module::Build 0.38 or higher--this is only "
        . Module::Build->VERSION . $/ if $@;
}

sub ACTION_distdir {
    _check_module_build_for_dist;
    shift->SUPER::ACTION_distdir(@_);
}

sub ACTION_dist {
    my $self = shift;
    _check_module_build_for_dist;

    # Create POD but make sure not to include build artifacts.
    $self->dispatch('pod');
    _clean_prereq_builds($self);

    # We build our Perl release tarball from $REPOS_ROOT/perl, rather than
    # from the top-level.
    #
    # Because some items we need are outside this directory, we need to copy a
    # bunch of stuff.  After the tarball is packaged up, we delete the copied
    # directories.
    my @items_to_copy = qw(
        core
        modules
        charmonizer
        devel
        clownfish
        lemon
        CHANGES
        CONTRIBUTING
        LICENSE
        NOTICE
        README
    );
    print "Copying files...\n";

    for my $item (@items_to_copy) {
        confess("'$item' already exists") if -e $item;
        system("cp -R ../$item $item");
    }

    $self->dispatch('manifest');
    my $no_index = $self->_gen_pause_exclusion_list;
    $self->meta_add( { no_index => $no_index } );
    $self->SUPER::ACTION_dist;

    # Clean up.
    print "Removing copied files...\n";
    rmtree($_) for @items_to_copy;
    unlink("META.yml");
    move( "MANIFEST.bak", "MANIFEST" ) or die "move() failed: $!";
}

sub ACTION_distmeta {
    my $self = shift;
    $self->SUPER::ACTION_distmeta(@_);
    # Make sure everything has a version.
    require CPAN::Meta;
    my $v = version->new($self->dist_version);
    my $meta = CPAN::Meta->load_file('META.json');
    my $provides = $meta->provides;
    while (my ($pkg, $data) = each %{ $provides }) {
        die "$pkg, defined in $data->{file}, has no version\n"
            unless $data->{version};
        die "$pkg, defined in $data->{file}, is "
            . version->new($data->{version})->normal
            . " but should be " . $v->normal . "\n"
            unless $data->{version} == $v;
    }
}

# Generate a list of files for PAUSE, search.cpan.org, etc to ignore.
sub _gen_pause_exclusion_list {
    my $self = shift;

    # Only exclude files that are actually on-board.
    open( my $man_fh, '<', 'MANIFEST' ) or die "Can't open MANIFEST: $!";
    my @manifest_entries = <$man_fh>;
    chomp @manifest_entries;

    my @excluded_files;
    for my $entry (@manifest_entries) {
        # Allow README and Changes.
        next if $entry =~ m#^(README|Changes)#;

        # Allow public modules.
        if ( $entry =~ m#^(perl/)?lib\b.+\.(pm|pod)$# ) {
            open( my $fh, '<', $entry ) or die "Can't open '$entry': $!";
            my $content = do { local $/; <$fh> };
            next if $content =~ /=head1\s*NAME/;
        }

        # Disallow everything else.
        push @excluded_files, $entry;
    }

    # Exclude redacted modules.
    if ( eval { require "buildlib/Lucy/Redacted.pm" } ) {
        my @redacted = map {
            my @parts = split( /\W+/, $_ );
            catfile( $LIB_DIR, @parts ) . '.pm'
        } Lucy::Redacted->redacted, Lucy::Redacted->hidden;
        push @excluded_files, @redacted;
    }

    my %uniquifier;
    @excluded_files = sort grep { !$uniquifier{$_}++ } @excluded_files;
    return { file => \@excluded_files };
}

sub ACTION_semiclean {
    my $self = shift;
    print "Cleaning up most build files.\n";
    my @candidates
        = grep { $_ !~ /(charmonizer|^_charm|charmony|charmonize|snowstem)/ }
        $self->cleanup;
    for my $path ( map { glob($_) } @candidates ) {
        next unless -e $path;
        rmtree($path);
        confess("Failed to remove '$path'") if -e $path;
    }
}

# Run the cleanup targets for independent prerequisite builds.
sub _clean_prereq_builds {
    my $self = shift;
    if ( -e $CLOWNFISH_BUILD ) {
        my $old_dir = getcwd();
        chdir $CLOWNFISH_DIR;
        system("$^X Build realclean")
            and die "Clownfish clean failed";
        chdir $old_dir;
    }
    $self->_run_make( dir => $CHARMONIZER_ORIG_DIR, args => ['clean'] );
    $self->_run_make( dir => $LEMON_DIR,            args => ['clean'] );
}

sub ACTION_clean {
    my $self = shift;
    _clean_prereq_builds($self);
    $self->SUPER::ACTION_clean;
}

1;

__END__
