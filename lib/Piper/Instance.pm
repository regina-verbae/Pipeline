#####################################################################
## AUTHOR: Mary Ehlers, regina.verbae@gmail.com
## ABSTRACT: An initialized pipeline segment for the Piper system
#####################################################################

package Piper::Instance;

use v5.10;
use strict;
use warnings;

use List::AllUtils qw(last_value max part sum);
use List::UtilsBy qw(max_by min_by);
use Piper::Path;
use Scalar::Util qw(weaken);
use Types::Standard qw(ArrayRef ConsumerOf Enum HashRef InstanceOf Tuple slurpy);

use Moo;
use namespace::clean;

with qw(Piper::Role::Queue);

use overload (
    q{""} => sub { $_[0]->path },
    fallback => 1,
);

our $VERSION = '0.06';

=head1 ATTRIBUTES

=head2 batch_size

The number of items to process at a time for this segment.

If not set, inherits the C<batch_size> of any existing parent(s).  If the segment has no parents, or if none of its parents have a C<batch_size> defined, the default C<batch_size> will be used.  The default is 200, but this can be configured at import of L<Piper>.

To clear a previously-set C<batch_size>, simply set it to C<undef> or use the C<clear_batch_size> method.

    $segment->batch_size(undef);
    $segment->clear_batch_size;

=cut

# around below to set up inheritance through parents

=head2 children

For container instances (made from L<Piper> objects, not L<Piper::Process> objects), the C<children> attribute holds an arrayref of the contained instance objects.

=cut

has children => (
    is => 'ro',
    # Must contain at least one child
    isa => Tuple[InstanceOf['Piper::Instance'],
        slurpy ArrayRef[InstanceOf['Piper::Instance']]
    ],
    required => 0,
    predicate => 1,
);

=head2 debug

Debug level for this segment.  When accessing, inherits the debug level of any existing parent(s) if not explicitly set for this segment.  The default level is 0, but can be globally overridden with the environment variable C<PIPER_DEBUG>.

To clear a previously-set debug level for a segment, simply set it to C<undef> or use the C<clear_debug> method.

    $segment->debug(undef);
    $segment->clear_debug;

=cut

# around below to set up inheritance through parents

=head2 enabled

A boolean indicating that the segment is enabled and can accept items for processing.  Inherits this attribute from any existing parent(s) with a default of true.

To clear a previously-set enabled attribute, simply set it to C<undef> or use the C<clear_enabled> method.

    $segment->enabled(undef);
    $segment->clear_enabled;

=cut

# around below to set up inheritance through parents

=head2 main

Holds a reference to the outermost container instance for the pipeline.

=cut

has main => (
    is => 'lazy',
    isa => InstanceOf['Piper::Instance'],
    weak_ref => 1,
    builder => sub {
        my ($self) = @_;
        my $parent = $self;
        while ($parent->has_parent) {
            $parent = $parent->parent;
        }
        return $parent;
    },
);

=head2 parent

Unless this segment is the outermost container (C<main>), this attribute holds a reference to the segment's immediate container.

=cut

has parent => (
    is => 'rwp',
    isa => InstanceOf['Piper::Instance'],
    # Setting a parent will introduce a self-reference
    weak_ref => 1,
    required => 0,
    predicate => 1,
);

=head2 path

The full path to this segment, built as the concatenation of all the parent(s) labels and the segment's label, joined by C</>.  L<Piper::Instance> objects stringify to this attribute.

=cut

has path => (
    is => 'lazy',
    isa => InstanceOf['Piper::Path'],
    builder => sub {
        my ($self) = @_;

        return $self->has_parent
            ? $self->parent->path->child($self->label)
            : Piper::Path->new($self->label);
    },
);

=head2 verbose

Verbosity level for this segment.  When accessing, inherits verbosity level of any existing parent(s) if not explicitly set for this segment.

To clear a previously-set verbosity level for a segment, simply set it to C<undef> or use the C<clear_verbose> method.

    $segment->verbose(undef);
    $segment->clear_verbose;

=cut

