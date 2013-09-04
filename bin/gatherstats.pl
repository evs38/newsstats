#! /usr/bin/perl
#
# gatherstats.pl
#
# This script will gather statistical information from a database
# containing headers and other information from a INN feed.
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
  # we're in .../bin, so our module is in ../lib
  push(@INC, dirname($0).'/../lib');
}
use strict;
use warnings;

use NewsStats qw(:DEFAULT :TimePeriods ListNewsgroups ParseHierarchies ReadGroupList);

use DBI;
use Getopt::Long qw(GetOptions);
Getopt::Long::config ('bundling');

################################# Definitions ##################################

# define types of information that can be gathered
# all / groups (/ clients / hosts)
my %LegalStats;
@LegalStats{('all','groups')} = ();

################################# Main program #################################

### read commandline options
my ($OptCheckgroupsFile,$OptClientsDB,$OptDebug,$OptGroupsDB,$OptTLH,
    $OptHostsDB,$OptMonth,$OptRawDB,$OptStatsType,$OptTest,$OptConfFile);
GetOptions ('c|checkgroups=s' => \$OptCheckgroupsFile,
            'clientsdb=s'     => \$OptClientsDB,
            'd|debug!'        => \$OptDebug,
            'groupsdb=s'      => \$OptGroupsDB,
            'hierarchy=s'     => \$OptTLH,
            'hostsdb=s'       => \$OptHostsDB,
            'm|month=s'       => \$OptMonth,
            'rawdb=s'         => \$OptRawDB,
            's|stats=s'       => \$OptStatsType,
            't|test!'         => \$OptTest,
            'conffile=s'      => \$OptConfFile,
            'h|help'          => \&ShowPOD,
            'V|version'       => \&ShowVersion) or exit 1;

### read configuration
my %Conf = %{ReadConfig($OptConfFile)};

### override configuration via commandline options
my %ConfOverride;
$ConfOverride{'DBTableRaw'}   = $OptRawDB if $OptRawDB;
$ConfOverride{'DBTableGrps'}  = $OptGroupsDB if $OptGroupsDB;
$ConfOverride{'DBTableClnts'} = $OptClientsDB if $OptClientsDB;
$ConfOverride{'DBTableHosts'} = $OptHostsDB if $OptHostsDB;
$ConfOverride{'TLH'} = $OptTLH if $OptTLH;
&OverrideConfig(\%Conf,\%ConfOverride);

### get type of information to gather, defaulting to 'all'
$OptStatsType = 'all' if !$OptStatsType;
&Bleat(2, sprintf("Unknown type '%s'!", $OptStatsType))
  if !exists($LegalStats{$OptStatsType});

### get time period from --month
# get verbal description of time period, drop SQL code
my ($Period) = &GetTimePeriod($OptMonth);
# bail out if --month is invalid or set to 'ALL';
# we don't support the latter
&Bleat(2,"--month option has an invalid format - please use 'YYYY-MM' or ".
         "'YYYY-MM:YYYY-MM'!") if (!$Period or $Period eq 'all time');

### reformat $Conf{'TLH'}
my $TLH;
if ($Conf{'TLH'}) {
  # $Conf{'TLH'} is parsed as an array by Config::Auto;
  # make a flat list again, separated by :
  if (ref($Conf{'TLH'}) eq 'ARRAY') {
    $TLH = join(':',@{$Conf{'TLH'}});
  } else {
    $TLH  = $Conf{'TLH'};
  }
  # strip whitespace
  $TLH =~ s/\s//g;
  # add trailing dots if none are present yet
  # (using negative look-behind assertions)
  $TLH =~ s/(?<!\.):/.:/g;
  $TLH =~ s/(?<!\.)$/./;
  # check for illegal characters
  &Bleat(2,'Config error - illegal characters in TLH definition!')
    if ($TLH !~ /^[a-zA-Z0-9:+.-]+$/);
  # escape dots
  $TLH =~ s/\./\\./g;
  if ($TLH =~ /:/) {
    # reformat $TLH from a:b to (a)|(b),
    # e.g. replace ':' by ')|('
    $TLH =~ s/:/)|(/g;
    $TLH = '(' . $TLH . ')';
  };
};

### init database
my $DBHandle = InitDB(\%Conf,1);

