#! /usr/bin/perl -W
#
# groupstats.pl
#
# This script will get statistical data on newgroup usage
# form a database.
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

use NewsStats qw(:DEFAULT :TimePeriods :Output :SQLHelper);

use DBI;

################################# Definitions ##################################

# ...

################################# Main program #################################

### read commandline options
my %Options = &ReadOptions('m:p:n:o:t:l:b:iscqdg:');

### read configuration
my %Conf = %{ReadConfig('newsstats.conf')};

### override configuration via commandline options
my %ConfOverride;
$ConfOverride{'DBTableGrps'}  = $Options{'g'} if $Options{'g'};
&OverrideConfig(\%Conf,\%ConfOverride);

### default output type to 'dump'
$Options{'o'} = 'dump' if !$Options{'o'};
# fail if more than one newsgroup is combined with 'dumpgroup' type
die ("$MySelf: E: You cannot combine newsgroup lists (-n) with more than one group with '-o dumpgroup'!\n") if ($Options{'o'} eq 'dumpgroup' and defined($Options{'n'}) and $Options{'n'} =~ /:|\*/);
# accept 'dumpgroup' only with -n
if ($Options{'o'} eq 'dumpgroup' and !defined($Options{'n'})) {
  $Options{'o'} = 'dump';
  warn ("$MySelf: W: You must submit exactly one newsgroup ('-n news.group') for '-o dumpgroup'. Output type was set to 'dump'.\n");
};
# you can't mix '-t' and '-b'
if ($Options{'b'}) {
  if ($Options{'t'}) {
    warn ("$MySelf: W: You cannot combine thresholds (-t) and top lists (-b). Threshold '-t $Options{'t'}' was ignored.\n");
    undef($Options{'t'});
  };
  warn ("$MySelf: W: Sorting by number of postings (-q) ignored due to top list mode (-b).\n") if $Options{'q'};
  warn ("$MySelf: W: Reverse sorting (-d) ignored due to top list mode (-b).\n") if $Options{'d'};
};

### get query type, default to 'postings'
#die "$MySelf: E: Unknown query type -q $Options{'q'}!\n" if ($Options{'q'} and !exists($LegalTypes{$Options{'q'}}));
#die "$MySelf: E: You must submit a threshold ('-t') for query type '-q $Options{'q'}'!\n" if ($Options{'q'} and !$Options{'t'});

### get time period
my ($StartMonth,$EndMonth) = &GetTimePeriod($Options{'m'},$Options{'p'});
# reset to one month for 'dump' type
if ($Options{'o'} eq 'dump' and $Options{'p'}) {
  $StartMonth = $EndMonth;
  warn ("$MySelf: W: You cannot combine time periods (-p) with '-o dump'. Month was set to $StartMonth.\n");
};

### init database
my $DBHandle = InitDB(\%Conf,1);

### get data
# get list of newsgroups (-n)
my ($QueryPart,@GroupList);
my $Newsgroups = $Options{'n'};
if ($Newsgroups) {
  ($QueryPart,@GroupList) = &SQLGroupList($Newsgroups);
} else {
  $QueryPart = 1;
};

# manage thresholds
if (defined($Options{'t'})) {
  if ($Options{'i'}) {
    $QueryPart .= ' AND postings < ?';
  } else {
    $QueryPart .= ' AND postings > ?';
  };
  push @GroupList,$Options{'t'};
}

# construct WHERE clause
my $WhereClause = sprintf('month BETWEEN ? AND ? AND %s %s',$QueryPart,&SQLHierarchies($Options{'s'}));

# get lenght of longest newsgroup delivered by query for formatting purposes
my $MaxLength = &GetMaxLenght($DBHandle,$Conf{'DBTableGrps'},'newsgroup',$WhereClause,$StartMonth,$EndMonth,@GroupList);

my ($OrderClause,$DBQuery);
# -b (best of) defined?
if (!defined($Options{'b'}) and !defined($Options{'l'})) {
  $OrderClause = 'newsgroup';
  $OrderClause = 'postings' if $Options{'q'};
  $OrderClause .= ' DESC' if $Options{'d'};
  # do query: get number of postings per group from groups table for given months and newsgroups
  $DBQuery = $DBHandle->prepare(sprintf("SELECT month,newsgroup,postings FROM %s.%s WHERE %s ORDER BY month,%s",$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$WhereClause,$OrderClause));
} elsif ($Options{'b'}) {
  # set sorting order (-i)
  if ($Options{'i'}) {
    $OrderClause = 'postings';
  } else {
    $OrderClause = 'postings DESC';
  };
  # push LIMIT to GroupList to match number of binding vars
  push @GroupList,$Options{'b'};
  # do query: get sum of postings per group from groups table for given months and newsgroups with LIMIT
  $DBQuery = $DBHandle->prepare(sprintf("SELECT newsgroup,SUM(postings) AS postings FROM %s.%s WHERE %s GROUP BY newsgroup ORDER BY %s,newsgroup LIMIT ?",$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$WhereClause,$OrderClause));
} else { # -l
  # set sorting order (-i)
  if ($Options{'i'}) {
    $OrderClause = '<';
  } else {
    $OrderClause = '>';
  };
  # push level and $StartMonth,$EndMonth - again - to GroupList to match number of binding vars
  push @GroupList,$Options{'l'};
  push @GroupList,$StartMonth,$EndMonth;
  # do query: get number of postings per group from groups table for given months and 
  $DBQuery = $DBHandle->prepare(sprintf("SELECT month,newsgroup,postings FROM %s.%s WHERE newsgroup IN (SELECT newsgroup FROM %s.%s WHERE %s GROUP BY newsgroup HAVING MAX(postings) %s ?) AND %s ORDER BY newsgroup,month",$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$WhereClause,$OrderClause,$WhereClause));
};

# execute query
$DBQuery->execute($StartMonth,$EndMonth,@GroupList) or die sprintf("$MySelf: E: Can't get groups data for %s to %s from %s.%s: %s\n",$StartMonth,$EndMonth,$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$DBI::errstr);

# output result
printf ("----- Report from %s to %s\n",$StartMonth,$EndMonth) if $Options{'c'} and ($Options{'m'} or $Options{'p'});
printf ("----- Newsgroups: %s\n",join(',',split(/:/,$Newsgroups))) if $Options{'c'} and $Options{'n'};
printf ("----- Threshold: %s %u\n",$Options{'i'} ? '<' : '>',$Options{'t'}) if $Options{'c'} and $Options{'t'};
if (!defined($Options{'b'})  and !defined($Options{'l'})) {
   &OutputData($Options{'o'},$DBQuery,$MaxLength);
} elsif ($Options{'b'}) {
   while (my ($Newsgroup,$Postings) = $DBQuery->fetchrow_array) {
    print &FormatOutput($Options{'o'}, ($Options{'i'} ? 'Bottom ' : 'Top ').$Options{'b'}, $Newsgroup, $Postings, $MaxLength);
  };
} else { # -l
   while (my ($Month,$Newsgroup,$Postings) = $DBQuery->fetchrow_array) {
    print &FormatOutput($Options{'o'}, $Newsgroup, $Month, $Postings, 7);
  };
};

### close handles
$DBHandle->disconnect;

