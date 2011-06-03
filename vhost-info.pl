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
our($opt_d, $opt_s, $opt_a);
getopts('dsa');

($opt_d, $opt_s) = (1) x 2 if $opt_a; # Set all variables, if the -a option is set

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
                        printf "%15s: %s\n", "Database", $drush{'database_name'};
                        if ($drush{'database_hostname'} ne 'localhost') {
                            printf "%15s: %s\n", "Database Host", $drush{'database_hostname'};
                            printf "%15s: %s\n", "Database User", $drush{'database_username'}
                                if $drush{'database_username'} ne 'root';
                        }
                        printf "%15s: %s\n", "Database Status",  $drush{'database'} ? $drush{'database'} : "Error!";
                    } else { # Otherwise, just say so.
                        printf "%15s: %s\n", "Drupal", "No";
                    }
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
  print "\t-a\tPerform all of the above. Overrides any other option specified\n\n";
  print "Options may be merged together. (Though at this point it'd be kind of pointless. :-p )\n\n";
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
}
