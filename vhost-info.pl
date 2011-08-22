#!/usr/bin/perl
use warnings;
use strict;

use Apache::Admin::Config;
use App::Info::HTTPD::Apache;
use Getopt::Std;
use File::Basename;
use File::Spec;
use Filesys::DiskUsage qw/du/;
use Sys::Hostname;
use LWP::Simple;
use Net::DNS;

# getopt parameters and settings
$main::VERSION = "0.2";
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our($opt_b, $opt_d, $opt_s, $opt_a, $opt_n);
getopts('bdsan:');

($opt_b, $opt_d, $opt_s) = (1) x 3 if $opt_a; # Set all variables, if the -a option is set

# If the option to check drupal installs using drush is used, make sure we have drush installed first!
if ( $opt_d && system("which drush 2>1&>/dev/null") ) {
    print "Sorry, it doesn't appear that you have drush installed in a place I can access it.\n";
    print "Maybe you do, but it isn't aliased or included in your PATH?\n";
    print "At any rate, you'll need to fix that before you can use the -d option.\n";
    print "Bye!\n";
    exit;
}

# Find out our global IP address
my $time_marker = time;
my $myip = &ip_lookup_self;
my $new_time_marker = (time - $time_marker);
print STDERR "Finding our external IP address took $new_time_marker seconds.\n" if $new_time_marker;

# Check for the current httpd.conf file in use
# Note: This only finds the first httpd in the path.
# So make sure the httpd you're using is found by which!
my $apache = App::Info::HTTPD::Apache->new;
my $main_conf = new Apache::Admin::Config( $apache->conf_file );

# Grab the global document root/ default for the server
# and start off the DocumentRoots hash with it.
(my $ServerRoot = $main_conf->directive('DocumentRoot')) =~ s/\"//g;

my %DocumentRoots = ($ServerRoot => 1);

# We're going to be examining all of the included .conf files
my @all_conf = ($apache->conf_file, map {glob($_)} $main_conf->directive('Include'));
map { $_ = File::Spec->rel2abs($_, $apache->httpd_root) } grep { m/\.conf/ } @all_conf;

# This hash will contain all the data for each virtualhost, as a hash of hashes in the form:
#   %thehash = (
#       'ConfFile' => {
#           'ServerName' => {
#               'URL' => value,
#               'IP' => value,
#               'Alias' => {
#                           'alias' => 'IPaddress',
#                           'alias' => 'IPaddress' },
#               'DocumentRoot' => value,
#               'Directives' => {
#                           'directive' => value,
#                           'directive' => value},
#               'DocRootSize' => value,
#               'Drupal' => {
#                           'Version' => value,
#                           'DB' => {
#                                   'Name' => value,
#                                   'Host' => value,
#                                   'User' => value,
#                                   'Status' => value,
#                                   'Size' => value }
#                           }
#           }
#       }
#   );
#
my %conf_info = ();

$time_marker = time;

# Print some summary information.
printf "%15s %s\n%15s %s\n%15s %s\n%15s %s (%s)\n\n",
    "Generated by:", getlogin(),
    "Using script:", File::Spec->rel2abs($0),
    "on date:", scalar localtime,
    "for server:", hostname, $myip;

print STDERR "Working... Please be patient.\n";