# Inherit parent settings
for my $attr (qw(batch_size debug enabled verbose)) {
    my $clear = "clear_$attr";
    my $has = "has_$attr";

    around $attr => sub {
        my ($orig, $self) = splice @_, 0, 2;

        state $default = {
            batch_size => $self->main->config->batch_size,
            debug => 0,
            enabled => 1,
            verbose => 0,
        };

        if (@_) {
            return $self->$clear() if !defined $_[0];
            return $self->$orig(@_);
        }
        else {
            return $self->$has()
                ? $self->$orig()
                : $self->has_parent
                    ? $self->parent->$attr()
                    : $default->{$attr};
        }
    };
}

=head1 METHODS

Methods marked with a (*) should only be called from the outermost instance.

=head2 clear_batch_size

=head2 clear_debug

=head2 clear_enabled

=head2 clear_verbose

Methods for clearing the corresponding attribute.

=head2 has_children

A boolean indicating whether the instance has any children (contained instances).  Will be true for all segments initialized from a L<Piper> object and false for all segments initialized from a L<Piper::Process> object.

=head2 has_parent

A boolean indicating whether the instance has a parent (container instance).  Will be true for all segments except the outermost segment (C<main>).

=head2 has_pending

Returns a boolean indicating whether there are any items that are queued at some level of the segment but have not completed processing.

=cut

sub has_pending {
    my ($self) = @_;

    if ($self->has_children) {
        for my $child (@{$self->children}) {
            return 1 if $child->has_pending;
        }
        return 0;
    }
    else {
        return $self->queue->ready;
    }
}

=head2 *dequeue([$num])

Remove at most C<$num> S<(default 1)> processed items from the end of the segment.

=head2 *enqueue(@data)

Queue C<@data> for processing by the pipeline.

=cut

around enqueue => sub {
    my ($orig, $self, @args) = @_;

    if (!$self->enabled) {
        # Bypass - go straight to drain
        $self->INFO('Skipping disabled process', @args);
        $self->drain->enqueue(@args);
        return;
    }

    my @items;
    if ($self->has_allow) {
        my ($skip, $queue) = part {
            $self->allow->($_) ? 1 : 0
        } @args;

        @items = @$queue if defined $queue;

        if (defined $skip) {
            $self->INFO('Disallowed items emitted to next handler', @$skip);
            $self->drain->enqueue(@$skip);
        }
    }
    else {
        @items = @args;
    }

    return unless @items;

    $self->INFO('Queueing items', @items);
    $self->$orig(@items);
};

=head2 find_segment($location)

Find and return the segment instance according to <$location>, which can be a label or a path-like hierarchy of labels.

For example, in the following pipeline, a few possible C<$location> values include C<a>, C<subpipe/b>, or C<main/subpipe/c>.

    my $pipe = Piper->new(
        { label => 'main' },
        subpipe => Piper->new(
            a => sub { ... },
            b => sub { ... },
            c => sub { ... },
        ),
    )->init;

If a label is unique within the pipeline, no path is required.  For non-unique labels, searches are performed in a nearest-neighbor, depth-first manner.

For example, in the following pipeline, searching for C<processA> from C<processB> would find C<main/pipeA/processA>, not C<main/processA>.  So to reach C<main/processA> from C<processB>, the appropriate search would be for C<main/processA>.

    my $pipe = Piper->new(
        { label => 'main' },
        pipeA => Piper->new(
            processA => sub { ... },
            processB => sub { ... },
        ),
        processA => sub { ... },
    );

=cut

sub find_segment {
    my ($self, $location) = @_;
    
    state $global_cache = {};
    $global_cache->{$self->main->id}{$self->path} //= {};
    my $cache = $global_cache->{$self->main->id}{$self->path};

    unless (exists $cache->{$location}) {
        $location = Piper::Path->new($location);
        if ($self->has_children or $self->has_parent) {
            my $parent = $self->has_children ? $self : $self->parent;
            my $segment = $parent->descendant($location);
            while (!defined $segment and $parent->has_parent) {
                my $referrer = $parent;
                $parent = $parent->parent;
                $segment = $parent->descendant($location, $referrer);
            }
            $cache->{$location} = $segment;
        }
        else {
            # Lonely Process (no parents or children)
            $cache->{$location} = "$self" eq "$location" ? $self : undef;
        }
        weaken($cache->{$location}) if defined $cache->{$location};
    }

    $self->DEBUG("Found label $location: '$cache->{$location}'") if defined $cache->{$location};
    return $cache->{$location};
}

