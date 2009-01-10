use MooseX::Declare;

class Github::Import with MooseX::Getopt {
	use File::HomeDir;
    use Moose::Util::TypeConstraints qw(enum);
    use MooseX::Types::Path::Class qw(Dir File);
    use LWP::UserAgent;
    use HTTP::Request::Common 'POST';
    use HTTP::Cookies;
    use URI;
    use String::TT 'tt';
    use File::pushd 'pushd';
	use Path::Class;
	use YAML::Tiny qw(LoadFile);

    use namespace::clean -except => 'meta';

	# for the password
	has config_file => (
        traits  => [qw(Getopt)],
		isa     => File,
		is      => "ro",
		default => sub { dir(File::HomeDir->my_home)->file(".github-import") },
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
		
		if ( -e ( my $file = $self->config_file ) ) {
			return LoadFile($file);
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

	sub _build_username { shift->config->{username} || $ENV{USER} }

    has password => (
        traits      => [qw(Getopt)],
        is          => 'ro',
        isa         => 'Str',
		lazy_build  => 1,
        cmd_aliases => "p",
        documentation => "password for github.com",
    );

	sub _build_password { shift->config->{password} || die "'password' is required" }

    has dry_run => (
        traits      => [qw(Getopt)],
        isa         => "Bool",
        is          => "ro",
        cmd_flag    => "dry-run",
        cmd_aliases => "n",
        documentation => "don't actually do anything",
    );

    has 'project' => (
        traits   => [qw(Getopt)],
        is       => 'ro',
        isa      => Dir,
        default  => ".",
        coerce   => 1,
        documentation => "the directory of the repository (default is pwd)",
    );

    has project_name => (
        traits   => [qw(Getopt)],
        is       => 'ro',
        isa      => 'Str',
        default  => sub {
            my $self = shift;
            return lc Path::Class::File->new($self->project->absolute)->basename;
        },
        cmd_flag => "project-name",
        documentation => "the name of the project to create",
    );

    has create => (
        traits  => [qw(Getopt)],
        is      => 'ro',
        isa     => 'Bool',
        default => 1,
        documentation => "create the repo on github.com (default is true)",
        cmd_aliases => "c",
    );

    has push => (
        traits  => [qw(Getopt)],
        is      => 'ro',
        isa     => 'Bool',
        default => 1,
        documentation => "run git push (default is true)",
    );

    has add_remote => (
        traits   => [qw(Getopt)],
        is       => "ro",
        isa      => "Bool",
        cmd_flag => "add-remote",
        default  => 1,
        documentation => "add a remote for github to .git/config (defaults to true)",
    );

    has push_tags => (
        traits   => [qw(Getopt)],
        is       => "ro",
        isa      => "Bool",
        cmd_flag => "tags",
        default  => 1,
        documentation => "specify --tags to push (default is true)",
    );

    has push_mode => (
        traits    => [qw(Getopt)],
        is        => "ro",
        isa       => enum([qw(all mirror)]),
        predicate => "has_push_mode",
        cmd_flag  => "push-mode",
        documentation => "'all' or 'mirror', overrides other push options",
    );

    has remote => (
        traits     => [qw(Getopt)],
        is         => "ro",
        isa        => "Str",
		lazy_build => 1,
        documentation => "the remote to add to .git/config (default is 'github')",
    );

	sub _build_remote { shift->config->{remote} || "github" }

    has refspec => (
        traits     => [qw(Getopt)],
        is         => "ro",
        isa        => "Str",
		lazy_build => 1,
        documentation => "the refspec to specify to push (default is 'master')",
    );

	sub _build_refspec { shift->config->{refspec} || "master" }

    has push_uri => (
        isa     => "Str",
        is      => "ro",
        lazy    => 1,
        default => sub {
            my $self = shift;
            tt 'git@github.com:[% self.username %]/[% self.project_name %].git';
        },
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

        $self->err('Error logging in: ' . $res->status_line)
          if !$res->is_success || $res->content =~ /incorrect login/i;
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
            : ( $self->push_tags ? "--tags" : (), $self->remote, $self->refspec );

        $self->run_git(
            "push @args",
            print_output => 1,
        );
    }
};

1;
