package Bot::Flowdock::IRC;
use Moose;
use MooseX::NonMoose;

use List::MoreUtils 'any';
use Net::Flowdock;
use Net::Flowdock::Stream;

extends 'Bot::BasicBot';

sub FOREIGNBUILDARGS {
    my $class = shift;
    my (%args) = @_;
    delete $args{$_} for qw(token key organization flow);
    return %args;
}

has token => (
    is  => 'ro',
    isa => 'Str',
    required => 1,
);

has key => (
    is  => 'ro',
    isa => 'Str',
);

has organization => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has flow => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has flowdock_api => (
    is      => 'ro',
    isa     => 'Net::Flowdock',
    lazy    => 1,
    default => sub {
        my $self = shift;
        Net::Flowdock->new(
            token => $self->token,
            ($self->key ? (key => $self->key) : ()),
        );
    }
);

has flowdock_stream => (
    is      => 'ro',
    isa     => 'Net::Flowdock::Stream',
    lazy    => 1,
    default => sub {
        my $self = shift;
        Net::Flowdock::Stream->new(
            token => $self->token,
            flows => [join('/', $self->organization, $self->flow)],
        );
    },
);

has _id_map => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => 'HashRef[Str]',
    default => sub { {} },
    handles => {
        name_from_id   => 'get',
        flowdock_names => 'values',
    },
);

sub has_flowdock_name {
    my $self = shift;
    my ($name) = @_;

    warn "checking $name";
    return any { $name eq $_ } $self->flowdock_names;
}

sub connected {
    my $self = shift;

    my $flow = $self->flowdock_api->get_flow({
        organization => $self->organization,
        flow         => $self->flow,
    });

    for my $user (@{ $flow->body->{users} }) {
        $self->_id_map->{$user->{id}} = $user->{name};
    }
}

sub tick {
    my $self = shift;

    for (1..20) {
        my $event = $self->flowdock_stream->get_next_event;

        last unless $event;
        next unless $event->{event} eq 'message';

        # skip if this is a message that we just sent
        next if exists $event->{external_user_name};

        my $name = $self->name_from_id($event->{user});
        $self->say(
            channel => ($self->channels)[0],
            body    => "<$name> $event->{content}",
        );
    }

    return 1;
}

sub said {
    my $self = shift;
    my ($args) = @_;

    $self->flowdock_api->push_chat({
        external_user_name => $args->{who},
        content            => $args->{body},
    });

    return;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;