vhost-info
==========

A script to determine information about the apache virtualhosts on a machine. Highly Drupal-centric, requires drush.

Requirements
============

Drush must be installed and accessible to the sudoer's path. Additionally, git should be installed to find related
information.

This script uses several Perl modules not commonly found on a base CentOS install, but that can be easily installed
from well-known repositories, namely repoforge.

This is a list of all modules used by the script.

| Module                       | Package                      | CentOS 5 Repository | CentOS 6 Repository |
| ---------------------------- | ---------------------------- | ------------------- | ------------------- |
| Apache::Admin::Config        | perl-Apache-Admin-Config     | repoforge           | repoforge           |
| App::Info::HTTPD::Apache     | perl-App-Info                | repoforge           | repoforge           |
| File::Basename               | perl                         | Core Module         | Core Module         |
| File::Spec                   | perl                         | Core Module         | Core Module         |
| Filesys::DiskUsage           | perl-Filesys-DiskUsage       | repoforge           | repoforge           |
| Getopt::Long::Descriptive    | perl-Getopt-Long-Descriptive | repoforge           | epel,repoforge      |
| LWP::Simple                  | perl-libwww-perl             | base,repoforge      | base,repoforge      |
| Net::DNS                     | perl-Net-DNS                 | base                | base                |
| Sys::Hostname                | perl                         | Core Module         | Core Module         |

If you would like to install all the prerequisite packages, first make sure you have the
[repoforge repository](http://repoforge.org/use) installed and enabled.

Then run:
<pre>sudo yum install perl-Apache-Admin-Config perl-App-Info perl-Filesys-DiskUsage \
perl-Getopt-Long-Descriptive perl-libwww-perl perl-Net-DNS</pre>

Usage
=====

Run `vhost-info` to print a list of virtualhosts as described by `httpd -S`, with information such as configuratiion file,
VirtualHost ServerName and any Aliases defined, with the IP address that the URL resolves to, if possible, as well as the DocumentRoot

Add additional flags to get more information:

    --logs | -l,   Check if any log files mentioned in conf file are missing
    --size | -s,   Display the size of each DocumentRoot and all subdirs
    --drupal | -d, Display the status of a Drupal install by running `drush status` in each DocumentRoot
    --dbsize | -b, Display the size of the Drupal database, if it exists
    --solr | -o,   Display module version and solr core url provided by apachesolr module in each DocumentRoot,
                   if available
    --roots | r,   Print a list of the Document Roots at the end of the report
    --git | -g,    Print relevant git information, namely if the directory is in a git repository, and if available,
                   the remote repository information
    --all | -a,    Perform all of the above, with verbose output. Overrides above options if specified
    --name | -n,   Filter results found by vhost ServerName or Alias. Usage: -n 'filterurl'
    
    --head, Prints the summary information and exits immediately.
    
    --verbose | -v, Prints extra information during run
    --help | -h,    Prints this help message and exits immediately.
