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

use NewsStats qw(:DEFAULT :TimePeriods ListNewsgroups ReadGroupList);

use DBI;

################################# Definitions ##################################

# define types of information that can be gathered
# all / groups (/ clients / hosts)
my %LegalTypes;
@LegalTypes{('all','groups')} = ();

################################# Main program #################################

### read commandline options
my %Options = &ReadOptions('dom:p:t:l:n:r:g:c:s:');

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

### get type of information to gather, defaulting to 'all'
$Options{'t'} = 'all' if !$Options{'t'};
die "$MySelf: E: Unknown type '-t $Options{'t'}'!\n" if !exists($LegalTypes{$Options{'t'}});

### get time period (-m or -p)
my ($StartMonth,$EndMonth) = &GetTimePeriod($Options{'m'},$Options{'p'});

### read newsgroups list from -l
my %ValidGroups = %{&ReadGroupList($Options{'l'})} if $Options{'l'};

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
      my %Newsgroups = ListNewsgroups($_,$Conf{'TLH'},$Options{'l'} ? \%ValidGroups : '');
      # count each newsgroup and hierarchy once
      foreach (sort keys %Newsgroups) {
        $Postings{$_}++;
      };
    };

    # add valid but empty groups if -l is set
    if (%ValidGroups) {
      foreach (sort keys %ValidGroups) {
        if (!defined($Postings{$_})) {
          $Postings{$_} = 0 ;
          warn (sprintf("ADDED: %s as empty group\n",$_));
        }
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

B<gatherstats> [B<-Vhdo>] [B<-m> I<YYYY-MM>] [B<-p> I<YYYY-MM:YYYY-MM>] [B<-t> I<type>] [B<-l> I<filename>] [B<-n> I<TLH>] [B<-r> I<database table>] [B<-g> I<database table>] [B<-c> I<database table>] [B<-s> I<database table>]

=head1 REQUIREMENTS

See doc/README: Perl 5.8.x itself and the following modules from CPAN:

=over 2

=item -

Config::Auto

=item -

DBI

=back

=head1 DESCRIPTION

This script will extract and process statistical information from a
database table which is fed from F<feedlog.pl> for a given time period
and write its results to (an)other database table(s). Entries marked
with I<'disregard'> in the database will be ignored; currently, you have
to set this flag yourself, using your database management tools. You
can exclude erroneous entries that way (e.g. automatic reposts (think
of cancels flood and resurrectors); spam; ...).

The time period to act on defaults to last month; you can assign
another month via the B<-m> switch or a time period via the B<-p>
switch; the latter takes preference.

By default B<gatherstats> will process all types of information; you
can change that using the B<-t> switch and assigning the type of
information to process. Currently only processing of the number of
postings per group per month is implemented anyway, so that doesn't
matter yet.

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

Data is written to I<DBTableGrps> (see doc/INSTALL).

=back

=head2 Configuration

F<gatherstats.pl> will read its configuration from F<newsstats.conf>
which should be present in the same directory via Config::Auto.

See doc/INSTALL for an overview of possible configuration options.

You can override configuration options via the B<-n>, B<-r>, B<-g>,
B<-c> and B<-s> switches, respectively.

=head1 OPTIONS

=over 3

=item B<-V> (version)

Print out version and copyright information on B<yapfaq> and exit.

=item B<-h> (help)

Print this man page and exit.

=item B<-d> (debug)

Output debugging information to STDOUT while processing (number of
postings per group).

=item B<-o> (output only)

Do not write results to database. You should use B<-d> in conjunction
with B<-o> ... everything else seems a bit pointless.

=item B<-m> I<YYYY-MM> (month)

Set processing period to a month in YYYY-MM format. Ignored if B<-p>
is set.

=item B<-p> I<YYYY-MM:YYYY-MM> (period)

Set processing period to a time period between two month, each in
YYYY-MM format, separated by a colon. Overrides B<-m>.

=item B<-t> I<type> (type)

Set processing type to one of I<all> and I<groups>. Defaults to all
(and is currently rather pointless as only I<groups> has been
implemented).

=item B<-l> I<filename> (check against list)

Check each group against a list of valid newsgroups read from
I<filename>, one group on each line and ignoring everything after the
first whitespace (so you can use a file in checkgroups format or (part
of) your INN active file).

Newsgroups not found in I<filename> will be dropped (and logged to
STDERR), and newsgroups found in I<filename> but having no postings
will be added with a count of 0 (and logged to STDERR).

=item B<-n> I<TLH> (newsgroup hierarchy)

Override I<TLH> from F<newsstats.conf>.

=item B<-r> I<table> (raw data table)

Override I<DBTableRaw> from F<newsstats.conf>.

=item B<-g> I<table> (postings per group table)

Override I<DBTableGrps> from F<newsstats.conf>.

=item B<-c> I<table> (client data table)

Override I<DBTableClnts> from F<newsstats.conf>.

=item B<-s> I<table> (server/host data table)

Override I<DBTableHosts> from F<newsstats.conf>.

=back

=head1 INSTALLATION

See doc/INSTALL.

=head1 EXAMPLES

Process all types of information for lasth month:

    gatherstats

Do a dry run, showing results of processing:

    gatherstats -do

Process all types of information for January of 2010:

    gatherstats -m 2010-01

Process only number of postings for the year of 2010,
checking against checkgroups-2010.txt:

    gatherstats -p 2010-01:2010-12 -t groups -l checkgroups-2010.txt

=head1 FILES

=over 4

=item F<gatherstats.pl>

The script itself.

=item F<NewsStats.pm>

Library functions for the NewsStats package.

=item F<newsstats.conf>

Runtime configuration file for B<yapfaq>.

=back

=head1 BUGS

Please report any bugs or feature requests to the author or use the
bug tracker at L<http://bugs.th-h.de/>!

=head1 SEE ALSO

=over 2

=item -

doc/README

=item -

doc/INSTALL

=back

This script is part of the B<NewsStats> package.

=head1 AUTHOR

Thomas Hochstein <thh@inter.net>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2010 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
