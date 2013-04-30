#!/usr/bin/perl
use warnings;
use strict;

use Apache::Admin::Config;
use App::Info::HTTPD::Apache;
use Getopt::Long::Descriptive;
use File::Basename;
use File::Spec;
use Filesys::DiskUsage qw/du/;
use Sys::Hostname;
use LWP::Simple;
use Net::DNS;

# Run this script with root privs, but check first
exec '/usr/bin/sudo', $0, @ARGV unless exists $ENV{SUDO_USER} or $ENV{USER} eq 'root';

# Error status code
my $error = 0;

# Getopt::Long::Descriptive configuration
my ($opt, $usage) = describe_options(
    'Usage: %c %o',
    [ 'logs|l', 'Check if any log files mentioned in conf file are missing' ],
    [ 'size|s', 'Display the size of each DocumentRoot and all subdirs' ],
    [ 'drupal|d', 'Display the status of a Drupal install by running `drush status` in each DocumentRoot' ],
    [ 'dbsize|b', 'Display the size of the Drupal database, if it exists' ],
    [ 'roots|r', 'Print a list of the Document Roots at the end of the report' ],
    [ 'git|g', 'Print relevant git information, namely if the directory is in a git repository, and if available, the remote repository information' ],
    [ 'all|a', 'Perform all of the above, with verbose output. Overrides above options if specified',
        { implies => [qw/logs size drupal dbsize roots git verbose/] }
    ],
    [ 'name|n=s', 'Filter results found by vhost ServerName or Alias. Usage: -n \'filterurl\'' ],
    [],
    [ 'verbose|v', 'Prints extra information during run' ],
    [ 'help|h', 'Prints this help message and exits immediately.' ],
    [],
);


print($usage->text), exit if $opt->help;

