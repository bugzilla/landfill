#!/usr/bin/perl -wT

use strict;
use lib qw(.);
use Landfill;

my $cgi = Landfill->cgi;
my $template = Landfill->template;

print $cgi->header;
$template->process('index.html.tmpl') or die $template->error;
