#! /usr/bin/perl
#
# install.pl
#
# This script will create database tables as necessary.
#
# It is part of the NewsStats package.
#
# Copyright (c) 2010-2013 Thomas Hochstein <thh@inter.net>
#
# It can be redistributed and/or modified under the same terms under
# which Perl itself is published.

BEGIN {
  our $VERSION = "0.02";
  use File::Basename;
  # we're in .../install, so our module is in ../lib
  push(@INC, dirname($0).'/../lib');
}
use strict;
use warnings;

use NewsStats qw(:DEFAULT);

use Cwd;

use DBI;
use Getopt::Long qw(GetOptions);
Getopt::Long::config ('bundling');

################################# Main program #################################

### read commandline options
my ($OptUpdate,$OptConfFile);
GetOptions ('u|update=s' => \$OptUpdate,
            'conffile=s' => \$OptConfFile,
            'h|help'     => \&ShowPOD,
            'V|version'  => \&ShowVersion) or exit 1;

### change working directory to .. (as we're in .../install)
chdir dirname($FullPath).'/..';
my $Path = cwd();

### read configuration
print("Reading configuration.\n");
my %Conf = %{ReadConfig($OptConfFile)};

##### --------------------------------------------------------------------------
##### Database table definitions
##### --------------------------------------------------------------------------

my $DBCreate = <<SQLDB;
CREATE DATABASE IF NOT EXISTS `$Conf{'DBDatabase'}` DEFAULT CHARSET=utf8;
SQLDB

my %DBCreate = ('DBTableRaw'  => <<RAW, 'DBTableGrps' => <<GRPS);
--
-- Table structure for table DBTableRaw
--

CREATE TABLE IF NOT EXISTS `$Conf{'DBTableRaw'}` (
  `id` bigint(20) unsigned NOT NULL auto_increment,
  `day` date NOT NULL,
  `mid` varchar(250) character set ascii NOT NULL,
  `date` datetime NOT NULL,
  `timestamp` bigint(20) NOT NULL,
  `token` varchar(80) character set ascii NOT NULL,
  `size` bigint(20) NOT NULL,
  `peer` varchar(250) NOT NULL,
  `path` varchar(1000) NOT NULL,
  `newsgroups` varchar(1000) NOT NULL,
  `headers` longtext NOT NULL,
  `disregard` tinyint(1) default '0',
  PRIMARY KEY  (`id`),
  KEY `day` (`day`),
  KEY `mid` (`mid`),
  KEY `peer` (`peer`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Raw data';
RAW
--
-- Table structure for table DBTableGrps
--

CREATE TABLE IF NOT EXISTS `$Conf{'DBTableGrps'}` (
  `id` bigint(20) unsigned NOT NULL auto_increment,
  `month` varchar(7) character set ascii NOT NULL,
  `newsgroup` varchar(100) NOT NULL,
  `postings` int(11) NOT NULL,
  `revision` timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP,
  PRIMARY KEY  (`id`),
  UNIQUE KEY `month_newsgroup` (`month`,`newsgroup`),
  KEY `newsgroup` (`newsgroup`),
  KEY `postings` (`postings`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Postings per newsgroup';
GRPS

##### --------------------------------------------------------------------------
##### Installation / upgrade instructions
##### --------------------------------------------------------------------------

my $Install = <<INSTALL;
----------
Things left to do:

1) Setup an INN feed to feedlog.pl

   a) Edit your 'newsfeeds' file and insert something like

          ## gather statistics for NewsStats
          newsstats!\\
                  :!*,de.*\\
                  :Tc,WmtfbsPNH,Ac:$Path/feedlog.pl

      Please

      * check that you got the path to feedlog.pl right
      * check that feedlog.pl can be executed by the news user
      * adapt the pattern (here: 'de.*') to your needs

   b) Check your 'newsfeeds' syntax:

         # ctlinnd checkfile

      and reload 'newsfeeds':

         # ctlinnd reload newsfeeds 'Adding newsstats! feed'

   c) Watch your 'news.notice' and 'errlog' files:

         # tail -f /var/log/news/news.notice
         ...
         # tail -f /var/log/news/errlog

2) Watch your $Conf{'DBTableRaw'} table fill.

3) Read the documentation. ;)

Enjoy!

-thh <thh\@inter.net>
INSTALL

my $Upgrade ='';
if ($OptUpdate) {
 $Upgrade = <<UPGRADE;
----------
Your installation was upgraded from $OptUpdate to $PackageVersion.

Don't forget to restart your INN feed so that it can pick up the new version:

   # ctlinnd begin 'newsstats!'

(or whatever you called your feed).
UPGRADE
}

##### --------------------------- End of definitions ---------------------------

