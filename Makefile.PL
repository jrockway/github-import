use strict;
use warnings;
use inc::Module::Install;

name 'Github-Import';
all_from 'lib/Github/Import.pm';

# requires: TODO

install_script 'bin/github-import';
WriteAll();
