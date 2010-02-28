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
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Everything Solved, Inc.
# Portions created by the Initial Developers are Copyright (C) 2010 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Max Kanat-Alexander <mkanat@bugzilla.org>

package Landfill;
use strict;
use base qw(Exporter);
our @EXPORT = qw(
    bzr_branches
    detaint_natural
    random_string
    trick_taint
    trim
    validate_install
);

# We want any compile errors to get to the browser, if possible.
BEGIN {
    # This makes sure we're in a CGI.
    if ($ENV{SERVER_SOFTWARE} && !$ENV{MOD_PERL}) {
        require CGI::Carp;
        CGI::Carp->import('fatalsToBrowser');
    }
}

use CGI qw(-no_xhtml -oldstyle_urls :private_tempfiles :unique_headers -utf8);
use DBI;
use Email::Address;
use File::Basename;
use Template;
$| = 1;
$::SIG{TERM} = 'IGNORE';
$::SIG{PIPE} = 'IGNORE';
$::SIG{__DIE__} = \&CGI::Carp::confess;

use constant BZR_REPO => 'bzr://bzr.mozilla.org/bugzilla';

use constant TEMPLATE_CONFIG => {
    INCLUDE_PATH => ['template'],
    PRE_CHOMP => 1,
    TRIM => 1,
    ENCODING => 'UTF-8',
    FILTERS => {
        js => sub {
            my ($var) = @_;
            $var =~ s/([\\\'\"\/])/\\$1/g;
            $var =~ s/\n/\\n/g;
            $var =~ s/\r/\\r/g;
            $var =~ s/\@/\\x40/g; # anti-spam for email addresses
            $var =~ s/</\\x3c/g;
            return $var;
        },
    },
};


# Note that this is a raw subroutine, not a method, so $class isn't available.
sub init_page {
    (binmode STDOUT, ':utf8');

    if (${^TAINT}) {
        # Some environment variables are not taint safe
        delete @::ENV{'PATH', 'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
        # Some modules throw undefined errors (notably File::Spec::Win32) if
        # PATH is undefined.
        $ENV{'PATH'} = '/var/www/html/tools/bin:/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin';
    }

    # Because this function is run live from perl "use" commands of
    # other scripts, we're skipping the rest of this function if we get here
    # during a perl syntax check (perl -c, like we do during the
    # 001compile.t test).
    return if $^C;
}

init_page();

sub cgi {
    my $class = shift;
    if (!$class->request_cache->{cgi}) {
        my $cgi = new CGI();
        $cgi->charset('UTF-8');
        $class->request_cache->{cgi} = $cgi;
    }
    return $class->request_cache->{cgi};
}

sub dbh {
    my $class = shift;
    return $class->request_cache->{dbh} if $class->request_cache->{dbh};

    my %attributes = (
        RaiseError => 1,
        AutoCommit => 1,
        PrintError => 0,
        ShowErrorStatement => 1,
        TaintIn => 1,
        FetchHashKeyName => 'NAME_lc',
        mysql_enable_utf8 => 1,
    );
    my $dsn = 'dbi:mysql:database=tools';
    my $db_pass = get_db_pass();
    my $dbh = DBI->connect($dsn, 'tools', $db_pass, \%attributes);
    $dbh->do("SET NAMES utf8");
    $class->request_cache->{dbh} = $dbh;
    return $dbh;
}

our $_request_cache = {};
sub request_cache {
    if ($ENV{MOD_PERL}) {
        require Apache2::RequestUtil;
        # Sometimes (for example, during mod_perl.pl), the request
        # object isn't available, and we should use $_request_cache instead.
        my $request = eval { Apache2::RequestUtil->request };
        return $_request_cache if !$request;
        return $request->pnotes();
    }
    return $_request_cache;
}

sub template {
    my $class = shift;
    $class->request_cache->{template} ||= Template->new(TEMPLATE_CONFIG);
    return $class->request_cache->{template};
}

###############
# Subroutines #
###############

sub bzr_branches {
    my $repo = BZR_REPO;
    my $branch_list = `bzr branches $repo`;
    my @branches = split("\n", $branch_list);
    my @valid = reverse grep(/^\d+\.\d+/, @branches);
    unshift(@valid, 'trunk');
    return \@valid;
}

sub detaint_natural {
    my $match = $_[0] =~ /^(\d+)$/;
    $_[0] = $match ? int($1) : undef;
    return (defined($_[0]));
}

sub get_db_pass {
    my $db_pass;
    my $path = dirname(__FILE__);
    open(my $fh, '<', "$path/db_pass") or die "$path/db_pass: $!";
    $db_pass = <$fh>;
    chomp($db_pass);
    close($fh);
    return $db_pass;
}

sub random_string {
    my $size = shift || 10; # default to 10 chars if nothing specified
    return join("", map{ ('0'..'9','a'..'z','A'..'Z')[rand 62] } (1..$size));
}

sub trim {
    my ($str) = @_;
    if ($str) {
        $str =~ s/^\s+//g;
        $str =~ s/\s+$//g;
    }
    return $str;
}

sub trick_taint {
    require Carp;
    Carp::confess("Undef to trick_taint") unless defined $_[0];
    my $match = $_[0] =~ /^(.*)$/s;
    $_[0] = $match ? $1 : undef;
    return (defined($_[0]));
}

sub validate_install {
    my ($params, $opts) = @_;

    my $dbh = Landfill->dbh;

    my (%values, @errors);
    foreach my $field (qw(name contact mailto user branch db)) {
        $params->{$field} = '' if !defined $params->{$field};
        $values{$field} = trim($params->{$field});
        if ($values{$field} eq '') {
            push(@errors, "You must specify a $field.");
            $values{$field} = '';
        }
    }

    if ($values{name} =~ /^(\w*)$/) {
        $values{name} = $1;
        my $exists = $dbh->selectrow_array(
            'SELECT 1 FROM installs WHERE name = ?', undef, $values{name});

        if ($exists and $opts->{check_exists}) {
            push(@errors, "An installation with the name '$values{name}'"
                          . " has already been created using this interface.");
        }

        if (!$opts->{for_deletion} and -e "/var/www/html/$values{name}") {
            push(@errors, "An installation with the name '$values{name}'"
                          . " already exists on the disk.");
        }

        if ($values{name} =~ /_branch$/ or $values{name} =~ /^tip$/i) {
            push(@errors, "Installation names can't end in _branch or"
                          . " be called 'tip'.");
        }
    }
    else {
        push(@errors, "The installation name can only contain letters,"
                      . " numbers, and underscores.");
    }

    if ($values{user}) {
        getpwnam($values{user})
          or push(@errors, "'$values{user}' is not a valid landfill user.");
    }

     if ($values{mailto} and $values{mailto} !~ $Email::Address::mailbox) {
         push(@errors, "'$values{mailto}' is not a valid email address.");
     }

     return (\%values, \@errors);
}

1;