### create DB, if necessary
if (!$OptUpdate) {
  print "----------\nStarting database creation.\n";
  # create database
  # we can't use InitDB() as that will use a table name of
  # the table that doesn't exist yet ...
  my $DBHandle = DBI->connect(sprintf('DBI:%s:host=%s',$Conf{'DBDriver'},
                                      $Conf{'DBHost'}), $Conf{'DBUser'},
                                      $Conf{'DBPw'}, { PrintError => 0 });
  my $DBQuery = $DBHandle->prepare($DBCreate);
  $DBQuery->execute() or &Bleat(2, sprintf("Can't create database %s: %s%\n",
                                           $Conf{'DBDatabase'}, $DBI::errstr));

  printf("Database table %s created succesfully.\n",$Conf{'DBDatabase'});
  $DBHandle->disconnect;
};

### DB init, read list of tables
print "Reading database information.\n";
my $DBHandle = InitDB(\%Conf,1);
my %TablesInDB =
   %{$DBHandle->table_info('%', '%', '%', 'TABLE')->fetchall_hashref('TABLE_NAME')};

if (!$OptUpdate) {
  ##### installation mode
  # check for tables and create them, if they don't exist yet
  foreach my $Table (keys %DBCreate) {
    &CreateTable($Table);
  };
  print "Database table generation done.\n";

  # Display install instructions
  print $Install;
} else {
  ##### upgrade mode
  print "----------\nStarting upgrade process.\n";
  $PackageVersion = '0.03';
  if ($OptUpdate < $PackageVersion) {
    if ($OptUpdate < 0.02) {
      # 0.01 -> 0.02
      # &DoMySQL('...;');
      # print "v0.02: Database upgrades ...\n";
      # &PrintInstructions('0.02',<<"      INSTRUCTIONS");
      # INSTRUCTIONS
    };
  };
  # Display general upgrade instructions
  print $Upgrade;
};

# close handle
$DBHandle->disconnect;

exit(0);

################################# Subroutines ##################################

sub CreateTable {
  my $Table = shift;
  if (defined($TablesInDB{$Conf{$Table}})) {
    printf("Database table %s.%s already exists, skipping ....\n",
           $Conf{'DBDatabase'},$Conf{$Table});
    return;
  };
  my $DBQuery = $DBHandle->prepare($DBCreate{$Table});
  $DBQuery->execute() or
    &Bleat(2, sprintf("Can't create table %s in database %s: %s%\n",$Table,
                      $Conf{'DBDatabase'},$DBI::errstr));
  printf("Database table %s.%s created succesfully.\n",
         $Conf{'DBDatabase'},$Conf{$Table});
  return;
};

sub DoMySQL {
  my $SQL = shift;
  my $DBQuery = $DBHandle->prepare($SQL);
  $DBQuery->execute() or &Bleat(1, sprintf("Database error: %s\n",$DBI::errstr));
  return;
};

sub PrintInstructions {
  my ($UpVersion,$Instructions) = @_;
  print "v$UpVersion: Upgrade Instructions >>>>>\n";
  my $Padding = ' ' x (length($UpVersion) + 3);
    $Instructions =~ s/^      /$Padding/mg;
    print $Instructions;
    print "<" x (length($UpVersion) + 29) . "\n";
};


__END__

################################ Documentation #################################

=head1 NAME

install - installation script

=head1 SYNOPSIS

B<install> [B<-Vh> [--update I<version>] [B<--conffile> I<filename>]

=head1 REQUIREMENTS

See L<doc/README>.

=head1 DESCRIPTION

This script will create database tables as necessary and configured.

=head2 Configuration

B<install> will read its configuration from F<newsstats.conf> which should
be present in etc/ via Config::Auto or from a configuration file submitted
by the B<--conffile> option.

See L<doc/INSTALL> for an overview of possible configuration options.

=head1 OPTIONS

=over 3

=item B<-V>, B<--version>

Print out version and copyright information and exit.

=item B<-h>, B<--help>

Print this man page and exit.

=item B<-u>, B<--update> I<version>

Don't do a fresh install, but update from I<version>.

=item B<--conffile> I<filename>

Load configuration from I<filename> instead of F<newsstats.conf>.

=back

=head1 FILES

=over 4

=item F<install/install.pl>

The script itself.

=item F<lib/NewsStats.pm>

Library functions for the NewsStats package.

=item F<etc/newsstats.conf>

Runtime configuration file.

=back

=head1 BUGS

Please report any bugs or feature requests to the author or use the
bug tracker at L<http://bugs.th-h.de/>!

=head1 SEE ALSO

=over 2

=item -

L<doc/README>

=item -

L<doc/INSTALL>

=back

This script is part of the B<NewsStats> package.

=head1 AUTHOR

Thomas Hochstein <thh@inter.net>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2010-2013 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
