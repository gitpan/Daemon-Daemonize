package Daemon::Daemonize;

use warnings;
use strict;

=head1 NAME

Daemon::Daemonize - A daemonizer

=head1 VERSION

Version 0.001

=cut

our $VERSION = '0.001';

=head1 SYNOPSIS

    use Daemon::Daemonize

    Daemon::Daemonize->daemonize( %options, run => sub {

        # Daemon code in here...

    } )

    # Do some non-daemon stuff here...

You can also use it in the traditional way, daemonizing the current process:

    Daemon::Daemonize->daemonize( %options )

    # Daemon code in here...

...and use it to check up on your daemon:

    # In your daemon
    Daemon::Daemonize->write_pidfile( $pidfile )
    $SIG{INT} = sub { Daemon::Daemonize->delete_pidfile( $pidfile ) }

    ... Elsewhere ...

    # Return the pid from $pidfile if it contains a pid AND
    # the process is running (even if you don't own it), 0 otherwise
    my $pid = Daemon::Daemonize->check_pidfile( $pidfile )

    # Return the pid from $pidfile, or undef if the
    # file doesn't exist, is unreadable, etc.
    # This will return the pid regardless of if the process is running
    my $pid = Daemon::Daemonize->read_pidfile( $pidfile )
    
=head1 DESCRIPTION

Daemon::Daemonize is a toolbox for both daemonizing processes & checking up on those processes. It takes inspiration from L<http://www.clapper.org/software/daemonize/>, L<MooseX::Daemon>, L<Net::Server::Daemon>, and more...

Being new, the API is currently fluid, but shouldn't change too much

=head1 METHODS

=cut

use POSIX;
use Carp;
use Path::Class;

sub _fork_or_die {
    my $self = shift;

    my $pid = fork;
    confess "Unable to fork" unless defined $pid;
    return $pid;
}

sub _close_all {
    my $self = shift;

    my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );
    $openmax = 64 if ! defined( $openmax ) || $openmax < 0;

    POSIX::close($_) foreach (0 .. $openmax - 1);
}

=head2 Daemon::Daemonize->daemonize( %options )

Daemonize via the current process, according to C<%options>:

    no_chdir            Don't change directory to '/' (good for avoiding unmount difficulty)
                        Default false

    no_close            Don't close STDIN, STDOUT, STDERR (usually redirected from/to /dev/null)
                        Default false

    chdir <dir>         If given, will change directory to <dir>. This will override no_chdir

    stdout <file>       Open up STDOUT of the process to <file>. This will override no_close

    stderr <file>       Open up STDERR of the process to <file>. This will override no_close

    run <code>          After daemonizing, run the given code and then exit successfully

=cut

sub daemonize {
    my $self = shift;
    my %options = @_;

    {
        if ( my $run = delete $options{run} ) {

            if ( -1 == $self->daemonize( %options, continue => 1 ) ) {
                # We're the parent, continue on...
            }
            else {
                # We've daemonized... launch into the code we've been given...
                $run->();
                exit 0;
            }

            return; # Daemonization actually handled in call above... Abort, abort, pull-up!
        }
    }

    $options{no_chdir} = delete $options{nochdir} if ! exists $options{no_chdir} && exists $options{nochdir};
    $options{no_close} = delete $options{noclose} if ! exists $options{no_close} && exists $options{noclose};

    # Fork once to go into the background
    {
        if ( my $pid = $self->_fork_or_die ) {
            return -1 if $options{continue};
            exit 0;
        }
    }

    # Create new session
    (POSIX::setsid)
        || confess "Cannot detach from controlling process";

    # Fork again to ensure that daemon never reacquires a control terminal
    $self->_fork_or_die && exit 0;

    # Clear the file creation mask
    umask 0;

    if ( my $chdir = $options{chdir} ) {
        chdir $chdir or confess "Unable to chdir to \"$chdir\": $!";
    }
    # Change to the root so we don't intefere with unmount
    elsif ( ! $options{no_chdir} ) {
        chdir '/';
    }

    unless ( $options{keep_open} || $options{no_close_all} ) {
        # Close any open file descriptors
        $self->_close_all;
    }

    my $stdout_file = $ENV{DAEMON_DAEMONIZE_STDOUT} || $options{stdout};
    my $stderr_file = $ENV{DAEMON_DAEMONIZE_STDERR} || $options{stderr};

    unless( $options{keep_open} || $options{no_close} ) {
        # Re-open  STDIN, STDOUT, STDERR to /dev/null
        open( STDIN,  "+>/dev/null" ) or confess "Could not redirect STDIN to /dev/null";

        unless ( $stdout_file ) {
            open( STDOUT, "+>&STDIN" ) or confess "Could not redirect STDOUT to /dev/null";
        }

        unless ( $stderr_file ) {
            open( STDERR, "+>&STDIN" ) or confess "Could not redirect STDERR to /dev/null";
        }

        # Avoid 'stdin reopened for output' warning (taken from MooseX::Daemonize)
        open( NULL, '/dev/null' );
        <NULL> if 0;
    }

    if ( $stdout_file ) {
        open STDOUT, ">", $stdout_file or confess "Could not redirect STDOUT to $stdout_file : $!";
    }

    if ( $stderr_file ) {
        open STDERR, ">", $stderr_file or confess "Could not redirect STDERR to $stderr_file : $!";
    }

    return 1;
}

