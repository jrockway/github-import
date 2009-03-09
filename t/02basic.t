#!/usr/bin/perl

use strict;
use warnings;

use Test::More 'no_plan';

use ok 'Github::Import';
use Test::Exception;

use Path::Class;

my $dist = file(__FILE__)->parent->parent;

my @log;

my $g = Github::Import->new(
    username => "foo",
    token    => "hellokitty",
    project  => $dist->subdir("lib"),
    dry_run  => 1,
    logger   => sub {
        push @log, [@_];
    },
);

is( $g->project, $dist->subdir("lib"), "project path" );
is( $g->project_name, "lib", "project name from path" );

is_deeply( \@log, [], "no log output" );

lives_ok { $g->run } "dry run";

ok( scalar(@log), "log output" );

my $log = join("\n", map { @$_ } @log);

like( $log, qr/adding project to github/i, "created on github" );
like( $log, qr/git remote add/, "remote added" );
like( $log, qr/git push --tags github master/, "pushed" );