=head2 *flush

Process batches until there are no more items pending.

=cut

sub flush {
    my ($self) = @_;

    while ($self->has_pending) {
        $self->process_batch;
    }
}

=head2 *is_exhausted

Returns a boolean indicating whether there are any items left to process or dequeue.

=cut

sub is_exhausted {
    my ($self) = @_;
    
    return $self->prepare ? 0 : 1;
}

=head2 *isnt_exhausted

Returns the opposite of C<is_exhausted>.

=cut

sub isnt_exhausted {
    my ($self) = @_;
    return !$self->is_exhausted;
}

=head2 next_segment

Returns the next adjacent segment from the calling segment.  Returns C<undef> for the outermost container.

=cut

sub next_segment {
    my ($self) = @_;
    return unless $self->has_parent;
    return $self->parent->follower->{$self};
}

=head2 pending

Returns the number of items that are queued at some level of the segment but have not completed processing.

=cut

sub pending {
    my ($self) = @_;
    if ($self->has_children) {
        return sum(map { $_->pending } @{$self->children});
    }
    else {
        return $self->queue->ready;
    }
}

=head2 *prepare([$num])

Process batches while data is still C<pending> until at least C<$num> S<(default 1)> items are C<ready> for C<dequeue>.

=cut

sub prepare {
    my ($self, $num) = @_;
    $num //= 1;

    while ($self->has_pending and $self->ready < $num) {
        $self->process_batch;
    }
    return $self->ready;
}

=head2 ready

Returns the number of items that have finished processing and are ready for C<dequeue> from the segment.

=cut

=head1 FLOW CONTROL METHODS

These methods are available for use within process handler subroutines (see L<Piper::Process>).

=head2 eject(@data)

If the segment has a parent, send C<@data> to the drain of its parent.  Otherwise, enqueues C<@data> to the segment's drain.

=cut

sub eject {
    my $self = shift;
    if ($self->has_parent) {
        $self->INFO('Ejecting to drain of parent ('.$self->parent.')', @_);
        $self->parent->drain->enqueue(@_);
    }
    else {
        $self->INFO('Ejecting to drain', @_);
        $self->drain->enqueue(@_);
    }
}

=head2 emit(@data)

Send C<@data> to the next segment in the pipeline.  If the segment is the last in the pipeline, emits to the drain, making the C<@data> ready for C<dequeue>.

=cut

sub emit {
    my $self = shift;
    $self->INFO('Emitting', @_);
    # Just collect in the drain
    $self->drain->enqueue(@_);
}

=head2 inject(@data)

If the segment has a parent, enqueues C<@data> to its parent.  Otherwise, enqueues <@data> to itself.

=cut

sub inject {
    my $self = shift;

    if ($self->has_parent) {
        $self->INFO('Injecting to parent ('.$self->parent.')', @_);
        $self->parent->enqueue(@_);
    }
    else {
        $self->INFO('Injecting to self ('.$self.')', @_);
        $self->enqueue(@_);
    }
}

=head2 injectAfter($location, @data)

Send C<@data> to the segment I<after> the specified C<$location>.  See L<C<find_segment>|/find_segment($location)> for a detailed description of C<$location>.

=cut

sub injectAfter {
    my $self = shift;
    my $location = shift;
    my $segment = $self->find_segment($location);
    $self->ERROR("Could not find $location to injectAfter", @_)
        if !defined $segment;
    $self->INFO("Injecting to $location", @_);
    $segment->drain->enqueue(@_);
}

=head2 injectAt($location, @data)

Send C<@data> to the segment I<at> the specified C<$location>.  See L<C<find_segment>|/find_segment($location)> for a detailed description of C<$location>.

=cut

sub injectAt {
    my $self = shift;
    my $location = shift;
    my $segment = $self->find_segment($location);
    $self->ERROR("Could not find $location to injectAt", @_)
        if !defined $segment;
    $self->INFO("Injecting to $location", @_);
    $segment->enqueue(@_);
}

=head2 recycle(@data)

