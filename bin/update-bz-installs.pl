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
use warnings;
use File::Basename;
BEGIN {
    my $dir = dirname(dirname($0));
    $dir =~ /(.*)/; $dir = $1;
    chdir($dir);
}
use lib qw(.);
use Landfill;
use Cwd;
use Fcntl qw(LOCK_EX LOCK_UN);
use File::Temp;
use HTTP::Cookies;
use IO::File;
use XMLRPC::Lite;

# Make sure only one of us is running at a time.
my $lock = '/root/.makebzinstall_lock';
my $lock_fh = IO::File->new($lock, '>>') || die "$lock: $!";
flock($lock_fh, LOCK_EX);
END { flock($lock_fh, LOCK_UN) }

my $dbh = Landfill->dbh;

my $need_deleting = $dbh->selectall_arrayref(
    'SELECT * FROM installs 
      WHERE delete_me = 1 OR delete_at < NOW()', {Slice=>{}});
foreach my $install(@$need_deleting) {
    delete_install($install);
}

my $uncreated = $dbh->selectall_arrayref(
    'SELECT * FROM installs WHERE created = 0', {Slice=>{}});
foreach my $install (@$uncreated) {
    create_install($install);
}

sub delete_install {
    my $install = shift;

    my (undef, $errors) = validate_install($install, { for_deletion => 1 });
    die(join("\n", @$errors)) if @$errors;

    my $name = $install->{name};
    print "Deleting the '$name' installation...\n";
    system("rm", "-rf", "/var/www/html/$name");
    my $drop_cmd = lc($install->{db}) . "drop";
    system($drop_cmd, "bugs_$name");
    Landfill->dbh->do('DELETE FROM installs WHERE install_id = ?', undef,
                      $install->{install_id});
}

sub create_install {
    my $install = shift;

    my (undef, $errors) = validate_install($install);
    die(join("\n", @$errors)) if @$errors;

    my $source_db = "bugs_tip";
    my $branch = $install->{branch};
    if ($branch ne 'trunk') {
        my $db_branch = $branch;
        $db_branch =~ s/\./_/g;
        $source_db = "bugs_bugzilla${db_branch}_branch";
    }

    my $name = $install->{name};
    print "Creating $name installation using $branch...\n";
    my $clone_cmd = lc($install->{db}) . "clone";
    system($clone_cmd, $source_db, "bugs_$name");
    my $repo = Landfill::BZR_REPO;
    my $dir = "/var/www/html/$name";
    system("bzr", "co", "$repo/$branch", $dir);

    my $answers = answers($install);
    my $temp_fh = File::Temp->new();
    $temp_fh->autoflush(1);
    print $temp_fh $answers;
    my $temp_filename = $temp_fh->filename;

    my $db_pass = Landfill::get_db_pass();
    my $bz_pass = Landfill::get_db_pass('bz_pass');

    my $original_dir = cwd();
    chdir($dir) || die "$dir: $!";

    if (-e "./install-module.pl") {
        system("./install-module.pl", "CGI");
    }

    # Create localconfig
    system("./checksetup.pl $temp_filename");
    # Branches earlier than 3.6 don't understand "answers" for $db_driver.
    fix_localconfig($install);
    # And set up the database
    system("./checksetup.pl $temp_filename");

    if ($install->{delete_at}) {
        make_admin($install, $bz_pass);
        disable_all_bugmail($install, $db_pass);
    }

    trick_taint($original_dir);
    chdir($original_dir) or warn "$original_dir: $!";
    system("find $dir -exec chown $install->{user} \{\} \\;");

    $dbh->do('UPDATE installs SET created = 1 WHERE install_id = ?',
             undef, $install->{install_id});
}

sub fix_localconfig {
    my $install = shift;
    my $branch = $install->{branch};
    return if ($branch eq 'trunk' or $branch >= 3.6);
    my $lc_contents;
    open(my $fh, '<', 'localconfig') or die "localconfig: $!";
    { local $/; $lc_contents = <$fh>; }
    close($fh);
    $lc_contents =~ s/\bmysql\b/$install->{db}/gis;
    open(my $write_fh, '>', 'localconfig') or die "localconfig: $!";
    print $write_fh $lc_contents;
    close $write_fh;
}

sub answers {
    my $install = shift;
    my $name = quotemeta($install->{name});
    my $email = quotemeta($install->{mailto});
    my $driver = quotemeta($install->{db});
    my $db_pass = quotemeta(Landfill::get_db_pass());

    my $random_pass = quotemeta(random_string());

    my $answers = <<END;
\$answer{'db_name'}    = 'bugs_$name';
\$answer{'db_user'}    = 'bugs';
\$answer{'db_pass'}    = '$db_pass';
\$answers{'db_driver'} = '$driver';

\$answer{'urlbase'}      = 'http://landfill.bugzilla.org/$name/';
\$answer{'sslbase'}      = 'https://landfill.bugzilla.org/$name/';
\$answer{'cookiepath'}   = '/$name/';
\$answer{'ssl'}          = 'always';
\$answer{'ssl_redirect'} = 1;
\$answer{'maintainer'}   = '$email';
\$answer{'allow_attachment_display'} = 1;
\$answer{'attachment_base'} = 'https://bug\%bugid\%.landfill.bugzilla.org/$name/';
\$answer{'webdotbase'} = '/usr/bin/dot';
\$answer{'use_mailer_queue'} = 0;

\$answer{'ADMIN_EMAIL'}    = '$email';
\$answer{'ADMIN_REALNAME'} = '$install->{contact}';
\$answer{'ADMIN_PASSWORD'} = '$random_pass';
\$answer{'NO_PAUSE'} = 1;
END
    return $answers;
}

sub make_admin {
    my ($install, $bz_pass) = @_;

    my $name = $install->{name};
    my $url = "https://landfill.bugzilla.org/$name/";
    my $rpc = xmlrpc_client($url);

    my $as_user = Landfill::BZ_USER;
    $rpc->call('User.login', 
               { login => $as_user, password => $bz_pass });
   
    # Save the cookies in the cookie jar
    $rpc->transport->cookie_jar->extract_cookies(
        $rpc->transport->http_response);
    $rpc->transport->cookie_jar->save;

    # Create the user
    my $admin = $install->{mailto};
    $rpc->call('User.create', { email => $admin });
    $rpc->call('User.logout');

    # Make them an admin
    system("./checksetup.pl", "-t", "--make-admin=$admin", "/dev/null");

    $rpc->transport->get("https://landfill.bugzilla.org/$name/token.cgi" 
                         . "?a=reqpw&loginname=$admin");
}

sub xmlrpc_client {
    my ($url) = @_;
    # A temporary cookie jar that isn't saved after the script closes.
    my $cookie_jar = new HTTP::Cookies();
    my $rpc        = new XMLRPC::Lite(proxy => "${url}xmlrpc.cgi");
    $rpc->transport->cookie_jar($cookie_jar);
    return $rpc;
}

sub disable_all_bugmail {
    my ($install, $db_pass) = @_;
    my $name = $install->{name};
    my $db_name = "bugs_$name";
    trick_taint($db_pass);
    system("mysql", "--user=bugs", "--password=$db_pass", $db_name,
           "--execute=UPDATE profiles SET disable_mail = 1");
}