# If the option to check drupal installs using drush is used, make sure we have drush installed first!
if ( $opt->drupal && system("which drush 2>1&>/dev/null") ) {
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
print STDERR "Finding our external IP address took $new_time_marker " .
    (($new_time_marker == 1) ? "second.\n" : "seconds.\n") if $new_time_marker and $opt->verbose;

# Check for the current httpd.conf file in use
# Note: This only finds the first httpd in the path.
# So make sure the httpd you're using is found by which!
my $apache = App::Info::HTTPD::Apache->new;
my $main_conf = new Apache::Admin::Config( $apache->conf_file );

# Determine how Apache is being called
our $APACHEBINPATH = $apache->executable;
our $APACHEBIN = basename($APACHEBINPATH);
our $APACHECTLPATH = ($APACHEBINPATH =~ 'apache2') ? "${APACHEBINPATH}ctl" : $APACHEBINPATH;
our $APACHECTL = basename($APACHECTLPATH);
print STDERR "Perl thinks the Apache executable is: $APACHEBIN\nand the control program is: $APACHECTL\n";

# Grab the global ServerRoot
my $ServerRoot = $apache->httpd_root;

# Grab the global document root/ default for the server
# and start off the DocumentRoots hash with it.
my $MainDocRoot = $apache->doc_root;

# If the DocumentRoot isn't specified in the main conf file, look in default locations
if ( ! $MainDocRoot ) {
    if ( $APACHEBIN eq "httpd" ) { $MainDocRoot = '/var/www/html'; }
    else {
        my $default_conf = new Apache::Admin::Config( '/etc/apache2/sites-available/default' );
        $MainDocRoot = $default_conf->section('VirtualHost')->directive('DocumentRoot');
    }
}

my %DocumentRoots = ($MainDocRoot => 1);

my %LogFiles = ();

# Now we will begin by parsing the output of apache's -t -D DUMP_VHOSTS
# We're going to be examining all of the included .conf files
open(DUMP_VHOSTS,"$APACHECTLPATH -t -S 2>&1 |") or die $!;
my @all_conf;
while (<DUMP_VHOSTS>) {
        m@.*port\s+([0-9]+)\s+\w+\s+(\S+)\s+\((.+):([0-9])\).*@ && do {
        my ($PORT, $URL, $CONF) = ($1, $2, $3);
        #print "PORT = $PORT, URL = $URL, CONF = $CONF\n";
        push @all_conf, $CONF;
    };
}
close(DUMP_VHOSTS);

# This hash will contain all the data for each virtualhost, as a hash of hashes in the form:
#   %thehash = (
#       ConfFile => {
#           ServerName => {
#               'URL' => value,
#               'IP' => value,
#               'Alias' => {
#                           'alias' => 'IPaddress',
#                           'alias' => 'IPaddress' },
#               'Logs' => {
#                           '<Type>' => {
#                                       'Path' => value,
#                                       'Exists' => value },
#                         },
#               'DocumentRoot' => {
#                                   'Location' => value,
#                                   'Exists' => value },
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
#                           },
#               'Git' => {
#                       'is_repository' => value,
#                       'remote_repo' => value }
#               }
#           }
#       }
#   );
#
my %conf_info = ();

$time_marker = time;

# Print some summary information.
printf "%15s %s\n%15s %s\n%15s %s\n%15s %s (%s)\n%15s %s\n\n",
    "Generated by:", getlogin(),
    "Using script:", File::Spec->rel2abs($0),
    "on date:", scalar localtime,
    "for server:", hostname, $myip,
    "main conf:", $apache->conf_file;

print STDERR "Working... Please be patient.\n" if $opt->verbose;

my $opt_name = $opt->name;

for (@all_conf) {

    my $conf = new Apache::Admin::Config($_);
    my $conf_file = $_;
    my $opt_name_vhost_match = 0;
    my $opt_name_file_match = 0;

    foreach($conf->section('VirtualHost')) {
        my $VhostConf = $_;
        my $ServerName;

        if ( defined $VhostConf->directive('ServerName') ) {
            $ServerName = $VhostConf->directive('ServerName')->value;
            (my $name = $ServerName) =~ s/:.*//;
            $conf_info{$conf_file}{$name}{'URL'} = $name;
            $conf_info{$conf_file}{$name}{'IP'} = &ip_lookup($name);
            $ServerName = $name;
            ($opt_name_vhost_match = 1 && $opt_name_file_match = 1) if (defined $opt_name && $name =~ m/$opt_name/);
        } else {
            next; #All VirtualHosts must have a ServerName.
        }

        foreach($VhostConf->directive('ServerAlias')) {
            (my $name = $_->value) =~ s/:.*//;
            $conf_info{$conf_file}{$ServerName}{'Aliases'}{$name} = &ip_lookup($name);
            ($opt_name_vhost_match = 1 && $opt_name_file_match = 1) if (defined $opt_name && $name =~ /$opt_name/);
        }

        # Check for match in ServerName or ServerAlias, if -n defined.
        # If no match, delete entry from hash and skip to next vhost.
        # If there is a match, just reset the 'matched' value.
        if (defined $opt_name) {
            (delete $conf_info{$conf_file}{$ServerName} && next) if $opt_name_vhost_match == 0;
            $opt_name_vhost_match = 0;
        }

        # Check to see if there is a DocumentRoot defined in the VirtualHost
        my $DR = $VhostConf->directive('DocumentRoot') ? File::Spec->canonpath($_->directive('DocumentRoot')) : 'None';
        # Check if the site url (ServerName) we are looking at is actually a multi-site Drupal install
        if (defined $VhostConf->directive('ServerName')) {
            my @SitesDirPossibilities = ();

            my $VhostName = $VhostConf->directive('ServerName')->value;
            push (@SitesDirPossibilities, $VhostName);

            (my $NameSansWWW = $VhostName) =~ s/www\.//;
            push (@SitesDirPossibilities, $NameSansWWW);

            if (-f "$DR/sites/sites.php") { # Check if there is a Drupal 7 sites.php file
                my $SitesDir = parse_sites_php_file("$DR/sites/sites.php", "$VhostName");
                push (@SitesDirPossibilities, $SitesDir);

                my $SitesDirSansWWW = parse_sites_php_file("$DR/sites/sites.php", "$NameSansWWW");
                push (@SitesDirPossibilities, $SitesDirSansWWW);
            }

            foreach my $dir (@SitesDirPossibilities) {
                next if ($dir eq '');
                if (-d "$DR/sites/$dir") {
                    $DR = File::Spec->canonpath("$DR/sites/$dir");
                    last;
                }
            }
        }

        $conf_info{$conf_file}{$ServerName}{'DocumentRoot'}{'Location'} = $DR;
        $conf_info{$conf_file}{$ServerName}{'DocumentRoot'}{'Exists'} = (-d $DR) ? 'Yes' : 'No';

        $DocumentRoots{$DR}++;

        if ($DR eq 'None') {
            foreach my $direc ($VhostConf->directive()){
                $conf_info{$conf_file}{$ServerName}{'Directives'}{$direc->name} = $direc->value
                    unless ($direc->name eq 'ServerName' || $direc->name eq 'ServerAlias');
            }
        } elsif ( -d $DR ) {
                $conf_info{$conf_file}{$ServerName}{'DocumentRoot'}{'Size'} = du( {'Human-readable' => 1}, $DR ) if $opt->size;
                if ($opt->drupal) {
                    my %drush = &drush_status($DR);
                    if (exists $drush{'drupal_version'}) { # If Drupal is installed, tell me about it
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'Version'} = $drush{'drupal_version'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Name'} = $drush{'database_name'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Host'} = $drush{'database_hostname'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'User'} = $drush{'database_username'};
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Status'} =
                                    exists $drush{'database'} ? $drush{'database'} : "Error!";
                        $conf_info{$conf_file}{$ServerName}{'Drupal'}{'DB'}{'Size'} =
                                    drupal_db_size($DR) if ( $opt->dbsize && exists $drush{'database'} );
                    } else { # Otherwise, just say so.
                        $conf_info{$conf_file}{$ServerName}{'Drupal'} = 'No';
                    }
                } elsif ($opt->dbsize) {
                    my %drush = &drush_status($DR);
                    $conf_info{$conf_file}->{$ServerName}{'Drupal'}{'DB'}{'Size'} =
                                drupal_db_size($DR) if ( $opt->dbsize && exists $drush{'database'} );
                }
                if ($opt->git) {
                    my $is_repo = `cd $DR && git rev-parse --is-inside-work-tree 2>&1 | head -1`;
                    chomp $is_repo;
                    if ($is_repo eq 'true') {
                        $conf_info{$conf_file}{$ServerName}{'Git'}{'is_repository'} = $is_repo;
                        $conf_info{$conf_file}{$ServerName}{'Git'}{'remote_repo'} = `cd $DR && git remote -v`;
                        chomp $conf_info{$conf_file}{$ServerName}{'Git'}{'remote_repo'};
                    } else {
                        $conf_info{$conf_file}{$ServerName}{'Git'}{'is_repository'} = 'false';
                    }
                }
        } else {
            $DocumentRoots{$DR}--;  # Decrement to put the entry at the bottom of the list when printing.
                                    #   Comment out if you want to know how many sites depend on this folder
        }

        # Check for log files that do not exist
        if ($opt->logs) {
            my @log_types = qw(Error Custom Forensic Rewrite Script Transfer);
            foreach my $type (@log_types) {
                $type .= 'Log';
                if (defined $VhostConf->directive($type)) {
                    # For CustomLog and other logs needing formats, strip the format
                    my ($logfile) = split(' ',$VhostConf->directive($type));
                    # For log paths in quotes, remove quotes.
                    $logfile =~ s/"//g;
                    # For relative log paths, add the ServerRoot first
                    $logfile = "$ServerRoot/$logfile" if $logfile !~ /^\//;
                    $conf_info{$conf_file}{$ServerName}{'Logs'}{$type}{'Path'} = $logfile;
                    $conf_info{$conf_file}{$ServerName}{'Logs'}{$type}{'Exists'} = (-f $logfile) ? 'Yes' : 'No';
                    $LogFiles{$logfile}++;
                    $error = 1 if $conf_info{$conf_file}{$ServerName}{'Logs'}{$type}{'Exists'} eq 'No';
                }
            }
        }
    }
    # If there are no matching virtualhosts in the file, we can delete its reference
    delete $conf_info{$conf_file} if (defined $opt_name && $opt_name_file_match == 0);
}

