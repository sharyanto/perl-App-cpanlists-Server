package App::cpanlists::Server;

use 5.010001;
use strict;
use warnings;
use Log::Any qw($log);

# VERSION

use JSON;
use MetaCPAN::API;
#use Perinci::Sub::Util qw(wrapres);
use SHARYANTO::SQL::Schema 0.04;

# TODO: use CITEXT columns when migrating to postgres 9.1+

our %SPEC;
my $json = JSON->new->allow_nonref;

my $spec = {
    latest_v => 1,

    install => [
        q[CREATE TABLE "user" (
            id SERIAL PRIMARY KEY,
            -- roles TEXT[],
            username VARCHAR(64) NOT NULL, UNIQUE(username),
            first_name VARCHAR(128),
            last_name VARCHAR(128),
            email VARCHAR(128), UNIQUE(email),
            password VARCHAR(255) NOT NULL,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            note TEXT
        )],

        q[CREATE TABLE list (
            id SERIAL PRIMARY KEY,
            creator INT NOT NULL REFERENCES "user"(id),
            name VARCHAR(255) NOT NULL, UNIQUE(name), -- citext
            -- XXX type: module, author
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE item (
            id SERIAL PRIMARY KEY,
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL, UNIQUE(list_id, name),
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_comment (
            list_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL, UNIQUE(list_id, name),
            comment TEXT,
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            mtime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE list_like (
            item_id INT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
            user_id INT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
            UNIQUE(item_id, user_id),
            -- XXX UNIQUE(user_id),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )],

        q[CREATE TABLE activity_log (
            user_id INT REFERENCES "user"(id),
            action VARCHAR(32),
            ctime TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ip INET,
            note TEXT
        )],
    ],
};

sub __dbh {
    state $dbh;
    if (@_) {
        $dbh = $_[0];
    }
    $dbh;
}

sub __env {
    state $env;
    if (@_) {
        $env = $_[0];
    }
    $env;
}

sub __init_db {
    SHARYANTO::SQL::Schema::create_or_update_db_schema(
        dbh => __dbh, spec => $spec,
    );
}

sub __activity_log {
    my %args = @_;

    __dbh()->do(q[INSERT INTO activity_log (ip,action,"user",note) VALUES (?,?,?,?)],
             {},
             (__env() ? __env->{REMOTE_ADDR} : $ENV{REMOTE_ADDR}),
             $args{action},
             (__env() ? __env->{REMOTE_USER} : $ENV{REMOTE_USER}),
             (ref($args{note}) ? $json->encode($args{note}) : $args{note}),
         )
        or $log->error("Can't log activity: ".__dbh->errstr);
}

my $sch_username = ['str*' => {
    # temporarily disabled because perl 5.12 stringifies regex differently and
    # unsupported by 5.10.
    # match => qr/\A\w+\z/,
    min_len => 4,
    max_len => 32,
}];
my $sch_password = ['str*' => min_len=>6, max_len=>72];
#my $sch_ip = ['str*' => {
#    # temporarily disabled because perl 5.12 stringifies regex differently and
#    # unsupported by 5.10.
#    # match => qr/\A\d{1,3}+\.\d{1,3}+\.\d{1,3}+\.\d{1,3}+\z/,
#}];

$SPEC{create_user} = {
    v => 1.1,
    args => {
        username => {
            schema => $sch_username,
            req => 1,
        },
        email => {
            schema => ['str*', {
                # match => qr/\A\S+\@\S+\z/,
            }],
            req => 1,
        },
        password => {
            schema => $sch_password,
            req => 1,
        },
        first_name => {
            schema => ['str'],
        },
        last_name => {
            schema => ['str'],
        },
        note => {
            schema => ['str'],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub create_user {
    require Authen::Passphrase::BlowfishCrypt;

    my %args = @_; # VALIDATE_ARGS

    # TMP
    $args{username} =~ /\A\w+\z/ or return [400, "Invalid username syntax"];

    my $ppr = Authen::Passphrase::BlowfishCrypt->new(cost=>8, salt_random=>1, passphrase=>$args{password});

    __dbh->do(q[INSERT INTO "user" (username,email,password, first_name,last_name, note) VALUES ('{"reseller"}', ?,?,?, ?,?,?, ?)],
             {},
             $args{username}, $args{email}, $ppr->as_crypt,
             $args{first_name}, $args{last_name},
             $args{note},
         )
        or return [500, "Can't create user: " . __dbh->errstr];
    [200, "OK", { id=>__dbh->last_insert_id(undef, undef, "user", undef) }];
}

$SPEC{get_user} = {
    v => 1.1,
    summary => 'Get user information either by email or username',
    args => {
        username => {
            schema => ['str*'],
        },
        email => {
            schema => ['str*'],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub get_user {
    my %args = @_; # VALIDATE_ARGS
    # TMP, schema
    $args{username} || $args{email}
        or return [400, "Please specify either email/username"];
    my $row;
    if ($args{username}) {
        $row = __dbh->selectrow_hashref(q[SELECT * FROM "user" WHERE username=?], {}, $args{username});
    } else {
        $row = __dbh->selectrow_hashref(q[SELECT * FROM "user" WHERE email=?], {}, $args{email});
    }

    return [404, "No such user"] unless $row;

    # delete sensitive fields
    delete $row->{password};
    #delete $row->{id} unless ...;

    [200, "OK", $row];
}

$SPEC{auth_user} = {
    v => 1.1,
    summary => 'Check username and password against database',
    args => {
        username => {
            # for auth, we don't need elaborate schemas
            #schema => $sch_username,
            schema => ['str*'],
            req => 1,
        },
        password => {
            # for auth, we don't need elaborate schemas
            #schema => $sch_password,
            schema => ['str*'],
            req => 1,
        },
    },
    description => <<'_',

Upon success, will return a hash of information, currently: `id` (user numeric
ID), `email`.

_
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub auth_user {
    require Authen::Passphrase;

    my %args = @_; # VALIDATE_ARGS

    my $row = __dbh->selectrow_hashref(q[SELECT password,id,email FROM "user" WHERE username=?], {}, $args{username});
    return [403, "Authentication failed"] unless $row;

    my $ppr = Authen::Passphrase->from_crypt($row->{password});
    if ($ppr->match($args{password})) {
        return [200, "Authenticated", {id=>$row->{id}, email=>$row->{email}, roles=>$row->{roles}}];
    } else {
        return [403, "Authentication failed"];
    }
}

$SPEC{list_lists} = {
    v => 1.1,
    summary => 'List available lists',
    args => {
        query => {
            schema => ['str*'],
            cmdline_aliases => {q => {}},
            pos => 0,
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub list_lists {
    my %args = @_; # VALIDATE_ARGS

    my $q = $args{query} // '';
    my $qq = __dbh->quote($q);
    $qq =~ s/\A'//; $qq =~ s/'\z//;
    my $sth = __dbh->prepare("
SELECT * FROM list WHERE
  name LIKE '%$qq%' OR
  comment LIKE '%$qq%'
");
    $sth->execute;
    my @rows;
    while (my $row = $sth->fetchrow_hashref) { push @rows, $row }

    [200, "OK", \@rows];
}

$SPEC{get_list} = {
    v => 1.1,
    summary => 'Get details about a list',
    args => {
        id => {
            schema => ['int*'],
            req => 1,
            pos => 0,
        },
        items => {
            summary => "Whether to retrieve list's items",
            schema => ['bool*' => default => 1],
        },
    },
    "_perinci.sub.wrapper.validate_args" => 0,
};
sub get_list {
    my %args = @_; # VALIDATE_ARGS
    my $row = __dbh->selectrow_hashref("SELECT * FROM list WHERE id=?", {}, $args{id});

    return [404, "No such list"] unless $row;

    [200, "OK", $row];
}

1;
#ABSTRACT: Application that runs on cpanlists.org

=head1 SYNOPSIS

See L<App::cpanlists> for the client program.


=head1 DESCRIPTION

Currently to use this module, you have to do two things. This is ugly and might
change in the future.

=over

=item * Set database handle at startup

 $dbh = DBI->connect(...);
 App::cpanlists::Server::__dbh($dbh);

=item * Set PSGI environment for each request

Mainly so that __activity_log() can get REMOTE_ADDR etc from PSGI environment.

 App::cpanlists::Server::__env($env);

=back


=head1 TODO


=head1 SEE ALSO

L<App::cpanlists>

=cut