sub _pidfile($) {
    my $pidfile = shift;
    confess "No pidfile given" unless defined $pidfile;
    return Path::Class::File->new( ref $pidfile eq 'ARRAY' ? @$pidfile : "$pidfile" );
}

=head2 Daemon::Daemonize->read_pidfile( $pidfile )

Return the pid from $pidfile. Return undef if the file doesn't exist, is unreadable, etc.
This will return the pid regardless of if the process is running

For an alternative, see C<check_pidfile>

=cut

sub read_pidfile {
    my $self = shift;
    my $pidfile = _pidfile shift;

    return unless -s $pidfile;
    return unless -f $pidfile && -r $pidfile;
    return scalar $pidfile->slurp( chomp => 1 );
}

=head2 Daemon::Daemonize->write_pidfile( $pidfile, [ $pid ] )

Write the given pid to $pidfile, creating/overwriting any existing file. The second
argument is optional, and will default to $$ (the current process number)

=cut

sub write_pidfile {
    my $self = shift;
    my $pidfile = _pidfile shift;
    my $pid = shift || $$;

    my $fh = $pidfile->openw;
    $fh->print( $pid . "\n" );
    $fh->close;
}

=head2 Daemon::Daemonize->delete_pidfile( $pidfile )

Unconditionally delete (unlink) $pidfile

=cut

sub delete_pidfile {
    my $self = shift;
    my $pidfile = _pidfile shift;

    $pidfile->remove;
}

=head2 Daemon::Daemonize->check_pidfile( $pidfile )

Return the pid from $pidfile if it contains a pid AND the process is running (even if you don't own it), and 0 otherwise

This method will always return a number

=cut

sub check_pidfile {
    my $self = shift;
    my $pidfile = _pidfile shift;

    my $pid = $self->read_pidfile( $pidfile );
    return 0 unless $pid;
    return 0 unless $self->does_process_exist( $pid );
    return $pid;
}

sub does_process_exist {
    my $self = shift;
    my $pid = shift;

    return 1 if kill 0, $pid;
    my $errno = $!;

    if ( eval { require Errno } ) {
        return 1 if exists &Errno::EPERM && $errno == &Errno::EPERM;
    }

    # So $errno == ESRCH, or we don't have Errno.pm, ... just going to assume non-existent
    return 0;
}

sub can_signal_process {
    my $self = shift;
    my $pid = shift;

    return kill 0, $pid ? 1 : 0;
    # So $! is ESRCH or EPERM or something else, so we can't signal/control it
}

sub check_port {
    require IO::Socket::INET;
    my $self = shift;
    my $port = shift;

    my $socket = IO::Socket::INET->new( PeerAddr => 'localhost', PeerPort => $port, Proto => 'tcp' );
    if ( $socket ) {
        $socket->close;
        return 1;
    }
    return 0;
}

=head1 SEE ALSO

L<MooseX::Daemonize>

L<Proc::Daemon>

L<Net::Server::Daemonize>

=head1 AUTHOR

Robert Krimen, C<< <rkrimen at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-daemon-daemonize at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Daemon-Daemonize>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Daemon::Daemonize


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Daemon-Daemonize>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Daemon-Daemonize>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Daemon-Daemonize>

=item * Search CPAN

L<http://search.cpan.org/dist/Daemon-Daemonize/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2009 Robert Krimen.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of Daemon::Daemonize