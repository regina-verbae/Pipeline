#####################################################################
## AUTHOR: Mary Ehlers, regina.verbae@gmail.com
## ABSTRACT: A data-processing unit for the Piper pipeline system
#####################################################################

package Piper::Process;

use v5.10;
use strict;
use warnings;

use Carp;
use Piper::Instance;
use Types::Standard qw(CodeRef);

use Moo;
use namespace::clean;

with qw(Piper::Role::Segment);

use overload (
    q{""} => sub { $_[0]->label },
    fallback => 1,
);

our $VERSION = '0.05';

my $CONFIG;
sub import {
    my $class = shift;
    if (@_) {
        require Piper::Config;
        $CONFIG = Piper::Config->new(@_);
    }
    return 1;
}

=head1 CONSTRUCTOR

=head2 new(@args)

The constructor accepts the following patterns for C<@args>:

    Piper::Process->new({
        label      => $label,    # recommended
        handler    => $handler,  # required
        batch_size => $num,      # optional
        allow      => $allow,    # optional
        enabled    => $enabled,  # default: 1
    });

    Piper::Process->new(
        $label => {
            handler    => $handler,
            batch_size => $num,
            allow      => $allow,
            enabled    => $enabled,
        }
    );

    Piper::Process->new($label => $handler);

=cut

around BUILDARGS => sub {
    my ($orig, $self, @args) = @_;

    croak 'ERROR: Too many arguments to constructor of '.__PACKAGE__
        if @args > 2;

    croak 'ERROR: Last argument must be a CODE ref or HASH ref'
        unless (ref $args[-1] eq 'CODE') or (ref $args[-1] eq 'HASH');

    my %hash;
    if (ref $args[-1] eq 'CODE') {
        $hash{handler} = pop @args;
    }
    else {
        %hash = %{pop @args};
    }

    if (@args) {
        croak 'ERROR: Labels may not be a reference' if ref $args[0];
        $hash{label} = shift @args;
    }

    $hash{config} = $CONFIG if defined $CONFIG;

    return $self->$orig(%hash);
};

=head1 ATTRIBUTES

=head2 allow

An optional coderef used to subset the items which are I<allowed> to be processed by the segment.

The coderef runs on each item attempting to queue to the segment.  If it returns true, the item is queued.  Otherwise, the item skips the segment and proceeds to the next adjacent segment.

Each item is localized to C<$_>, and is also passed in as the first argument.  These example C<allow> subroutines are equivalent:

    # This segment only accepts digit inputs
    sub { /^\d+$/ }
    sub { $_ =~ /^\d+$/ }
    sub { $_[0] =~ /^\d+$/ }

=head2 batch_size

The number of items to process at a time for the segment.  Once initialized, a segment inherits the C<batch_size> of its parent(s) if not provided.

=head2 enabled

Boolean indicating that the segment is enabled and can accept items for processing.  Defaults to true.

=head2 handler

The data-processing subroutine for this segment.

The arguments provided to the handler are as follows:

    $instance - the instance corresponding to the segment
    $batch    - an arrayref of items to process
    @args     - the init arguments (if any) provided
                at the initialization of the pipeline

Via the provided C<$instance> object (L<Piper::Instance>), the handler has several options for sending data to other pipes or processes in the pipeline:

    $instance->eject(@data)
    $instance->emit(@data)
    $instance->inject(@data)
    $instance->injectAfter($location, @data)
    $instance->injectAt($location, @data)
    $instance->recycle(@data)

See L<Piper> or L<Piper::Instance> for an explanation of these methods.

Example handler:

    sub {
        my ($instance, $batch) = @_;
        $instance->emit(map { ... } @$batch);
    }

=cut

has handler => (
    is => 'ro',
    isa => CodeRef,
    required => 1,
);

=head2 id

A globally unique ID for the segment.  This is primarily useful for debugging only.

=head2 label

A label for this segment.  If no label is provided, the segment's C<id> will be used.

Labels are necessary if any handlers wish to use the C<injectAt> or C<injectAfter> methods.  Otherwise, labels are primarily useful for logging and/or debugging.

Stringification of a L<Piper::Process> object is overloaded to return its label:

    my $process = Piper::Process->new($label => sub {...});

    $process->label; # $label
    "$process";      # $label

=head1 METHODS

=head2 has_allow

A boolean indicating whether or not an C<allow> attribute exists for this segment.

=head2 has_batch_size

A boolean indicating whether the segment has an assigned C<batch_size>.

=head2 init

Returns a L<Piper::Instance> object for this segment.

=cut

sub init {
    my ($self) = @_;

    return Piper::Instance->new(
        segment => $self,
    );
}

1;

__END__

=head1 SEE ALSO

=over

=item L<Piper>

=item L<Piper::Instance>

=back

=cut
