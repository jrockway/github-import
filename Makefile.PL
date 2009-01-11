use strict;
use warnings;
use inc::Module::Install;

name 'Github-Import';
all_from 'lib/Github/Import.pm';

requires "Moose";
requires "MooseX::Declare";
requires "MooseX::Getopt";
requires "MooseX::Types::Path::Class";
requires "LWP::UserAgent";
requires "Crypt::SSLeay"; # https
requires "URI";
requires "String::TT";
requires "File::pushd";
requires "YAML::Tiny";
requires "File::HomeDir";
requires "Test::use::ok";
requires "Test::Exception";

install_script 'bin/github-import';
WriteAll();