for (@all_conf) {

    my $conf = new Apache::Admin::Config($_);
    my $conf_file = $_;
    my $opt_n_vhost_match = 0;
    my $opt_n_file_match = 0;

    foreach($conf->section('VirtualHost')) {
        my $ServerName;
        if ( defined $_->directive('ServerName') ) {
            $ServerName = $_->directive('ServerName')->value;
            (my $name = $ServerName) =~ s/:.*//;
            $conf_info{$conf_file}{$name}{'URL'} = $name;
            $conf_info{$conf_file}{$name}{'IP'} = &ip_lookup($name);
            $ServerName = $name;
            ($opt_n_vhost_match = 1 && $opt_n_file_match = 1) if (defined $opt_n && $name =~ /$opt_n/);
        }

        foreach($_->directive('ServerAlias')) {
            (my $name = $_->value) =~ s/:.*//;
            $conf_info{$conf_file}{$ServerName}{'Aliases'}{$name} = &ip_lookup($name);
            ($opt_n_vhost_match = 1 && $opt_n_file_match = 1) if (defined $opt_n && $name =~ /$opt_n/);
        }

        # Check for match in ServerName or ServerAlias, if -n defined.
        # If no match, delete entry from hash and skip to next vhost.
        # If there is a match, just reset the 'matched' value.
        if (defined $opt_n) {
            (delete $conf_info{$conf_file}{$ServerName} && next) if $opt_n_vhost_match == 0;
            $opt_n_vhost_match = 0;
        }

        # Check to see if there is a DocumentRoot defined in the VirtualHost
        my $DR = $_->directive('DocumentRoot') ? File::Spec->canonpath($_->directive('DocumentRoot')) : 'None';
        # Check if the site url (ServerName) we are looking at is actually a multi-site Drupal install
        if (defined $_->directive('ServerName')) {
            (my $NameSansWWW = $_->directive('ServerName')) =~ s/www\.//;
            if (-d $DR."/sites/".$_->directive('ServerName')) {
                $DR = File::Spec->canonpath($DR."/sites/".$_->directive('ServerName'));
            } elsif (-d $DR."/sites/".$NameSansWWW) {
                $DR = File::Spec->canonpath($DR."/sites/".$NameSansWWW);
            } else {
                $DR = File::Spec->canonpath($DR);
            }
        }

        $conf_info{$conf_file}{$ServerName}{'DocumentRoot'}{'Location'} = $DR;
        $conf_info{$conf_file}{$ServerName}{'DocumentRoot'}{'Exists'} = (-d $DR) ? 'Yes' : 'No';

        $DocumentRoots{$DR}++;

        if ($DR eq 'None') {
            foreach my $direc ($_->directive()){
                $conf_info{$conf_file}{$ServerName}{'Directives'}{$direc->name} = $direc->value
                    unless ($direc->name eq 'ServerName' || $direc->name eq 'ServerAlias');
            }
        } elsif ( -d $DR ) {
                $conf_info{$conf_file}{$ServerName}{'DocumentRoot'}{'Size'} = du( {'Human-readable' => 1}, $DR ) if $opt_s;
                if ($opt_d) {
                    my %drush = &drush_status($DR);
                    if (exists $drush{'drupal_version'}) { # If Drupal is installed, tell me about it
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'Version'} = $drush{'drupal_version'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Name'} = $drush{'database_name'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Host'} = $drush{'database_hostname'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'User'} = $drush{'database_username'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Status'} =
                                    exists $drush{'database'} ? $drush{'database'} : "Error!";
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Size'} =
                                    drupal_db_size($DR) if ( $opt_b && exists $drush{'database'} );
                    } else { # Otherwise, just say so.
                        $conf_info{$conf_file}{$ServerName}{'Drupal'} = 'No';
                    }
                } elsif ($opt_b) {
                    my %drush = &drush_status($DR);
                    $conf_info{$conf_file}->{$ServerName}{'Drupal'}{'DB'}{'Size'} =
                                drupal_db_size($DR) if ( $opt_b && exists $drush{'database'} );
                }
        } else {
            $DocumentRoots{$DR}--;  # Decrement to put the entry at the bottom of the list when printing.
                                    #   Comment out if you want to know how many sites depend on this folder
        }
    }
    # If there are no matching virtualhosts in the file, we can delete its reference
    delete $conf_info{$conf_file} if (defined $opt_n && $opt_n_file_match == 0);
}

$new_time_marker = (time - $time_marker);
print STDERR "Gathering information took $new_time_marker seconds.\n" if $new_time_marker;

&printInfoHash(%conf_info);

print '-' x 80, "\n\nDocument Roots to be aware of:\n\n";
foreach (sort {$DocumentRoots{$b} <=> $DocumentRoots{$a} or $a cmp $b} keys %DocumentRoots)
{
    #printf "%2d site%s using %s\n", $DocumentRoots{$_}, ($DocumentRoots{$_} == 1) ? ' ' : 's', $_;
    printf "$_ %s\n", (!-d $_) ? "(Does not exist)" : "" unless $_ eq "None";
}

sub HELP_MESSAGE() {
    print "Usage: ".basename($0)." [OPTIONS]\n";
    print "  The following options are accepted:\n\n";
    print "\t-s\tDisplay the size of each DocumentRoot and all subdirs\n\n";
    print "\t-d\tDisplay the status of a Drupal install by running \"drush status\" in each DocumentRoot\n\n";
    print "\t-b\tDisplay the size of the Drupal database, if it exists\n\n";
    print "\t-a\tPerform all of the above. Overrides above options if specified\n\n";
    print "\t-n\tFilter results found by vhost ServerName or Alias. Usage: -n 'filterurl'\n\n";
    print "Note: Options may be merged together, and option '-n' may be used with any other option.\n\n";
}
sub VERSION_MESSAGE() {
    print basename($0)." - version $main::VERSION\n";
}


