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

# getopt parameters and settings
$main::VERSION = "0.2";
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our($opt_b, $opt_d, $opt_s, $opt_a);
getopts('bdsa');

($opt_b, $opt_d, $opt_s) = (1) x 3 if $opt_a; # Set all variables, if the -a option is set

# If the option to check drupal installs using drush is used, make sure we have drush installed first!
if ( $opt_d && system("which drush 2>1&>/dev/null") ) {
    print "Sorry, it doesn't appear that you have drush installed in a place I can access it.\n";
    print "Maybe you do, but it isn't aliased or included in your PATH?\n";
    print "At any rate, you'll need to fix that before you can use the -d option.\n";
    print "Bye!\n";
    exit;
}

# Check for the current httpd.conf file in use
my $apache = App::Info::HTTPD::Apache->new;
my $main_conf = new Apache::Admin::Config( $apache->conf_file );

# Grab the global document root/ default for the server
# and start off the DocumentRoots hash with it.
(my $ServerRoot = $main_conf->directive('DocumentRoot')) =~ s/\"//g;

my %DocumentRoots = ($ServerRoot => 1);

# We're going to be examining all of the included .conf files
my @all_conf = ($apache->conf_file, map {glob($_)} $main_conf->directive('Include'));
map { $_ = File::Spec->rel2abs($_, $apache->httpd_root) } grep { m/\.conf/ } @all_conf;

# Print some summary information.
printf "%15s %s\n%15s %s\n%15s %s\n%15s %s\n\n",
 "Generated by:", getlogin(),
 "Using script:", File::Spec->rel2abs($0),
 "on date:", scalar localtime,
 "for server:", hostname;

for (@all_conf) {

    my $conf = new Apache::Admin::Config($_);
    print '-' x 80, "\n\nConf file: $_\n";

    print "*No VirtualHost entries in this file*\n\n" unless $conf->section('VirtualHost');

    foreach($conf->section('VirtualHost')) {
        printf "%15s: %s\n",$_->name,$_->directive('ServerName')->value if defined $_->directive('ServerName');

        foreach($_->directive('ServerAlias')) {
            printf "%15s: %s\n","Alias",$_->value;
        }

        # Check to see if there is a DocumentRoot defined in the VirtualHost
        my $DR = $_->directive('DocumentRoot') ? File::Spec->canonpath($_->directive('DocumentRoot')) : 'None';
        # Check if the site url (ServerName) we are looking at is actually a multi-site Drupal install
            $DR = (defined $_->directive('ServerName') && -d $DR."/sites/".$_->directive('ServerName'))
                ? File::Spec->canonpath($DR."/sites/".$_->directive('ServerName'))
                : File::Spec->canonpath($DR);

        printf "%15s: %s\n", "DocumentRoot", $DR;

        $DocumentRoots{$DR}++;

        if ($DR eq 'None') {
            foreach my $direc ($_->directive()){
                printf "%15s: %s\n",$direc->name,$direc->value
                  unless ($direc->name eq 'ServerName' || $direc->name eq 'ServerAlias');
            }
        } elsif ( -d $DR ) {
            if ($DocumentRoots{$DR} == 1) {
                printf("%15s: %s\n", "Dir Size", du {'Human-readable' => 1}, $DR ) if $opt_s;
                if ($opt_d) {
                    my %drush = &drush_status($DR);
                    if (exists $drush{'drupal_version'}) { # If Drupal is installed, tell me about it
                        printf "%15s: %s\n", "Drupal Version", $drush{'drupal_version'};
                        printf "%15s: %s\n", "Database Name", $drush{'database_name'};
                        if ($drush{'database_hostname'} ne 'localhost') {
                            printf "%15s: %s\n", "Database Host", $drush{'database_hostname'};
                            printf "%15s: %s\n", "Database User", $drush{'database_username'}
                                if $drush{'database_username'} ne 'root';
                        }
                        printf "%15s: %s\n", "Database Status", exists $drush{'database'} ? $drush{'database'} : "Error!";
                        printf "%15s: %s\n", "Database Size", drupal_db_size($DR) if ( $opt_b && exists $drush{'database'} );
                    } else { # Otherwise, just say so.
                        printf "%15s: %s\n", "Drupal", "No";
                    }
                } elsif ($opt_b) {
                    my %drush = &drush_status($DR);
                    printf "%15s: %s\n", "Drupal DB Size", drupal_db_size($DR) if exists $drush{'database'};
                }
            } else {
                printf "%15s: %s", "Note", "DocumentRoot already seen. Check above for more information.\n"
                    if ($opt_s || $opt_d); # Only note this if you asked for more information
            }
        } else {
            printf "%15s: %s\n", "***Warning***", "DocumentRoot does not exist!";
            $DocumentRoots{$DR}--;  # Decrement to put the entry at the bottom of the list when printing.
                                    #   Comment out if you want to know how many sites depend on this folder
        }
        print "\n";
    }
}

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
  print "\t-a\tPerform all of the above. Overrides any other option specified\n\n";
  print "Note: Options may be merged together.\n\n";
}
sub VERSION_MESSAGE() {
  print basename($0)." - version $main::VERSION\n";
}

sub drush_status {

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

sub human_size {
# Takes a number in bytes and converts it to Kilo, Mega, or Gigabytes.
  my $num = shift;
  my $i = 0;
  while ($num >= 1024){
    $num = $num/1024; $i++;
  }
  my $unit = $i==0 ? "B" : $i==1 ? "KB" : $i==2 ? "MB" : $i==3 ? "GB" : "(TooBig)";
  my $returnstring = sprintf "%.2f %s", $num, $unit;
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
    while (<SETTINGS>){ $dbString = $_ and last if m/^\$db_url.*/; }
    close SETTINGS;
  } else { return "Error reading $settings_file";}

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
#  return $db_size_h;
} # END SUB drupal_db_size
