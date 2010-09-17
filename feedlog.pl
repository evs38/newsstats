#! /usr/bin/perl -W
#
# feedlog.pl
#
# This script will log headers and other data to a database
# for further analysis by parsing a feed from INN.
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
  push(@INC, dirname($0));
}
use strict;

use NewsStats;

use Sys::Syslog qw(:standard :macros);

use Date::Format;
use DBI;

################################# Main program #################################

### read commandline options
my %Options = &ReadOptions('qd');

### read configuration
my %Conf = %{ReadConfig('newsstats.conf')};

### init syslog
openlog($MySelf, 'nofatal,pid', LOG_NEWS);
syslog(LOG_NOTICE, "$MyVersion starting up.") if !$Options{'q'};

### init database
my $DBHandle = InitDB(\%Conf,0);
if (!$DBHandle) {
  syslog(LOG_CRIT, 'Database connection failed: %s', $DBI::errstr);
  while (1) {}; # go into endless loop to suppress further errors and respawning
};
my $DBQuery = $DBHandle->prepare(sprintf("INSERT INTO %s.%s (day,date,mid,timestamp,token,size,peer,path,newsgroups,headers) VALUES (?,?,?,?,?,?,?,?,?,?)",$Conf{'DBDatabase'},$Conf{'DBTableRaw'}));

### main loop
while (<>) {
  chomp;
  # catch empty lines trailing or leading
  if ($_ eq '') {
    next;
  }
  # first line contains: mid, timestamp, token, size, peer, Path, Newsgroups
  my ($Mid, $Timestamp, $Token, $Size, $Peer, $Path, $Newsgroups) = split;
  # remaining lines contain headers
  my $Headers = "";
  while (<>) {
    chomp;
    # empty line terminates this article
    if ($_ eq '') {
      last;
    }
    # collect headers
    $Headers .= $_."\n" ;
  }

  # parse timestamp to day (YYYY-MM-DD) and to MySQL timestamp
  my $Day  = time2str("%Y-%m-%d", $Timestamp);
  my $Date = time2str("%Y-%m-%d %H:%M:%S", $Timestamp);

  # write to database
  if (!$DBQuery->execute($Day, $Date, $Mid, $Timestamp, $Token, $Size, $Peer, $Path, $Newsgroups, $Headers)) {
    syslog(LOG_ERR, 'Database error: %s', $DBI::errstr);
  };
  $DBQuery->finish;
  
  warn sprintf("-----\nDay: %s\nDate: %s\nMID: %s\nTS: %s\nToken: %s\nSize: %s\nPeer: %s\nPath: %s\nNewsgroups: %s\nHeaders: %s\n",$Day, $Date, $Mid, $Timestamp, $Token, $Size, $Peer, $Path, $Newsgroups, $Headers) if !$Options{'d'};
}

### close handles
$DBHandle->disconnect;
syslog(LOG_NOTICE, "$MySelf closing down.") if !$Options{'q'};
closelog();

