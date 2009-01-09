use MooseX::Declare;

class Github::Import with MooseX::Getopt {
    use MooseX::Types::Path::Class 'Dir';
    use LWP::UserAgent;
    use HTTP::Request::Common 'POST';
    use HTTP::Cookies;
    use URI;
    use String::TT 'tt';
    use File::pushd 'pushd';
    use namespace::clean -except => ['meta'];

    # command-line args
    has [qw/username password/] => (
        is       => 'ro',
        isa      => 'Str',
        required => 1,
    );

    has '+username' => ( default => sub { $ENV{USER} } );

    has dry_run => (
        isa => "Bool",
        is  => "ro",
    );

    has 'project' => (
        is       => 'ro',
        isa      => Dir,
        required => 1,
        coerce   => 1,
    );

    has 'project-name' => (
        reader   => 'project_name',
        isa      => 'Str',
        required => 0,
        default  => sub {
            my $self = shift;
            return Path::Class::File->new($self->project)->basename;
        },
    );

    has [qw/create add_remote push push_tags/] => (
        is       => 'ro',
        isa      => 'Bool',
        default  => sub { 1 },
        required => 1,
    );

    has push_all => (
        is  => "ro",
        isa => "Bool",
    );

    has remote => (
        is      => "ro",
        isa     => "Str",
        default => "github",
    );

    has refspec => (
        is      => "ro",
        isa     => "Str",
        default => "master",
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
        die $msg;
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
        return if $self->dry_run;
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

        $self->err('Error logging in')
          if !$res->is_success || $res->content =~ /incorrect login/i;
    }

    my $CREATE_URI = URI->new('http://github.com/repositories/new');
    my $CREATE_SUBMIT_URI = URI->new('http://github.com/repositories');
    method do_create(){
        return if $self->dry_run;
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
        $self->err('Error creating project') unless $res->is_success;
        return tt 'http://github.com/[% self.username %]/[% self.project_name %]/tree/master';
    };

    method run_git(Str $command, Bool :$ignore_errors, Bool :$print_output){
        if ( $self->dry_run ) {
            warn "/usr/bin/env git $command\n",
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
        my $push = tt 'git@github.com:[% self.username %]/[% self.project_name %].git';
        $self->run_git(
            "remote add $remote $push",
            ignore_errors => 1,
            print_output  => 0,
        );
    }

    method do_push() {
        my $remote = $self->remote;
        my $refspec = $self->refspec;

        my @args = $self->push_all
            ? ( "--all", $self->remote )
            : ( $self->push_tags ? "--tags" : (), $self->remote, $self->refspec );

        $self->run_git(
            "push @args",
            print_output => 1,
        );
    }
};

1;
