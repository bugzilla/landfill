#!/usr/bin/perl -wT
#
# ------------------------------------
# create.cgi - Public Install Creation
# ------------------------------------
#

use strict;
use lib qw(.);
use Landfill;
use Captcha::reCAPTCHA;

my $cgi = Landfill->cgi;
my $action = trim($cgi->param('action') || '');


our $rc = Captcha::reCAPTCHA->new;

if ($action eq "") { page_add(); }
elsif ($action eq "new") { page_new(); }
else { die "Unknown action: $action"; }

# action=add -> Add a new install.
sub page_add {
    my ($rc_error) = @_;
    my $cgi = Landfill->cgi;
    my $template = Landfill->template;
    my $branches = bzr_branches();
    # Only let people create installations on version 3 or higher.
    @$branches = grep { $_ ne 'trunk' and $_ !~ /^2/ } @$branches;
    my $cap_html = $rc->get_html(Landfill::RC_PUBLIC, $rc_error, 1);
    my %vars = ( branches => $branches, recaptcha => $cap_html );
    print $cgi->header();
    $template->process('create/add.html.tmpl', \%vars) 
        or die $template->error;
}

# action="new" -> Actually create the install
sub page_new {
    my $cgi = Landfill->cgi;
    my $dbh = Landfill->dbh;
    my $template = Landfill->template;

    my $rc_private = Landfill::get_db_pass('recaptcha_private');
    my $result = $rc->check_answer($rc_private, $cgi->remote_addr,
        scalar $cgi->param('recaptcha_challenge_field'),
        scalar $cgi->param('recaptcha_response_field'));

    if (!$result->{is_valid}) {
        page_add($result->{error});
        exit;
    }

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
                                    user, delete_at) 
              VALUES (?,?,?,?,?,?,?, NOW() + INTERVAL 7 DAY)',
             undef,
             $values->{name}, "/$values->{name}/", $values->{contact},
             $values->{mailto}, $values->{db}, $values->{branch}, 
             $values->{user});

    $template->process('create/added.html.tmpl', 
                       { url => "/$values->{name}/" }) or die $template->error;
}