Re-queue C<@data> to the top of the current segment in an order such that C<dequeue(1)> would subsequently return C<$data[0]> and so forth.

=cut

sub recycle {
    my $self = shift;
    $self->INFO('Recycling', @_);
    $self->requeue(@_);
}

=head1 LOGGING AND DEBUGGING METHODS

See L<Piper::Logger> for detailed descriptions.

=head2 INFO($message, [@items])

Prints an informational C<$message> to STDERR if either the debug or verbosity level for the segment S<< is > 0 >>.

=head2 DEBUG($message, [@items])

Prints a debug C<$message> to STDERR if the debug level for the segment S<< is > 0 >>.

=head2 WARN($message, [@items])

Issues a warning with C<$message> via L<Carp::carp|Carp>.

=head2 ERROR($message, [@items])

Throws an error with C<$message> via L<Carp::croak|Carp>.

=head1 UTILITY ATTRIBUTES

None of these should be directly accessed.  Documented for contributors and source-code readers.

=head2 args

The arguments passed to the C<init> method of L<Piper>.

=cut

has args => (
    is => 'rwp',
    isa => ArrayRef,
    lazy => 1,
    builder => sub {
        my ($self) = @_;
        if ($self->has_parent) {
            return $self->main->args;
        }
        else {
            return [];
        }
    },
);

=head2 directory

A hashref of the segment's children, keyed by their labels.  Used by C<find_segment>.

=cut

has directory => (
    is => 'lazy',
    isa => HashRef,
    builder => sub {
        my ($self) = @_;
        return {} unless $self->has_children;
        my %dir;
        for my $child (@{$self->children}) {
            $dir{$child->path->name} = $child;
        }
        return \%dir;
    },
);

=head2 drain

A reference to the location where the segment's processed items are emitted.

=cut

BEGIN { # Enables 'with Piper::Role::Queue'
has drain => (
    is => 'lazy',
    handles => [qw(dequeue ready)],
    builder => sub {
        my ($self) = @_;
        if ($self->has_parent) {
            return $self->next_segment;
        }
        else {
            return $self->main->config->queue_class->new();
        }
    },
);
}

=head2 follower

A hashref of children paths to the child's next adjacent segment.  Used by C<next_segment>.

=cut

has follower => (
    is => 'lazy',
    isa => HashRef,
    builder => sub {
        my ($self) = @_;
        return {} unless $self->has_children;
        my %follow;
        for my $index (0..$#{$self->children}) {
            if (defined $self->children->[$index + 1]) {
                $follow{$self->children->[$index]} =
                    $self->children->[$index + 1];
            }
            else {
                $follow{$self->children->[$index]} = $self->drain;
            }
        }
        return \%follow;
    },
);

=head2 logger

A reference to the logger for the pipeline.  Handles L</LOGGING AND DEBUGGING> methods.

=cut

has logger => (
    is => 'lazy',
    isa => ConsumerOf['Piper::Role::Logger'],
    handles => 'Piper::Role::Logger',
    builder => sub {
        my ($self) = @_;
        
        if ($self->has_parent) {
            return $self->main->logger;
        }
        else {
            return $self->main->config->logger_class->new();
        }
    },
);

# Cute little trick to auto-insert the instance object
# as first argument, since $self will become the logger
# object and lose access to paths/labels/etc.
around [qw(INFO DEBUG WARN ERROR)] => sub {
    my ($orig, $self) = splice @_, 0, 2;
    if (ref $_[0]) {
        $self->$orig(@_);
    }
    else {
        $self->$orig($self, @_);
    }
};

=head2 queue

A reference to the location where data is queued for processing by this segment.

=cut

BEGIN { # Enables 'with Piper::Role::Queue'
has queue => (
    is => 'lazy',
    isa => ConsumerOf['Piper::Role::Queue'],
    handles => [qw(enqueue requeue)],
    builder => sub {
        my ($self) = @_;
        if ($self->has_children) {
            return $self->children->[0];
        }
        else {
            return $self->main->config->queue_class->new();
        }
    },
);
}

=head2 segment

The L<Piper> or L<Piper::Process> object from which the instance segment was created.

=cut