$new_time_marker = (time - $time_marker);
print STDERR "Gathering information took $new_time_marker " .
    (($new_time_marker == 1) ? "second.\n" : "seconds.\n") if $new_time_marker and $opt->verbose;

# Make sure there is stuff to print before trying
if (! scalar keys %conf_info) {
   if ($opt_name) {
       print "Nothing found matching '$opt_name'!\n\n";
   } else {
       print "Nothing found!\nThis could be serious.\nAre you sure things are working properly?\n\n";
   }
} else {
    # The Big Print function
    &printInfoHash(%conf_info);

    # Summary of document roots at the end
    if ($opt->roots) {
        print '-' x 80, "\n\nDocument Roots to be aware of:\n\n";
        foreach (sort {$DocumentRoots{$b} <=> $DocumentRoots{$a} or $a cmp $b} keys %DocumentRoots)
        {
            printf "$_ %s\n", (!-d $_) ? "(Does not exist)" : "" unless $_ eq "None";
        }
    }

    # Summary of log files at the end
    if ($opt->logs) {
        print '-' x 80, "\n\nLog files to be aware of:\n\n";
        foreach (sort keys %LogFiles)
        {
            print "$_\n" if (-f $_);
            print STDERR "$_ (Does not exist)\n" if (!-f $_);
        }
    }
}

