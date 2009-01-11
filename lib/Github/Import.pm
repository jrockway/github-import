use MooseX::Declare;

class Github::Import with MooseX::Getopt {
    use Moose::Util::TypeConstraints qw(enum);
    use MooseX::Types::Path::Class qw(Dir File);
    use LWP::UserAgent;
    use HTTP::Request::Common 'POST';
    use HTTP::Cookies;
    use URI;
    use String::TT 'tt';
    use File::pushd 'pushd';
    use Path::Class;
    use Carp qw(croak);

    use namespace::clean -except => 'meta';

    our $VERSION = "0.01";

    has use_config_file => (
        traits  => [qw(NoGetopt)],
        isa     => "Bool",
        is      => "ro",
        default => 0,
    );

    # for the password
    has config_file => (
        traits        => [qw(Getopt)],
        isa           => File,
        is            => "ro",
        coerce        => 1,
        default       => sub {
            require File::HomeDir;
            dir(File::HomeDir->my_home)->file(".github-import");
        },
        cmd_flag      => "config-file",
        cmd_aliases   => "f",
        documentation => "a YAML file for your username/password (default is ~/.github-import)",
    );
    
    has config => (
        traits     => [qw(NoGetopt)],
        isa        => "HashRef",
        is         => "ro",
        lazy_build => 1,
    );

    sub _build_config {
        my $self = shift;

        if ( $self->use_config_file and -e ( my $file = $self->config_file ) ) {
            require YAML::Tiny;
            return YAML::Tiny::LoadFile($file);
        } else {
            return {};
        }
    }

    # command-line args
    has username => (
        traits      => [qw(Getopt)],
        is          => 'ro',
        isa         => 'Str',
        lazy_build  => 1,
        cmd_aliases => "u",
        documentation => 'username for github.com (defaults to $ENV{USER})',
    );

    sub _conf_var {
        my ( $self, $var, $default ) = @_;

        my $config = $self->config;

        if ( exists $config->{$var} ) {
            return $config->{$var};
        } else {
            return $default;
        }
    }

    sub _build_username { shift->_conf_var( username => $ENV{USER} ) }

    has password => (
        traits      => [qw(Getopt)],
        is          => 'ro',
        isa         => 'Str',
        lazy_build  => 1,
        cmd_aliases => "P",
        documentation => "password for github.com",
    );

    sub _build_password { shift->_conf_var("password") || croak "'password' is required" }

    has dry_run => (
        traits      => [qw(Getopt)],
        isa         => "Bool",
        is          => "ro",
        cmd_flag    => "dry-run",
        cmd_aliases => "n",
        documentation => "don't actually do anything",
    );