sub printInfoHash {
    my (%InfoHash) = @_;
    my $fstr = "%15s: %s\n";
    my $ipfstr = "%15s: %s (%s)\n";
    for my $file ( keys %InfoHash ) {
        print '-' x 80;
        print "\nConf file: $file\n\n";
        for my $vhost ( sort keys %{$InfoHash{$file}}) {
            printf $ipfstr, "VirtualHost", $vhost, $InfoHash{$file}{$vhost}{'IP'};
            if (defined $InfoHash{$file}{$vhost}{'Aliases'}) {
                for my $alias (sort keys %{$InfoHash{$file}{$vhost}{'Aliases'}}) {
                    printf $ipfstr, "Alias", $alias, $InfoHash{$file}{$vhost}{'Aliases'}{$alias};
                } #END ALIASES LOOP
            } #END CHECK FOR ALIASES
            if ($InfoHash{$file}{$vhost}{'DocumentRoot'}{'Location'} eq 'None') {
                printf $fstr, "DocumentRoot", $InfoHash{$file}{$vhost}{'DocumentRoot'}{'Location'};
                for my $directive ( keys %{$InfoHash{$file}{$vhost}{'Directives'}}) {
                    printf $fstr, $directive, $InfoHash{$file}{$vhost}{'Directives'}{$directive};
                } #END DIRECTIVES LOOP
            } elsif ( $InfoHash{$file}{$vhost}{'DocumentRoot'}{'Exists'} eq 'No') {
                printf $ipfstr, "DocumentRoot", $InfoHash{$file}{$vhost}{'DocumentRoot'}{'Location'}, "Does not exist!";
            } else {
                printf $fstr, "DocumentRoot", $InfoHash{$file}{$vhost}{'DocumentRoot'}{'Location'};

                if ( defined $InfoHash{$file}{$vhost}{'DocumentRoot'}{'Size'} ) {
                    printf $fstr, "Dir Size", $InfoHash{$file}{$vhost}{'DocumentRoot'}{'Size'};
                } #END DOCUMENT ROOT INFO
                if ( defined $InfoHash{$file}{$vhost}{'Drupal'} ) {
                    if ( defined $InfoHash{$file}{$vhost}{'Drupal'}{'Version'}) {
                        printf $fstr, "Drupal Version", $InfoHash{$file}{$vhost}{'Drupal'}{'Version'};
                    }
                    if ( defined $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'Name'} ) {
                        printf $fstr, "Database Name", $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'Name'};
                        printf $fstr, "Database Host", $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'Host'};
                        printf $fstr, "Database User", $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'User'};
                        printf $fstr, "Database Status", $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'Status'};
                    }
                    if ( defined $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'Size'} ) {
                        printf $fstr, "Database Size", $InfoHash{$file}{$vhost}{'Drupal'}{'DB'}{'Size'};
                    } #END DATABASE INFO
                } else {
                    printf $fstr, "Drupal", "No" if $opt_d;
                } #END DRUPAL CHECK
            }
            print "\n";
        } #END VHOST LOOP
    } #END FILE LOOP
    print "\n";
} #END HASH LOOP


sub drush_status
{
    chdir(shift);

    my @oa = split /\s+:|\n/, `drush status`; # Split on colons (except in urls) and newlines

    for (@oa) {
        chomp;
        s/^\s*|\s*$|\s{2,}//g;   # Trim extra spaces
        $_ = 'none' if $_ eq ''; # If there isn't a value, put one there so the hash will work
    }

    my %oh = @oa;

    for my $k ( keys %oh ) { # Normalize the key values
        (my $nk = lc $k) =~ s/ /_/g;
        $oh{$nk} = delete $oh{$k};
    }

############################################################
# Available Keys for a full, proper Drupal install
#  administration_theme (String)
#  database             (String)
#  database_driver      (String)
#  database_hostname    (String)
#  database_name        (String)
#  database_username    (String)
#  default_theme        (String)
#  drupal_bootstrap     (String)
#  drupal_root          (Absolute file path)
#  drupal_user          (String)
#  drupal_version       (Float)
#  drush_alias_files    (Absolute file path)
#  drush_configuration  (Absolute file path)
#  drush_version        (Float)
#  file_directory_path  (Relative file path [to drupal_root])
#  php_configuration    (Absolute file path)
#  site_path            (Relative file path [to drupal_root])
#  site_uri             (URI [http://...])
############################################################

    return %oh;
} # END SUB drush_status

