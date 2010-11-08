#!/usr/bin/perl -wT
# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Landfill Tools System.
#
# The Initial Developer of the Original Code is Everything Solved, Inc.
# Portions created by the Initial Developers are Copyright (C) 2010 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Max Kanat-Alexander <mkanat@bugzilla.org>

use strict;
use lib qw(.);
use Landfill;

my $cgi = Landfill->cgi;
my $action = trim($cgi->param('action') || '');

if ($action eq "") { page_default(); }
elsif ($action eq "add") { page_add(); }
elsif ($action eq "new") { page_new(); }
elsif ($action eq "del") { page_delete(); }
else { die "Unknown action: $action"; }

# action=add -> Add a new install.
sub page_add {
    my $cgi = Landfill->cgi;
    my $template = Landfill->template;
    my $branches = bzr_branches();
    my %vars = ( branches => $branches );
    print $cgi->header();
    $template->process('installs/add.html.tmpl', \%vars) 
        or die $template->error;
}

# action='' -> No action specified, show main page.
sub page_default {
    my $cgi = Landfill->cgi;
    my $dbh = Landfill->dbh;
    my $template = Landfill->template;
    my $installs = $dbh->selectall_arrayref(
        'SELECT install_id, name, url, contact, mailto 
           FROM installs ORDER BY delete_at, name', {Slice=>{}});
    my %vars = ( installs => $installs );
    print $cgi->header();
    $template->process('installs/index.html.tmpl', \%vars) 
        or die $template->error;
}

# action='del' -> Schedule an install for deletion.
sub page_delete {
    my $cgi = Landfill->cgi;
    my $dbh = Landfill->dbh;
    my $template = Landfill->template;

    my $id = $cgi->param('install');
    detaint_natural($id);
    my $install = $dbh->selectrow_hashref(
        'SELECT * FROM installs WHERE install_id = ?', undef, $id);
    die "No install with id $id" if !$install;

    my $has_patches = $dbh->selectrow_array(
        'SELECT 1 FROM patches WHERE install_id = ?', undef, $id);
    if ($has_patches) {
        die "This install has patches associated with it, you must"
            . " delete them first";
    }

    $dbh->do('UPDATE installs SET delete_me = 1 WHERE install_id = ?',
             undef, $id);
    print $cgi->header;
    $template->process('installs/deleted.html.tmpl', { install => $install })
        or die $template->error;
}

# action="new" -> Actually create the install
sub page_new {
    my $cgi = Landfill->cgi;
    my $dbh = Landfill->dbh;
    my $template = Landfill->template;

    print $cgi->header();

    my ($values, $errors) = validate_install(
        scalar $cgi->Vars, { check_exists => 1 });

    if (@$errors) {
        $template->process('global/error.html.tmpl', { errors => $errors })
            or die $template->error;
        exit;
    }

    foreach my $key (keys %$values) {
        trick_taint($values->{$key});
    }

    $dbh->do('INSERT INTO installs (name, url, contact, mailto, db, branch, 
                                    user) VALUES (?,?,?,?,?,?,?)', undef,
             $values->{name}, "/$values->{name}/", $values->{contact},
             $values->{mailto}, $values->{db}, $values->{branch}, 
             $values->{user});

    $template->process('installs/added.html.tmpl', 
                       { url => "/$values->{name}/" }) or die $template->error;
}