    has 'project' => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => Dir,
        default       => ".",
        coerce        => 1,
        cmd_aliases   => "d",
        documentation => "the directory of the repository (default is pwd)",
    );

    has project_name => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => 'Str',
        default       => sub {
            my $self = shift;
            return lc Path::Class::File->new($self->project->absolute)->basename;
        },
        cmd_flag      => "project-name",
        cmd_aliases   => "N",
        documentation => "the name of the project to create",
    );

    has create => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => 'Bool',
        lazy_build    => 1,
        cmd_aliases   => "c",
        documentation => "create the repo on github.com (default is true)",
    );

    sub _build_create { shift->_conf_var( create => 1 ) }

    has push => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => 'Bool',
        lazy_build    => 1,
        cmd_aliases   => "p",
        documentation => "run git push (default is true)",
    );

    sub _build_push { shift->_conf_var( push => 1 ) }

    has add_remote => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Bool",
        cmd_flag      => "add-remote",
        lazy_build    => 1,
        cmd_aliases   => "a",
        documentation => "add a remote for github to .git/config (defaults to true)",
    );

    sub _build_add_remote { shift->_conf_var( add_remote => 1 ) }

    has push_tags => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Bool",
        cmd_flag      => "tags",
        lazy_build    => 1,
        cmd_aliases   => "t",
        documentation => "specify --tags to push (default is true)",
    );

    sub _build_push_tags { shift->_conf_var( push_tags => 1 ) }

    has push_mode => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => enum([qw(all mirror)]),
        predicate     => "has_push_mode",
        cmd_flag      => "push-mode",
        cmd_aliases   => "m",
        documentation => "'all' or 'mirror', overrides other push options",
    );

    has remote => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Str",
        lazy_build    => 1,
        cmd_aliases   => "r",
        documentation => "the remote to add to .git/config (default is 'github')",
    );

    sub _build_remote { shift->_conf_var( remote => "github" ) }

    has refspec => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Str",
        lazy_build    => 1,
        cmd_aliases   => "b",
        documentation => "the refspec to specify to push (default is 'master')",
    );

    sub _build_refspec { shift->_conf_var( refspec => "master" ) }

    has push_uri => (
        traits        => [qw(Getopt)],
        isa           => "Str",
        is            => "ro",
        lazy          => 1,
        default       => sub {
            my $self = shift;
            tt 'git@github.com:[% self.username %]/[% self.project_name %].git';
        },
        cmd_flag      => "push-uri",
        cmd_aliases   => "u",
        documentation => "override the default github push uri",
    );

    # internals
    has 'user_agent' => (
        traits   => ['NoGetopt'],
        is       => 'ro',
        isa      => 'LWP::UserAgent',
        default  => sub {
            my $ua = LWP::UserAgent->new( requests_redirectable => [qw/GET POST/] );
            $ua->cookie_jar( HTTP::Cookies->new );
            return $ua;
        }
    );

    has 'logger' => (
        traits  => ['NoGetopt'],
        is      => 'ro',
        isa     => 'CodeRef',
        default => sub {
            sub { print {*STDERR} @_, "\n" },
        },
    );

    method msg(Str $msg){
        $self->logger->($msg);
    }

    method err(Str $msg){
        croak $msg;
    }

    method BUILD(HashRef $args){
        my $p = $self->project;
        confess "project '$p' does not exist" unless -d $p;
    }

    method run(){
        if($self->create){
            $self->msg('Logging in');
            $self->do_login;
            $self->msg('Logged in');

            $self->msg('Adding project to github');
            my $url = $self->do_create;
            $self->msg('Project added OK: '. $url);
        }

        if($self->add_remote){
            $self->msg(tt 'Adding remote "[% self.remote %]" to existing working copy');
            $self->do_add_remote;
            $self->msg('Remote added');
        };

        if($self->push){
            $self->msg('Pushing existing master to github');
            $self->do_push;
            $self->msg('Pushed OK');
        }
    };

    my $LOGIN_URI = URI->new('https://github.com/login');
    my $LOGIN_SUBMIT_URI = URI->new('https://github.com/session');
    method do_login() {
        if ( $self->dry_run ) {
            $self->username;
            $self->password;
            return;
        }
        my $ua = $self->user_agent;
        my $res = $ua->get($LOGIN_URI);
        $self->err('Error getting login page: ' . $res->status_line) unless $res->is_success;
        $res = $ua->request(
            POST( $LOGIN_SUBMIT_URI, [
                login    => $self->username,
                password => $self->password,
                submit   => 'Log in',
            ]),
        );

        $self->err('Error logging in: ' . $res->status_line) unless $res->is_success;
        $self->err('Incorrect login') if $res->content =~ /incorrect login/i;
    }

    my $CREATE_URI = URI->new('http://github.com/repositories/new');
    my $CREATE_SUBMIT_URI = URI->new('http://github.com/repositories');
    method do_create(){
        unless ( $self->dry_run ) {
            my $ua = $self->user_agent;
            my $res = $ua->get($CREATE_URI);
            $self->err('Error getting creation page: ' . $res->status_line) unless $res->is_success;
            $res = $ua->request(
                POST( $CREATE_SUBMIT_URI, [
                    'repository[name]'   => $self->project_name,
                    'repository[public]' => 'true',
                    'commit'             => 'Create repository',
                ]),
            );

            # XXX: not sure how to detect errors here, other than the obvious
            $self->err('Error creating project: ' . $res->status_line) unless $res->is_success;
        }
        return tt 'http://github.com/[% self.username %]/[% self.project_name %]/tree/master';
    };

    method run_git(Str $command, Bool :$ignore_errors, Bool :$print_output){
        if ( $self->dry_run ) {
            $self->msg("/usr/bin/env git $command");
        } else {
            my $dir = pushd $self->project;
            my $output = `/usr/bin/env git $command 2>&1`;
            $self->err("Error running 'git $command': $output")
              if $output =~ /^fatal:/sm && !$ignore_errors;
            $self->msg($output) if $output && $print_output;
        }
    }

    method do_add_remote() {
        my $remote = $self->remote;
        my $push   = $self->push_uri;
        $self->run_git(
            "remote add $remote $push",
            ignore_errors => 1,
            print_output  => 0,
        );
    }

    method do_push() {
        my $remote = $self->add_remote ? $self->remote : $self->push_uri;
        my $refspec = $self->refspec;

        my @args = $self->has_push_mode
            ? ( "--" . $self->push_mode, $self->remote )
            : ( $self->push_tags ? "--tags" : (), $remote, $self->refspec );

        $self->run_git(
            "push @args",
            print_output => 1,
        );
    }
};