### get data for each month
&Bleat(1,'Test mode. Database is not updated.') if $OptTest;
foreach my $Month (&ListMonth($Period)) {

  print "---------- $Month ----------\n" if $OptDebug;

  if ($OptStatsType eq 'all' or $OptStatsType eq 'groups') {
    # read list of newsgroups from --checkgroups
    # into a hash
    my %ValidGroups = %{ReadGroupList(sprintf('%s-%s',$OptCheckgroupsFile,$Month))}
      if $OptCheckgroupsFile;

    ### ----------------------------------------------
    ### get groups data (number of postings per group)
    # get groups data from raw table for given month
    my $DBQuery = $DBHandle->prepare(sprintf("SELECT newsgroups FROM %s.%s ".
                                             "WHERE day LIKE ? AND NOT disregard",
                                             $Conf{'DBDatabase'},
                                             $Conf{'DBTableRaw'}));
    $DBQuery->execute($Month.'-%')
      or &Bleat(2,sprintf("Can't get groups data for %s from %s.%s: ".
                          "$DBI::errstr\n",$Month,
                          $Conf{'DBDatabase'},$Conf{'DBTableRaw'}));

    # count postings per group
    my %Postings;
    while (($_) = $DBQuery->fetchrow_array) {
      # get list of newsgroups and hierarchies from Newsgroups:
      my %Newsgroups = ListNewsgroups($_,$TLH,
                                      $OptCheckgroupsFile ? \%ValidGroups : '');
      # count each newsgroup and hierarchy once
      foreach (sort keys %Newsgroups) {
        $Postings{$_}++;
      };
    };

    # add valid but empty groups if --checkgroups is set
    if (%ValidGroups) {
      foreach (sort keys %ValidGroups) {
        if (!defined($Postings{$_})) {
          # add current newsgroup as empty group
          $Postings{$_} = 0;
          warn (sprintf("ADDED: %s as empty group\n",$_));
          # add empty hierarchies for current newsgroup as needed
          foreach (ParseHierarchies($_)) {
            my $Hierarchy = $_ . '.ALL';
            if (!defined($Postings{$Hierarchy})) {
              $Postings{$Hierarchy} = 0;
              warn (sprintf("ADDED: %s as empty group\n",$Hierarchy));
            };
          };
        }
      };
    };

    # delete old data for that month
    if (!$OptTest) {
      $DBQuery = $DBHandle->do(sprintf("DELETE FROM %s.%s WHERE month = ?",
                                       $Conf{'DBDatabase'},$Conf{'DBTableGrps'}),
                                       undef,$Month)
        or &Bleat(2,sprintf("Can't delete old groups data for %s from %s.%s: ".
                            "$DBI::errstr\n",$Month,
                            $Conf{'DBDatabase'},$Conf{'DBTableGrps'}));
    };

    print "----- GroupStats -----\n" if $OptDebug;
    foreach my $Newsgroup (sort keys %Postings) {
      print "$Newsgroup => $Postings{$Newsgroup}\n" if $OptDebug;
      if (!$OptTest) {
        # write to database
        $DBQuery = $DBHandle->prepare(sprintf("INSERT INTO %s.%s ".
                                              "(month,newsgroup,postings) ".
                                              "VALUES (?, ?, ?)",
                                              $Conf{'DBDatabase'},
                                              $Conf{'DBTableGrps'}));
        $DBQuery->execute($Month, $Newsgroup, $Postings{$Newsgroup})
          or &Bleat(2,sprintf("Can't write groups data for %s/%s to %s.%s: ".
                              "$DBI::errstr\n",$Month,$Newsgroup,
                              $Conf{'DBDatabase'},$Conf{'DBTableGrps'}));
        $DBQuery->finish;
      };
    };
  } else {
    # other types of information go here - later on
  };
};

### close handles
$DBHandle->disconnect;

__END__

################################ Documentation #################################

=head1 NAME

gatherstats - process statistical data from a raw source

=head1 SYNOPSIS

B<gatherstats> [B<-Vhdt>] [B<-m> I<YYYY-MM> | I<YYYY-MM:YYYY-MM>] [B<-s> I<stats>] [B<-c> I<filename template>]] [B<--hierarchy> I<TLH>] [B<--rawdb> I<database table>] [B<-groupsdb> I<database table>] [B<--clientsdb> I<database table>] [B<--hostsdb> I<database table>] [B<--conffile> I<filename>]

=head1 REQUIREMENTS

See L<doc/README>.

=head1 DESCRIPTION

