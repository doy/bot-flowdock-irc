package Bot::Flowdock::IRC;
use Moose;
use MooseX::NonMoose;

use JSON;
use List::MoreUtils 'any';
use Net::Flowdock 0.03;
use Net::Flowdock::Stream;
use String::Truncate 'elide';
use WWW::Shorten 'GitHub';

extends 'Bot::BasicBot';

sub FOREIGNBUILDARGS {
    my $class = shift;
    my (%args) = @_;
    delete $args{$_} for qw(email token key organization flow);
    return %args;
}

# XXX require this for now so that we can tell which account is the bot
# (to allow us to filter those out so we don't get echos)
# ideally, there would be a better way to detect this
has email => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

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

has _my_id => (
    is  => 'rw',
    isa => 'Int',
);

sub connected {
    my $self = shift;

    my $flow = $self->flowdock_api->get_flow({
        organization => $self->organization,
        flow         => $self->flow,
    });

    for my $user (@{ $flow->body->{users} }) {
        $self->_set_name_for_id($user->{id}, $user->{nick});
        if ($user->{email} eq $self->email) {
            $self->_my_id($user->{id});
        }
    }
}

sub tick {
    my $self = shift;

    for (1..20) {
        my $event = $self->flowdock_stream->get_next_event;

        last unless $event;

        next if $event->{user} == $self->_my_id;

        my $app = $event->{app} || '';
        my $type = $event->{event};

        if ($app eq 'chat') {
            if ($type eq 'message' || $type eq 'line') {
                $self->flowdock_message($event);
            }
            elsif ($type eq 'status') {
                $self->flowdock_status($event);
            }
            elsif ($type eq 'user-edit') {
                $self->flowdock_user_edit($event);
            }
            else {
                warn "Unknown chat event type $type: " . encode_json($event);
            }
        }
        elsif ($app eq 'influx') { # i think this is timeline stuff
            if ($type eq 'vcs' && any { /^github/ } @{ $event->{tags} }) {
                $self->flowdock_github_event($event);
            }
            else {
                $self->flowdock_unknown_inbox_event($event);
            }
        }
        else {
            # we don't care activity events
            if ($type ne 'activity.user') {
                warn "Unknown event type $type for unknown app $app: " . encode_json($event);
            }
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
    $self->_say_to_channel(
        $event->{content}, $name,
        emoted => ($event->{event} eq 'line' || $event->{event} eq 'status')
    );
}

sub flowdock_status {
    my $self = shift;
    my ($event) = @_;

    $self->flowdock_message($event);
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

sub flowdock_github_event {
    my $self = shift;
    my ($event) = @_;

    my $content = $event->{content};

    my $pusher = $content->{pusher}{name};
    $pusher = $content->{commits}[0]{author}{username} . '(?)'
        if $pusher eq 'none'; # XXX ?
    my $commits = @{ $content->{commits} };
    my $repo = $content->{repository}{name};
    (my $branch = $content->{ref}) =~ s{^refs/heads/}{};
    my $compare = makeashorterlink($content->{compare});
    my $commit_messages = join(' / ', map { $_->{message} }
                                          @{ $content->{commits} });

    my $msg = "[github] $pusher pushed $commits commit"
            . ($commits == 1 ? '' : 's')
            . " to $repo/$branch (compare $compare): $commit_messages";

    $self->_say_to_channel($msg);
}

sub flowdock_unknown_inbox_event {
    my $self = shift;
    my ($event) = @_;

    warn "unknown timeline event type $event->{event}: " . encode_json($event);
    $self->_say_to_channel("[$event->{event}] unknown");
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

sub nick_change {
    my $self = shift;
    my ($old, $new) = @_;

    $self->_say_to_flowdock("$old is now known as $new");
}

sub _say_to_channel {
    my $self = shift;
    my ($body, $from, %params) = @_;

    if (defined($from)) {
        $body = $params{emoted} ? "* $from $body" : "<$from> $body";
    }
    else {
        $body = "-!- $body";
    }

    $body =~ s/\n/ /g;
    $body = elide($body, 275, { at_space => 1 });

    $self->say(
        channel => ($self->channels)[0],
        body    => $body,
    );
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
