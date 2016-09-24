#####################################################################
## AUTHOR: Mary Ehlers, regina.verbae@gmail.com
## ABSTRACT: Base role for pipeline segments
#####################################################################

package Piper::Role::Segment;

use v5.10;
use strict;
use warnings;

use Types::Standard qw(Bool CodeRef HashRef InstanceOf);
use Types::Common::Numeric qw(PositiveInt);
use Types::Common::String qw(NonEmptySimpleStr);

use Moo::Role;

=head1 DESCRIPTION

This role contains attributes and methods that apply
to each pipeline segment, both individual process
handlers and pipelines.

=head1 REQUIRES

=head2 init

This role requires the definition of an init method
which initializes the segment as a pipeline
instance and prepares it for data processing.  The
method must return the created pipeline instance.

=cut

requires 'init';

around init => sub {
    my ($orig, $self, @args) = @_;
    state $call = 0;
    $call++;
    # The first time this is called (per Piper object)
    #   will be from the main (or top-level) pipeline
    #   segment
    my $main = $call == 1 ? 1 : 0;

    my $instance = $self->$orig();

    if ($main) {
        # Set the args in the main instance
        $instance->_set_args(\@args);

        # Reset $call so any other Piper objects can
        #   determine their main segment
        $call = 0;
    }

    return $instance;
};

=head1 ATTRIBUTES

=head2 allow

An optional coderef used to subset the items which
are allowed to be processed by the segment.

The coderef runs on each item attempting to queue
to the segment.  If it returns true, the item is
queued.  Otherwise, the item skips the segment and
proceeds to the next adjacent segment.

Each item is localized to $_, and is also passed in
as the first argument.  These example 'allow'
subroutines are equivalent:

    # This handler only accepts digit inputs
    sub { /^\d+$/ }
    sub { $_ =~ /^\d+$/ }
    sub { $_[0] =~ /^\d+$/ }

=cut

has allow => (
    is => 'ro',
    isa => CodeRef,
    # Closure to enable sub to use $_ instead of $_[0],
    #   though $_[0] will also work
    coerce => sub {
        my $orig = shift;
        CodeRef->assert_valid($orig);
        return sub {
            my $item = shift;
            local $_ = $item;
            $orig->($item);
        };
    },
    predicate => 1,
);

=head2 batch_size

The number of items to process at a time for
the segment.  A segment inherits the batch_size
of its parent(s) if not provided.

=cut

has batch_size => (
    is => 'ro',
    isa => PositiveInt,
    predicate => 1,
);

=head2 config

A Piper::Config object defining component classes.

=cut

has config => (
    is => 'lazy',
    isa => InstanceOf['Piper::Config'],
    builder => sub { require Piper::Config; return Piper::Config->new() },
);

=head2 enabled

Boolean indicating that the segment is enabled and
can accept items for processing.  Defaults to true.

=cut

has enabled => (
    is => 'rw',
    isa => Bool,
    default => 1,
);

=head2 extra

Any extra (unknown) attributes passed during initial
construction of the segment are stored in this
hashref.

=cut

has extra => (
    is => 'rwp',
    isa => HashRef,
    predicate => 1,
);

=head2 id

A globally uniq ID for the segment.  This is primarily
useful for debugging only.

=cut

has id => (
    is => 'ro',
    isa => NonEmptySimpleStr,
    builder => sub {
        my ($self) = @_;
        state $id = {};
        my $base = ref $self;
        $id->{$base}++;
        return "$base$id->{$base}";
    },
);

=head2 label

A label for this segment.  If no label is provided, the
segment's id will be used.

Labels are necessary if any handlers wish to use the
injectAt or injectAfter methods.  Otherwise, labels are
primarily useful for logging and/or debugging.

=cut

has label => (
    is => 'rwp',
    isa => NonEmptySimpleStr,
    lazy => 1,
    builder => sub {
        my $self = shift;
        return $self->id;
    },
);

=head1 METHODS

=head2 has_allow

A boolean indicating whether or not an 'allow'
attribute exists for this segment.

=head2 has_batch_size

A boolean indicating whether the segment
has an assigned batch_size.

=head2 has_extra

A boolean indicating whether or not the
'extra' attribute has been set, which
indicates that extra (unknown) attributes
were given to the constructor of the segment.

=cut

1;