This script will extract and process statistical information from a
database table which is fed from F<feedlog.pl> for a given time period
and write its results to (an)other database table(s). Entries marked
with I<'disregard'> in the database will be ignored; currently, you
have to set this flag yourself, using your database management tools.
You can exclude erroneous entries that way (e.g. automatic reposts
(think of cancels flood and resurrectors); spam; ...).

The time period to act on defaults to last month; you can assign
another time period or a single month via the B<--month> option (see
below).

By default B<gatherstats> will process all types of information; you
can change that using the B<--stats> option and assigning the type of
information to process. Currently that doesn't matter yet as only
processing of the number of postings per group per month is
implemented anyway.

Possible information types include:

=over 3

=item B<groups> (postings per group per month)

B<gatherstats> will examine Newsgroups: headers. Crosspostings will be
counted for each single group they appear in. Groups not in I<TLH>
will be ignored.

B<gatherstats> will also add up the number of postings for each
hierarchy level, but only count each posting once. A posting to
de.alt.test will be counted for de.alt.test, de.alt.ALL and de.ALL,
respectively. A crossposting to de.alt.test and de.alt.admin, on the
other hand, will be counted for de.alt.test and de.alt.admin each, but
only once for de.alt.ALL and de.ALL.

Data is written to I<DBTableGrps> (see L<doc/INSTALL>); you can
override that default through the B<--groupsdb> option.

=back

=head2 Configuration

B<gatherstats> will read its configuration from F<newsstats.conf>
which should be present in etc/ via Config::Auto or from a configuration file
submitted by the B<--conffile> option.

See L<doc/INSTALL> for an overview of possible configuration options.

You can override configuration options via the B<--hierarchy>,
B<--rawdb>, B<--groupsdb>, B<--clientsdb> and B<--hostsdb> options,
respectively.

=head1 OPTIONS

=over 3

=item B<-V>, B<--version>

Print out version and copyright information and exit.

=item B<-h>, B<--help>

Print this man page and exit.

=item B<-d>, B<--debug>

Output debugging information to STDOUT while processing (number of
postings per group).

=item B<-t>, B<--test>

Do not write results to database. You should use B<--debug> in
conjunction with B<--test> ... everything else seems a bit pointless.

=item B<-m>, B<--month> I<YYYY-MM[:YYYY-MM]>

Set processing period to a single month in YYYY-MM format or to a time
period between two month in YYYY-MM:YYYY-MM format (two month, separated
by a colon).

=item B<-s>, B<--stats> I<type>

Set processing type to one of I<all> and I<groups>. Defaults to all
(and is currently rather pointless as only I<groups> has been
implemented).

=item B<-c>, B<--checkgroups> I<filename template>

Check each group against a list of valid newsgroups read from a file,
one group on each line and ignoring everything after the first
whitespace (so you can use a file in checkgroups format or (part of)
your INN active file).

The filename is taken from I<filename template>, amended by each
B<--month> B<gatherstats> is processing in the form of I<template-YYYY-MM>,
so that

    gatherstats -m 2010-01:2010-12 -c checkgroups

will check against F<checkgroups-2010-01> for January 2010, against
F<checkgroups-2010-02> for February 2010 and so on.

Newsgroups not found in the checkgroups file will be dropped (and
logged to STDERR), and newsgroups found there but having no postings
will be added with a count of 0 (and logged to STDERR).

=item B<--hierarchy> I<TLH> (newsgroup hierarchy)

Override I<TLH> from F<newsstats.conf>.

=item B<--rawdb> I<table> (raw data table)

Override I<DBTableRaw> from F<newsstats.conf>.

=item B<--groupsdb> I<table> (postings per group table)

Override I<DBTableGrps> from F<newsstats.conf>.

=item B<--clientsdb> I<table> (client data table)

Override I<DBTableClnts> from F<newsstats.conf>.

=item B<--hostsdb> I<table> (host data table)

Override I<DBTableHosts> from F<newsstats.conf>.

=item B<--conffile> I<filename>

Load configuration from I<filename> instead of F<newsstats.conf>.

=back

=head1 INSTALLATION

See L<doc/INSTALL>.

=head1 EXAMPLES

Process all types of information for lasth month:

    gatherstats

Do a dry run, showing results of processing:

    gatherstats --debug --test

Process all types of information for January of 2010:

    gatherstats --month 2010-01

Process only number of postings for the year of 2010,
checking against checkgroups-*:

    gatherstats -m 2010-01:2010-12 -s groups -c checkgroups

=head1 FILES

=over 4

=item F<bin/gatherstats.pl>

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
