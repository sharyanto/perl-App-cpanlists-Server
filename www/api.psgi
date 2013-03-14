#!/usr/bin/env plackup

use 5.010;
use strict;
use warnings;

use DBI;
use File::Write::Rotate;
use JSON;
use Perinci::Access::Base::Patch::PeriAHS;
use Plack::Builder;
use Plack::Util::PeriAHS qw(errpage);
use App::cpanlists::Server;

my $json = JSON->new->allow_nonref;
my $conf = LoadFile "$ENV{HOME}/cpanlists-server.conf.json"; # $ENV{HOME} is empty if via fcgi, needs supplied
my $dbh = DBI->connect(
    "dbi:Pg:dbname=$conf->{dbname};host=localhost",
    $conf->{dbuser}, $conf->{dbpass});
App::cpanlists::Server::__dbh($dbh);

my $fwr = File::Write::Rotate->new(
    dir       => $conf->{riap_access_log_dir},
    prefix    => $conf->{riap_access_log_prefix},
    size      => $conf->{riap_access_log_size},
    histories => $conf->{riap_access_log_histories},
);

my $app = builder {
    enable(
        "PeriAHS::LogAccess",
        dest => $fwr,
    );

    #enable "PeriAHS::CheckAccess";

    enable(
        "PeriAHS::ParseRequest",
        #parse_path_info => $args{parse_path_info},
        #parse_form      => $args{parse_form},
        #parse_reform    => $args{parse_reform},
    );

    enable_if(
        sub {
            my $env = shift;
            my $rreq = $env->{'riap.request'};
            my $action = $rreq->{action};
            $rreq->{uri} =~ s!\Apl:/api/!pl:/!;
            my ($mod, $func) = $rreq->{uri} =~ m!\A(?:pl:)?/(.+)/(.+)!;
            # public actions
            return 0 if $action eq 'meta' ||
                $action eq 'call' && $mod eq 'App/cpanlists/Server' && $func =~ /\A(create_user|get_lists|list_lists)\z/;
            return 1;
        },
        "Auth::Basic",
        authenticator => sub {
                my ($user, $pass, $env) = @_;

                #my $role;
                my $res = App::cpanlists::Server::auth_user(
                    user => $user, pass=>$pass);
                if ($res->[0] == 200) {
                    $env->{"cpanlists.user_id"} = $res->[2]{id};
                    return 1;
                }
                return 0;
            },
        );

    enable(
        sub {
            my $app = shift;
            sub {
                my $env = shift;
                my $rreq = $env->{'riap.request'};

                $rreq->{uri} =~ s!\Apl:/api/!pl:/!;
                return errpage($env, [403,"Only cpanlists functions are currently allowed"])
                    unless $rreq->{uri} =~ m!\A(pl:)?(/App/cpanlists/Server/)!;

                #return errpage($env, [403, "Only call action is currently alllowed"])
                #    unless $rreq->{action} eq 'call';

                my ($mod, $func) = $rreq->{uri} =~ m!\A(?:pl:)?/(.+)/(.+)!;
                $mod =~ s!/!::!g;

                # authz
                {
                    my $uid  = $env->{"cpanlists.user_id"};
                    #my $role = $env->{"cpalists.user_role"};

                    # everybody can create/comment/like/unlike lists
                    last if $func =~ /^(create_list|comment_list|like_list|unlike_lists)$/;

                    # user can add item/delete item/delete lists he created
                    if ($role eq 'reseller' && $func =~ /^(delete_list|add_item|delete_item)$/) {
                        my $res = App::cpanlists::Server::get_list(id => $rreq->{args}{id}, items=>0);
                        return errpage($env, $res) if $res->[0] != 200;
                        return errpage($env, [403, "List does not exist or not yours"])
                            unless $res->[2]{creator} == $uid;
                        last;
                    }

                    # no other functions are available
                    return errpage($env, [403, "Unauthorized"]);
                }

                App::cpanlists::Server::__env($env);
                $app->($env);
            };
        },
    );

    enable "PeriAHS::Respond";
};

=head1 SYNOPSIS

To deploy as FastCGI script, see INSTALL.org. This will require a restart
(killing the FCGI process) whenever we modify the application.

For testing, you can run:

 % plackup api.psgi

To test the app:

 % curl http://localhost:5000/api/App/cpanlists/Server/list_lists
 % curl -u USER:PASS 'http://localhost:5000/api/App/cpanlists/Server/like_list?id=1'
 % curl -u USER:PASS 'http://localhost:5000/api/App/cpanlists/Server/unlike_list?id=1'


=head1 DESCRIPTION

=cut
