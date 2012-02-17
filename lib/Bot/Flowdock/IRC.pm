package Bot::Flowdock::IRC;
use Moose;
use MooseX::NonMoose;

use JSON;
use List::MoreUtils 'any';
use Net::Flowdock 0.03;
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
    isa     => 'HashRef[Str]',
    default => sub { {} },
    handles => {
        _set_name_for_id => 'set',
        name_from_id     => 'get',
        flowdock_names   => 'values',
    },
);

sub connected {
    my $self = shift;

    my $flow = $self->flowdock_api->get_flow({
        organization => $self->organization,
        flow         => $self->flow,
    });

    for my $user (@{ $flow->body->{users} }) {
        $self->_set_name_for_id($user->{id}, $user->{nick});
    }
}

sub tick {
    my $self = shift;

    for (1..20) {
        my $event = $self->flowdock_stream->get_next_event;

        last unless $event;

        my $type = $event->{event};

        if ($type eq 'message') {
            $self->flowdock_message($event);
        }
        elsif ($type eq 'user-edit') {
            $self->flowdock_user_edit($event);
        }
        elsif ($type eq 'activity.user') {
            # ignore it
        }
        else {
            warn "Unknown event type $type: " . encode_json($event);
        }
    }

    return 1;
}

sub flowdock_message {
    my $self = shift;
    my ($event) = @_;

    # skip if this is a message that we just sent
    return if exists $event->{external_user_name};

    my $name = $self->name_from_id($event->{user});
    $self->_say_to_channel($event->{content}, $name);
}

sub flowdock_user_edit {
    my $self = shift;
    my ($event) = @_;

    my $id = $event->{user};
    my $nick = $event->{content}{user}{nick};
    my $oldnick = $self->name_from_id($id);

    $self->_say_to_channel("$oldnick is now known as $nick");

    $self->_set_name_for_id($id, $nick);
}

sub said {
    my $self = shift;
    my ($args) = @_;

    my $address = $args->{address} || '';

    return if $address eq 'msg';

    # XXX: Bot::BasicBot does a lot of "helpful" munging of messages that we
    # receive. this is annoying for this use case. look into switching to raw
    # poco::irc at some point.
    my $msg = ($address ? "$address: " : '') . $args->{body};

    # XXX when they allow external users to post status update events, fix this
    $msg = '*' . $msg . '*'
        if $args->{emoted};

    $self->_say_to_flowdock($msg, $args->{who});

    return;
}

around emoted => sub {
    my $orig = shift;
    my $self = shift;
    my ($args) = @_;
    $args->{emoted} = 1;
    return $self->$orig($args);
};

sub _say_to_channel {
    my $self = shift;
    my ($body, $from) = @_;

    if (defined($from)) {
        $self->say(
            channel => ($self->channels)[0],
            body    => "<$from> $body",
        );
    }
    else {
        $self->say(
            channel => ($self->channels)[0],
            body    => "-!- $body",
        );
    }
}

sub _say_to_flowdock {
    my $self = shift;
    my ($body, $from) = @_;

    if (defined($from)) {
        $self->flowdock_api->push_chat({
            external_user_name => $from,
            content            => $body,
        });
    }
    else {
        $self->flowdock_api->send_message({
            organization => $self->organization,
            flow         => $self->flow,
            event        => 'status',
            content      => $body,
        });
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