sub human_size
{ # Takes a number in bytes and converts it to Kilo, Mega, or Gigabytes.
    my $num = shift;
    my $i = 0;
    
    while ($num >= 1024){
        $num = $num/1024; $i++;
    }

    my $unit = $i==0 ? "B" : $i==1 ? "K" : $i==2 ? "M" : $i==3 ? "G" : " (TooBig)";
    my $returnstring = sprintf "%.2f%s", $num, $unit;
} # END SUB human_size

sub drupal_db_size {
    require DBI;
    require DBD::mysql;
    require File::Spec;
    require URI::Escape;

    my $site_path = shift;
    my %drush_info = drush_status($site_path);
    return undef unless exists $drush_info{'database'};

    $site_path .= "/$drush_info{'site_path'}" if ($site_path !~ m#/sites/#);

    my $settings_file = File::Spec->canonpath("$site_path/settings.php");
    my $dbString = '';

    if (-r $settings_file) {
        open SETTINGS, '<', $settings_file;
        while (<SETTINGS>){
            $dbString = $_ and last if m/^\$db_url.*/;
        }
        close SETTINGS;
    } else {
        return "Error reading $settings_file";
    }

    chomp $dbString; # No need for spurious newlines gumming up the works.
    $dbString =~ s/^\$db_url.*\'(.*)\'.*/$1/; # Just take the quoted part
    $dbString =~ tr#[:/@]#,#; # Substitute commas for other punctuation
    $dbString =~ s/,,+/,/; # Whoops, too many commas! Now we can split it.

    my ($protocol,$user,$pass,$host,$db) = split /,/, $dbString;
    $pass = URI::Escape::uri_unescape($pass); # Need to be able to read the password

    my $dbh = DBI->connect("dbi:mysql:database=$db;host=$host", $user, $pass);
    my $sth = $dbh->prepare("SELECT (SUM(t.data_length)+SUM(t.index_length)) total_size
                            FROM INFORMATION_SCHEMA.SCHEMATA s
                            LEFT JOIN INFORMATION_SCHEMA.TABLES t
                            ON s.schema_name = t.table_schema
                            WHERE s.schema_name = '$db'") if defined $dbh;
    $sth->execute() if defined $dbh;
    
    my $db_size = defined $dbh ? $sth->fetchrow_hashref->{total_size} : "-1";
    my $db_size_h = &human_size($db_size);

    return $db_size_h;
} # END SUB drupal_db_size

sub ip_lookup_self {
    use Switch qw(Perl5 Perl6); #Use native GIVEN/WHEN once upgraded to Perl 5.10+
    my $ip;
    until ( defined $ip) {
        given (int(rand(6))) {
            when 0 { $ip = get("http://icanhazip.com"); }
            when 1 { $ip = get("http://showip.codebrainz.ca"); }
            when 2 { $ip = get("http://www.showmyip.com/simple"); }
            when 3 { $ip = get("http://cfaj.freeshell.org/ipaddr.cgi"); }
            when 4 { $ip = get("https://secure.informaction.com/ipecho"); }
            when 5 { $ip = get("http://automation.whatismyip.com/n09230945.asp"); }
        }
    }
    chomp($ip);
    return $ip;
}

sub ip_lookup {
    my $dns= new Net::DNS::Resolver;
    my $search = $dns->search(shift);
    my @answer = $search ? $search->answer : undef;

    return defined $_ ? $_->type eq "A" ? $_->address : next : "Unresolvable!" for @answer;
}

sub ip_lookup_array {
    my $dns= new Net::DNS::Resolver;
    my @ipaddrs;
    my $search = $dns->search(shift);
    my @answer = $search ? $search->answer : undef;
    
    push @ipaddrs, defined $_ ? $_->type eq "A" ? $_->address : next : "Unresolvable!" for @answer;
    
    return @ipaddrs;
}

sub ip_lookup_hash {
    my $dns= new Net::DNS::Resolver;
    my %ipaddrs;
    my $search = $dns->search(shift);
    my @answer = $search ? $search->answer : undef;
    
    $ipaddrs{defined $_ ? $_->type eq "A" ? $_->address : next : "Unresolvable!"}++ for @answer;
  
    return %ipaddrs;
}