exit $error;

### END MAIN PROGRAM ###


### BEGIN SUBROUTINES ###

sub printInfoHash {
    my (%InfoHash) = @_;
    my $spaces = 15;
    my $fstr = "%${spaces}s: %s\n";
    my $ipfstr = "%${spaces}s: %s (%s)\n";
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
            if (defined $InfoHash{$file}{$vhost}{'Logs'}) {
                for my $log (keys %{$InfoHash{$file}{$vhost}{'Logs'}}) {
                    if ( $InfoHash{$file}{$vhost}{'Logs'}{$log}{'Exists'} eq 'No') {
                        printf $ipfstr, $log, $InfoHash{$file}{$vhost}{'Logs'}{$log}{'Path'}, "Does not exist!";
                        printf $fstr, "WARNING", "This will prevent Apache from restarting.";
                    } else {
                    printf $fstr, $log, $InfoHash{$file}{$vhost}{'Logs'}{$log}{'Path'};
                    }
                }
            }
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
                if ( defined $InfoHash{$file}{$vhost}{'Drupal'} && $InfoHash{$file}{$vhost}{'Drupal'} ne 'No' ) {
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
                    printf $fstr, "Drupal", "No" if $opt->drupal;
                } #END DRUPAL CHECK
                if ( defined $InfoHash{$file}{$vhost}{'Git'}{'is_repository'} ) {
                    printf $fstr, "Git", $InfoHash{$file}{$vhost}{'Git'}{'is_repository'};
                    if ( defined $InfoHash{$file}{$vhost}{'Git'}{'remote_repo'} ) {
                        my $trans = '  '.' ' x $spaces;
                        $InfoHash{$file}{$vhost}{'Git'}{'remote_repo'} =~ s{\n}{\n$trans}g;
                        printf $fstr, "Git Remote", $InfoHash{$file}{$vhost}{'Git'}{'remote_repo'};
                    }
                }
            }
            print "\n";
        } #END VHOST LOOP
    } #END FILE LOOP
    print "\n";
} #END SUB printInfoHash

