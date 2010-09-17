#! /usr/bin/perl -W
#
# install.pl
#
# This script will create database tables as necessary.
# 
# It is part of the NewsStats package.
#
# Copyright (c) 2010 Thomas Hochstein <thh@inter.net>
#
# It can be redistributed and/or modified under the same terms under 
# which Perl itself is published.

BEGIN {
  our $VERSION = "0.01";
  use File::Basename;
  # we're in .../install, so our module is in ..
  push(@INC, dirname($0).'/..');
}
use strict;

use NewsStats qw(:DEFAULT);

use Cwd;

use DBI;

################################# Main program #################################

### read commandline options
my %Options = &ReadOptions('');

### change working directory to .. (as we're in .../install)
chdir dirname($0).'/..';

### read configuration
print("Reading configuration.\n");
my %Conf = %{ReadConfig('newsstats.conf')};

##### --------------------------------------------------------------------------
##### Database table definitions
##### --------------------------------------------------------------------------

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

##### --------------------------- End of definitions ---------------------------

### create database tables
print "-----\nStarting database table generation.\n";
# DB init
my $DBHandle = InitDB(\%Conf,1);

# read tables
my %TablesInDB = %{$DBHandle->table_info('%', '%', '%', 'TABLE')->fetchall_hashref('TABLE_NAME')};

# check for tables and create them, if they don't exist yet
foreach my $Table (keys %DBCreate) {
  if (defined($TablesInDB{$Conf{$Table}})) {
    printf("Database table %s.%s already exists, skipping ....\n",$Conf{'DBDatabase'},$Conf{$Table});
    next;
  };
  my $DBQuery = $DBHandle->prepare($DBCreate{$Table});
  $DBQuery->execute() or die sprintf("$MySelf: E: Can't create table %s in database %s: %s%\n",$Table,$Conf{'DBDatabase'},$DBI::errstr);
  printf("Database table %s.%s created succesfully.\n",$Conf{'DBDatabase'},$Conf{$Table});
};

# close handle
$DBHandle->disconnect;
print "Database table generation done.\n";

### output information on other necessary steps
my $Path = cwd();
print <<TODO;
-----
Things left to do:

1) Setup an INN feed to feedlog.pl

   a) Edit your 'newsfeeds' file and insert something like

          ## gather statistics for NewsStats
          newsstats!\
                  :!*,de.*\
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
TODO
