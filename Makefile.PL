use strict;
use warnings;
use inc::Module::Install 0.77;

name 'Github-Import';
all_from 'lib/Github/Import.pm';

requires "Moose" => "0.64";
requires "MooseX::Declare";
requires "MooseX::Getopt";
requires "MooseX::Types::Path::Class";
requires "LWP::UserAgent";
requires "URI";
requires "File::pushd";
requires "File::HomeDir";
requires "Test::use::ok";
requires "Test::Exception";
requires "Git";

install_script 'bin/github-import';
WriteAll();