BEGIN { # So we can 'around' on Piper::Role::Segment methods
has segment => (
    is => 'ro',
    isa => ConsumerOf['Piper::Role::Segment'],
    handles => 'Piper::Role::Segment',
    required => 1,
);
}

=head1 UTILITY METHODS

None of these should be directly accessed.  Documented for contributors and source-code readers.

=head2 descendant($path, $referrer)

Returns a child segment if its path ends with C<$path>.  Does not search children with a path of C<$referrer>, as it was presumably already searched by a previous iteration of the search.  Used by C<find_segment>.

=cut

sub descendant {
    my ($self, $path, $referrer) = @_;
    return unless $self->has_children;
    $referrer //= '';

    $self->DEBUG("Searching for location '$path'");
    $self->DEBUG('Referrer', $referrer) if $referrer;

    # Search immediate children
    $path = Piper::Path->new($path) if $path and not ref $path;
    my @pieces = $path ? $path->split : ();
    my $descend = $self;
    while (defined $descend and @pieces) {
        if (!$descend->has_children) {
            $descend = undef;
        }
        elsif (exists $descend->directory->{$pieces[0]}) {
            $descend = $descend->directory->{$pieces[0]};
            shift @pieces;
        }
        else {
            $descend = undef;
        }
    }

    # Search grandchildren,
    #   but not when checking whether requested location starts at $self (referrer = $self)
    if (!defined $descend and $referrer ne $self) {
        my @possible;
        for my $child (@{$self->children}) {
            if ($child eq $referrer) {
                $self->DEBUG("Skipping search of '$child' referrer");
                next;
            }
            if ($child->has_children) {
                my $potential = $child->descendant($path);
                push @possible, $potential if defined $potential;
            }
        }

        if (@possible) {
            $descend = min_by { $_->path->split } @possible;
        }
    }

    # If location begins with $self->label, see if requested location starts at $self
    #   but not if already checking that (referrer = $self)
    if (!defined $descend and $referrer ne $self) {
        my $overlap = $self->label;
        if ($path =~ m{^\Q$overlap\E(?:$|/(?<path>.*))}) {
            $path = $+{path} // '';
            $self->DEBUG('Overlapping descendant search', $path ? $path : ());
            $descend = $path ? $self->descendant($path, $self) : $self;
        }
    }

    return $descend;
}

=head2 pressure

An integer metric for the "fullness" of the pending queue.  For handler instances (initialized from L<Piper::Process> objects), it is the percentage of pending items vs the batch size of the segment.  For container instances (initialized from L<Piper> objects), is is the maximum C<pressure> of the contained instances.  Used by process_batch for choosing which segment to process.

=cut

# Metric for "how full" the pending queue is
sub pressure {
    my ($self) = @_;
    if ($self->has_children) {
        return max(map { $_->pressure } @{$self->children});
    }
    else {
        return $self->pending ? (int(100 * $self->pending / $self->batch_size) || 1) : 0;
    }
}

=head2 process_batch

Chooses the "best" segment for processing, and processes a batch for that segment.

It first attempts to choose the full-batch segment (C<< pending >= batch_size >>) closest to the end of the pipeline.  If there are no full-batch segments, it chooses the segment closest to being full.

=cut

sub process_batch {
    my ($self) = @_;
    if ($self->has_children) {
        my $best;
        # Full-batch process closest to drain
        if ($best = last_value { $_->pressure >= 100 } @{$self->children}) {
            $self->DEBUG("Chose batch $best: full-batch process closest to drain");
        }
        # If no full batch, choose the one closest to full
        else {
            $best = max_by { $_->pressure } @{$self->children};
            $self->DEBUG("Chose batch $best: closest to full-batch");
        }
        $best->process_batch;
    }
    else {
        my $num = $self->batch_size;
        $self->DEBUG('Processing batch with max size', $num);

        my @batch = $self->queue->dequeue($num);
        $self->INFO('Processing batch', @batch);

        $self->segment->handler->(
            $self,
            \@batch,
            @{$self->args}
        );
    }
}

1;

__END__

=head1 SEE ALSO

=over

=item L<Piper>

=item L<Piper::Process>

=item L<Piper::Logger>

=back

=cut
