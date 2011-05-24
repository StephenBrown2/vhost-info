#!/usr/bin/perl
use warnings;
use strict;

use Apache::Admin::Config;
use App::Info::HTTPD::Apache;
use File::Spec;
use Sys::Hostname;

my $apache = App::Info::HTTPD::Apache->new;
my $main_conf = new Apache::Admin::Config( $apache->conf_file );
(my $ServerRoot = $main_conf->directive('DocumentRoot')) =~ s/\"//g;

my %DocumentRoots = ($ServerRoot => 1);

my @all_conf = ($apache->conf_file, $main_conf->directive('Include'));
map { $_ = File::Spec->rel2abs($_, $apache->httpd_root) } @all_conf;

printf "%15s %s\n%15s %s\n%15s %s\n\n", "Generated by:", $0, "on date:", scalar localtime, "for server:", hostname;

for (@all_conf) {

	my $conf = new Apache::Admin::Config($_);

	print "Conf file: $_\n";

	foreach($conf->section('VirtualHost'))
	{
		printf "%15s: %s\n",$_->name,$_->directive('ServerName')->value if defined $_->directive('ServerName');
		foreach($_->directive('ServerAlias')) {
			printf "%15s: %s\n","Alias",$_->value;
		}
		my $DR = $_->directive('DocumentRoot') ? $_->directive('DocumentRoot') : 'None';
		printf "%15s: %s\n", "DocumentRoot", $DR;
		if ($DR eq 'None') {
			foreach my $direc ($_->directive()){
				printf "%15s: %s\n",$direc->name,$direc->value
				unless ($direc->name eq 'ServerName' || $direc->name eq 'ServerAlias');
			}
		}
		print "\n";
		$DocumentRoots{File::Spec->canonpath($DR)}++;
	}
}
print "\nDocument Roots to be aware of:\n\n";
foreach (sort {$DocumentRoots{$b} <=> $DocumentRoots{$a} or $a cmp $b} keys %DocumentRoots)
{
	#printf "%2d site%s using %s\n", $DocumentRoots{$_}, ($DocumentRoots{$_} == 1) ? ' ' : 's', $_;
	print "$_\n" unless $_ eq "None";
}