1;

__END__

=pod

=head1 NAME

Github::Import - Import your project into L<http://github.com>

=head1 SYNOPSIS

    % cd some_project_in_git
    % github-import --username jrockway --password whatever --add-remote --push-mode all

You can also create a config file. Here is an example using a real man's editor:

    % cat > ~/.github-import
    ---
    username: jrockway
    password: ilovehellokitty
    remote:   origin # if you don't like "github"
    ^D
    % cd some_other_project_in_git
    % github-import

=head1 DESCRIPTION

This class/script provides a way to import a git repository into
L<http://github.com>.

=head1 CONFIGURATION

The configuration file is a YAML file whose values are used as defaults for the
attributes docuented below.

If no value is specified in the config file, the default one in the
documentation will be used.

For instance to not push to github, set:

    push: 0

You can override on the command line by specifying C<--no-push> or C<--push>
depending on what you have in the file and what is the default.

=head1 ATTRIBUTES

=over 4

=item dry_run

If true nothing will actually be done, but the output will be printed.

=item config_file

Defaults to C<~/.github-import>.

This is a YAML file containing values for attributes.

=item use_config_file

Defaults to false.

The C<github-import> command line tool sets this attribute.

=item username

The username for github.com

If none is provided or in the config file uses C<$ENV{USER}>.

=item password

The password for github.com

=item remote

The name of the remote to create if C<add_remote> is specified.

Defaults to C<github>.

=item project

The directory to imoport.

Defaults to the current directory.

=item project_name

The project name to use when creating on github.

Defaults to the basename of C<project>.

=item create

If true a repository will be created on github.

Defaults to true. Requires C<username> and C<password>.

=item add_remote

If true a remote will be added for the github repository.

Defaults to true.

=item push

If true the repository will be pushed to github.

Defaults to true.

=item tags

If true C<--tags> will be given to C<git push>.

Defaults to true.

=item refspec

The refspec to push, given to C<git push>.

Defaults to C<master>.

If you want to push all your branches set to C<refs/heads/*:refs/heads/*>.

=item push_mode

One of C<all> or C<mirror>.

If specified, C<git push --all> or C<git push --mirror> is run instead of
pushing with a refspec.

Overrides C<refspec> and C<tags>.

=item push_uri

Defaults to the SSH push URI for your github repository.

=back

=head1 METHODS

=over 4

=item new_with_options

L<MooseX::Getopt>

=item run

Import the repository by running all steps

=item do_login

Login the L<LWP::UserAgent> instance to github.

=item do_create

Create the repository by submitting a form.

=item do_add_remote

Add a remote entry for github to C<.git/config>.

=item do_push

Run C<git push>.

=back

=head1 VERSION CONTROL

L<http://github.com/jrockway/github-import>

=head1 AUTHORS

Jonathan Rockway

Yuval Kogman

=head1 LICENSE

MIT

=head1 COPYRIGHT

    Copyright 2009 Jonathan Rockway, Yuval Kogman, ALl rights reserved

=cut
