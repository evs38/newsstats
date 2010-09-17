#! /usr/bin/perl -W
#
# gatherstats.pl
#
# This script will gather statistical information from a database
# containing headers and other information from a INN feed.
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

use NewsStats qw(:DEFAULT :TimePeriods ListNewsgroups);

use DBI;

################################# Definitions ##################################

# define types of information that can be gathered
# all / groups (/ clients / hosts)
my %LegalTypes;
@LegalTypes{('all','groups')} = ();

################################# Main program #################################

### read commandline options
my %Options = &ReadOptions('dom:p:t:n:r:g:c:s:');

### read configuration
my %Conf = %{ReadConfig('newsstats.conf')};

### override configuration via commandline options
my %ConfOverride;
$ConfOverride{'DBTableRaw'}   = $Options{'r'} if $Options{'r'};
$ConfOverride{'DBTableGrps'}  = $Options{'g'} if $Options{'g'};
$ConfOverride{'DBTableClnts'} = $Options{'c'} if $Options{'c'};
$ConfOverride{'DBTableHosts'} = $Options{'s'} if $Options{'s'};
$ConfOverride{'TLH'} = $Options{'n'} if $Options{'n'};
&OverrideConfig(\%Conf,\%ConfOverride);

### get type of information to gather, default to 'all'
$Options{'t'} = 'all' if !$Options{'t'};
die "$MySelf: E: Unknown type '-t $Options{'t'}'!\n" if !exists($LegalTypes{$Options{'t'}});

### get time period
my ($StartMonth,$EndMonth) = &GetTimePeriod($Options{'m'},$Options{'p'});

### init database
my $DBHandle = InitDB(\%Conf,1);

### get data for each month
warn "$MySelf: W: Output only mode. Database is not updated.\n" if $Options{'o'};
foreach my $Month (&ListMonth($StartMonth,$EndMonth)) {

  print "---------- $Month ----------\n" if $Options{'d'};

  if ($Options{'t'} eq 'all' or $Options{'t'} eq 'groups') {
    ### ----------------------------------------------
    ### get groups data (number of postings per group)
    # get groups data from raw table for given month
    my $DBQuery = $DBHandle->prepare(sprintf("SELECT newsgroups FROM %s.%s WHERE day LIKE ? AND NOT disregard",$Conf{'DBDatabase'},$Conf{'DBTableRaw'}));
    $DBQuery->execute($Month.'-%') or die sprintf("$MySelf: E: Can't get groups data for %s from %s.%s: $DBI::errstr\n",$Month,$Conf{'DBDatabase'},$Conf{'DBTableRaw'});

    # count postings per group
    my %Postings;

    while (($_) = $DBQuery->fetchrow_array) {
      # get list oft newsgroups and hierarchies from Newsgroups:
      my %Newsgroups = ListNewsgroups($_);
      # count each newsgroup and hierarchy once
      foreach (sort keys %Newsgroups) {
        # don't count newsgroup/hierarchy in wrong TLH
        next if(defined($Conf{'TLH'}) and !/^$Conf{'TLH'}/);
        $Postings{$_}++;
      };
    };

    print "----- GroupStats -----\n" if $Options{'d'};
    foreach my $Newsgroup (sort keys %Postings) {
      print "$Newsgroup => $Postings{$Newsgroup}\n" if $Options{'d'};
      if (!$Options{'o'}) {
        # write to database
        $DBQuery = $DBHandle->prepare(sprintf("REPLACE INTO %s.%s (month,newsgroup,postings) VALUES (?, ?, ?)",$Conf{'DBDatabase'},$Conf{'DBTableGrps'}));
        $DBQuery->execute($Month, $Newsgroup, $Postings{$Newsgroup}) or die sprintf("$MySelf: E: Can't write groups data for %s/%s to %s.%s: $DBI::errstr\n",$Month,$Newsgroup,$Conf{'DBDatabase'},$Conf{'DBTableGrps'});
        $DBQuery->finish;
      };
    };
  };
};

### close handles
$DBHandle->disconnect;