sub drush_status
{
    chdir(shift);

    my $show_pass = shift || '';
    $show_pass = ($show_pass =~ /p/) ? '--show-passwords' : ''; # If specified, show the DB password(s)

    my @oa = split /\s+:|\n/, `drush status $show_pass`; # Split on colons (except in urls) and newlines

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
#  database_password    (String)
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
    my $site_path = shift;
    my %drush_info = drush_status($site_path,'p');
    return undef unless exists $drush_info{'database'};

    my $user = $drush_info{'database_username'};
    my $pass = $drush_info{'database_password'};
    my $host = $drush_info{'database_hostname'};
    my $db   = $drush_info{'database_name'};
#    $pass = URI::Escape::uri_unescape($pass); # Need to be able to read the password

    chdir($site_path);
    my $query = "SELECT (SUM(t.data_length)+SUM(t.index_length)) total_size ".
                "FROM INFORMATION_SCHEMA.SCHEMATA s ".
                "LEFT JOIN INFORMATION_SCHEMA.TABLES t ".
                "ON s.schema_name = t.table_schema WHERE s.schema_name = '$db'";
    my $drush_db_size = `drush sql-query "$query"`;
    $drush_db_size =~ s/[^0-9]+//;
    chomp($drush_db_size);
    my $db_size_h = &human_size($drush_db_size);

    return $db_size_h;
} # END SUB drupal_db_size

# Parses a sites.php file for a particular URL
# and returns the corresponding directory name
# or an empty string if no matches are found.
#
sub parse_sites_php_file {
    my $file = shift or die "Must have filename";
    my $site = shift or die "Must have string to parse";

    open SITESPHP, "<", "$file" or die "Cannot open file $file: $!";

    my $regex = qr/^\s*\$sites\[\s*['"]$site['"]\s*\]\s*=\s*['"]([^']+)['"]\s*;/;

    while (<SITESPHP>) {
        if (/$regex/) {
            chomp;
            close SITESPHP;
            return $1;
        }
    }
    close SITESPHP;
    return '';
}

sub ip_lookup_self {
    use Switch qw(Perl5 Perl6); #Use native GIVEN/WHEN once upgraded to Perl 5.10+
    my $ip;
    my $ip_service;
    print STDERR "Looking up IP\n";
    until ( defined $ip && $ip =~ /(\d{1,3}\.){3}\d{1,3}/ ) {
        given (int(rand(6))) {
            when 0 { $ip_service = "http://tnx.nl/ip"; }
            when 1 { $ip_service = "http://icanhazip.com"; }
            when 2 { $ip_service = "http://ifconfig.me/ip"; }
            when 3 { $ip_service = "http://ip.appspot.com"; }
            when 4 { $ip_service = "http://myip.dnsomatic.com"; }
            when 5 { $ip_service = "http://www.showmyip.com/simple/"; }
            when 6 { $ip_service = "https://secure.informaction.com/ipecho/"; }
            when 7 { $ip_service = "http://automation.whatismyip.com/n09230945.asp"; }
            else {}
        }
        print STDERR "Trying: $ip_service\n";
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm 2;
            $ip = get($ip_service);
            alarm 0;
        };
    }
    chomp($ip);
    print STDERR "IP ($ip) found from: $ip_service\n";
    return $ip;
} # END SUB ip_lookup_self

sub ip_lookup {
    my $dns= new Net::DNS::Resolver;
    my $search = $dns->search(shift);
    my @answer = $search ? $search->answer : undef;

    return defined $_ ? $_->type eq "A" ? $_->address : next : "Unresolvable!" for @answer;
} # END SUB ip_lookup

sub ip_lookup_array {
    my $dns= new Net::DNS::Resolver;
    my @ipaddrs;
    my $search = $dns->search(shift);
    my @answer = $search ? $search->answer : undef;

    push @ipaddrs, defined $_ ? $_->type eq "A" ? $_->address : next : "Unresolvable!" for @answer;

    return @ipaddrs;
} # END SUB ip_lookup_array

sub ip_lookup_hash {
    my $dns= new Net::DNS::Resolver;
    my %ipaddrs;
    my $search = $dns->search(shift);
    my @answer = $search ? $search->answer : undef;

    $ipaddrs{defined $_ ? $_->type eq "A" ? $_->address : next : "Unresolvable!"}++ for @answer;

    return %ipaddrs;
} # END SUB ip_lookup_hash
