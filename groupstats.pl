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

################################# Main program #################################

### read commandline options
my %Options = &ReadOptions('m:p:n:o:t:l:b:iscqdg:');

### read configuration
my %Conf = %{ReadConfig('newsstats.conf')};

### override configuration via commandline options
my %ConfOverride;
$ConfOverride{'DBTableGrps'}  = $Options{'g'} if $Options{'g'};
&OverrideConfig(\%Conf,\%ConfOverride);

### check for incompatible command line options
# you can't mix '-t', '-b' and '-l'
# -b/-l take preference over -t, and -b takes preference over -l
if ($Options{'b'} or $Options{'l'}) {
  if ($Options{'t'}) {
    # drop -t
    warn ("$MySelf: W: You cannot combine thresholds (-t) and top lists (-b) or levels (-l). Threshold '-t $Options{'t'}' was ignored.\n");
    undef($Options{'t'});
  };
  if ($Options{'b'} and $Options{'l'}) {
    # drop -l
    warn ("$MySelf: W: You cannot combine top lists (-b) and levels (-l). Level '-l $Options{'l'}' was ignored.\n");
    undef($Options{'l'});
  };
  # -q/-d don't work with -b or -l
  warn ("$MySelf: W: Sorting by number of postings (-q) ignored due to top list mode (-b) / levels (-l).\n") if $Options{'q'};
  warn ("$MySelf: W: Reverse sorting (-d) ignored due to top list mode (-b) / levels (-l).\n") if $Options{'d'};
};

### check output type
# default output type to 'dump'
$Options{'o'} = 'dump' if !$Options{'o'};
# fail if more than one newsgroup is combined with 'dumpgroup' type
die ("$MySelf: E: You cannot combine newsgroup lists (-n) with more than one group with '-o dumpgroup'!\n") if ($Options{'o'} eq 'dumpgroup' and defined($Options{'n'}) and $Options{'n'} =~ /:|\*/);
# accept 'dumpgroup' only with -n
if ($Options{'o'} eq 'dumpgroup' and !defined($Options{'n'})) {
  $Options{'o'} = 'dump';
  warn ("$MySelf: W: You must submit exactly one newsgroup ('-n news.group') for '-o dumpgroup'. Output type was set to 'dump'.\n");
};
# set output type to 'pretty' for -l
if ($Options{'l'}) {
  $Options{'o'} = 'pretty';
  warn ("$MySelf: W: Output type forced to '-o pretty' due to usage of '-l'.\n");
};

### get time period
my ($StartMonth,$EndMonth) = &GetTimePeriod($Options{'m'},$Options{'p'});
# reset to one month for 'dump' output type
if ($Options{'o'} eq 'dump' and $Options{'p'}) {
  warn ("$MySelf: W: You cannot combine time periods (-p) with '-o dump', changing output type to '-o pretty'.\n");
  $Options{'o'} = 'pretty';
};

### init database
my $DBHandle = InitDB(\%Conf,1);

### create report
# get list of newsgroups (-n)
my ($QueryPart,@GroupList);
my $Newsgroups = $Options{'n'};
if ($Newsgroups) {
  # explode list of newsgroups for WHERE clause
  ($QueryPart,@GroupList) = &SQLGroupList($Newsgroups);
} else {
  # set to dummy value (always true)
  $QueryPart = 1;
};

# manage thresholds
if (defined($Options{'t'})) {
  if ($Options{'i'}) {
    # -i: list groups below threshold
    $QueryPart .= ' AND postings < ?';
  } else {
    # default: list groups above threshold
    $QueryPart .= ' AND postings > ?';
  };
  # push threshold to GroupList to match number of binding vars for DBQuery->execute
  push @GroupList,$Options{'t'};
}

# construct WHERE clause
# $QueryPart is "list of newsgroup" (or 1),
# &SQLHierarchies() takes care of the exclusion of hierarchy levels (.ALL)
# according to setting of -s
my $WhereClause = sprintf('month BETWEEN ? AND ? AND %s %s',$QueryPart,&SQLHierarchies($Options{'s'}));

# get lenght of longest newsgroup delivered by query for formatting purposes
# FIXME
my $MaxLength = &GetMaxLenght($DBHandle,$Conf{'DBTableGrps'},'newsgroup',$WhereClause,$StartMonth,$EndMonth,@GroupList);

my ($OrderClause,$DBQuery);
# -b (best of / top list) defined?
if (!defined($Options{'b'}) and !defined($Options{'l'})) {
  # default: neither -b nor -l
  # set ordering (ORDER BY) to "newsgroups" or "postings", "ASC" or "DESC"
  # according to -q and -d
  $OrderClause = 'newsgroup';
  $OrderClause = 'postings' if $Options{'q'};
  $OrderClause .= ' DESC' if $Options{'d'};
  # prepare query: get number of postings per group from groups table for given months and newsgroups
  $DBQuery = $DBHandle->prepare(sprintf("SELECT month,newsgroup,postings FROM %s.%s WHERE %s ORDER BY month,%s",$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$WhereClause,$OrderClause));
} elsif ($Options{'b'}) {
  # -b is set (then -l can't be!)
  # set sorting order (-i)
  if ($Options{'i'}) {
    $OrderClause = 'postings';
  } else {
    $OrderClause = 'postings DESC';
  };
  # set -b to 10 if < 1 (Top 10)
  $Options{'b'} = 10 if $Options{'b'} !~ /^\d*$/ or $Options{'b'} < 1;
  # push LIMIT to GroupList to match number of binding vars for DBQuery->execute
  push @GroupList,$Options{'b'};
  # prepare query: get sum of postings per group from groups table for given months and newsgroups with LIMIT
  $DBQuery = $DBHandle->prepare(sprintf("SELECT newsgroup,SUM(postings) AS postings FROM %s.%s WHERE %s GROUP BY newsgroup ORDER BY %s,newsgroup LIMIT ?",$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$WhereClause,$OrderClause));
} else {
  # -l must be set now, as all other cases have been taken care of
  # set sorting order (-i)
  if ($Options{'i'}) {
    $OrderClause = '<';
  } else {
    $OrderClause = '>';
  };
  # push level and $StartMonth,$EndMonth - again - to GroupList to match number of binding vars for DBQuery->execute
  # FIXME -- together with the query (see below)
  push @GroupList,$Options{'l'};
  push @GroupList,$StartMonth,$EndMonth;
  # prepare query: get number of postings per group from groups table for given months and 
  # FIXME -- this query is ... in dire need of impromevent
  $DBQuery = $DBHandle->prepare(sprintf("SELECT month,newsgroup,postings FROM %s.%s WHERE newsgroup IN (SELECT newsgroup FROM %s.%s WHERE %s GROUP BY newsgroup HAVING MAX(postings) %s ?) AND %s ORDER BY newsgroup,month",$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$WhereClause,$OrderClause,$WhereClause));
};

# execute query
$DBQuery->execute($StartMonth,$EndMonth,@GroupList)
  or die sprintf("$MySelf: E: Can't get groups data for %s to %s from %s.%s: %s\n",$StartMonth,$EndMonth,$Conf{'DBDatabase'},$Conf{'DBTableGrps'},$DBI::errstr);

# output results
# print caption (-c) with time period if -m or -p is set
# FIXME - month or period should handled differently
printf ("----- Report from %s to %s\n",$StartMonth,$EndMonth) if $Options{'c'} and ($Options{'m'} or $Options{'p'});
# print caption (-c) with newsgroup list if -n is set
printf ("----- Newsgroups: %s\n",join(',',split(/:/,$Newsgroups))) if $Options{'c'} and $Options{'n'};
# print caption (-c) with threshold if -t is set, taking -i in account
printf ("----- Threshold: %s %u\n",$Options{'i'} ? '<' : '>',$Options{'t'}) if $Options{'c'} and $Options{'t'};
if (!defined($Options{'b'})  and !defined($Options{'l'})) {
  # default: neither -b nor -l
  &OutputData($Options{'o'},$DBQuery,$MaxLength);
} elsif ($Options{'b'}) {
  # -b is set (then -l can't be!)
  # we have to read in the query results ourselves, as they do not have standard layout
  while (my ($Newsgroup,$Postings) = $DBQuery->fetchrow_array) {
    # we just assign "top x" or "bottom x" instead of a month for the caption
    # FIXME
    print &FormatOutput($Options{'o'}, ($Options{'i'} ? 'Bottom ' : 'Top ').$Options{'b'}, $Newsgroup, $Postings, $MaxLength);
  };
} else {
  # -l must be set now, as all other cases have been taken care of
  # we have to read in the query results ourselves, as they do not have standard layout
  while (my ($Month,$Newsgroup,$Postings) = $DBQuery->fetchrow_array) {
    # we just switch $Newsgroups and $Month for output generation
    # FIXME
    print &FormatOutput($Options{'o'}, $Newsgroup, $Month, $Postings, 7);
  };
};

### close handles
$DBHandle->disconnect;

__END__

################################ Documentation #################################

=head1 NAME

groupstats - create reports on newsgroup usage

=head1 SYNOPSIS

B<groupstats> [B<-Vhiscqd>] [B<-m> I<YYYY-MM>] [B<-p> I<YYYY-MM:YYYY-MM>] [B<-n> I<newsgroup(s)>] [B<-t> I<threshold>] [B<-l> I<level>] [B<-b> I<number>] [B<-o> I<output type>] [B<-g> I<database table>]

=head1 REQUIREMENTS

See doc/README: Perl 5.8.x itself and the following modules from CPAN:

=over 2

=item -

Config::Auto

=item -

DBI

=back

=head1 DESCRIPTION

This script create reports on newsgroup usage (number of postings per
group per month) taken from result tables created by
F<gatherstats.pl>.

The time period to act on defaults to last month; you can assign
another month via the B<-m> switch or a time period via the B<-p>
switch; the latter takes preference.

B<groupstats> will process all newsgroups by default; you can limit
that to only some newsgroups by supplying a list of those groups via
B<-n> (see below). You can include hierarchy levels in the output by
adding the B<-s> switch (see below).

Furthermore you can set a threshold via B<-t> so that only newsgroups
with more postings per month will be included in the report. You can
invert that by the B<-i> switch so only newsgroups with less than
I<threshold> postings per month will be included.

You can sort the output by number of postings per month instead of the
default (alphabetical list of newsgroups) by using B<-q>; you can
reverse the sorting order (from highest to lowest or in reversed
alphabetical order) by using B<-d>.

Furthermore, you can create a list of newsgroups that had consistently
more (or less) than x postings per month during the whole report
period by using B<-l> (together with B<i> as needed).

Last but not least you can create a "best of" list of the top x
newsgroups via B<-b> (or a "worst of" list by adding B<i>).

By default, B<groupstats> will dump a very simple alphabetical list of
newsgroups, one per line, followed by the number of postings in that
month. This output format of course cannot sensibly be combined with
time periods, so you can set the output format by using B<-o> (see
below). Captions can be added by setting the B<-c> switch.

=head2 Configuration

F<groupstats.pl> will read its configuration from F<newsstats.conf>
which should be present in the same directory via Config::Auto.

See doc/INSTALL for an overview of possible configuration options.

You can override configuration options via the B<-g> switch.

=head1 OPTIONS

=over 3

=item B<-V> (version)

Print out version and copyright information on B<yapfaq> and exit.

=item B<-h> (help)

Print this man page and exit.

=item B<-m> I<YYYY-MM> (month)

Set processing period to a month in YYYY-MM format. Ignored if B<-p>
is set.

=item B<-p> I<YYYY-MM:YYYY-MM> (period)

Set processing period to a time period between two month, each in
YYYY-MM format, separated by a colon. Overrides B<-m>.

=item B<-n> I<newsgroup(s)> (newsgroups)

Limit processing to a certain set of newsgroups. I<newsgroup(s)> can
be a single newsgroup name (de.alt.test), a newsgroup hierarchy
(de.alt.*) or a list of either of these, separated by colons, for
example

   de.test:de.alt.test:de.newusers.*

=item B<-t> I<threshold> (threshold)

Only include newsgroups with more than I<threshold> postings per
month. Can be inverted by the B<-i> switch so that only newsgroups
with less than I<threshold> postings will be included.

This setting will be ignored if B<-l> or B<-b> is set.

=item B<-l> I<level> (level)

Only include newsgroups with more than I<level> postings per
month, every month during the whole reporting period. Can be inverted
by the B<-i> switch so that only newsgroups with less than I<level>
postings every single month will be included. Output will be ordered
by newsgroup name, followed by month.

This setting will be ignored if B<-b> is set. Overrides B<-t> and
can't be used together with B<-q> or B<-d>.

=item B<-b> I<n> (best of)

Create a list of the I<n> newsgroups with the most postings over the
whole reporting period. Can be inverted by the B<-i> switch so that a
list of the I<n> newsgroups with the least postings over the whole
period is generated. Output will be ordered by sum of postings.

Overrides B<-t> and B<-l> and can't be used together with B<-q> or
B<-d>. Output format is set to I<pretty> (see below).

=item B<-i> (invert)

Used in conjunction with B<-t>, B<-l> or B<-b> to set a lower
threshold or level or generate a "bottom list" instead of a top list.

=item B<-s> (sum per hierarchy level)

Include "virtual" groups for every hierarchy level in output, for
example:

    de.alt.ALL 10
    de.alt.test 5
    de.alt.admin 7

See the B<gatherstats> man page for details.

=item B<-o> I<output type> (output format)

Set output format. Default is I<dump>, consisting of an alphabetical
list of newsgroups, each on a new line, followed by the number of
postings in that month. This default format can't be used with time
periods of more than one month.

I<list> format is like I<dump>, but will print the month in front of
the newsgroup name.

I<dumpgroup> format can only be use with a group list (see B<-n>) of
exactly one newsgroup and is like I<dump>, but will output months,
followed by the number of postings.

If you don't need easily parsable output, you'll mostly use I<pretty>
format, which will print a header for each new month and try to align
newsgroup names and posting counts. Usage of B<-b> will force this
format.

=item B<-c> (captions)

Add captions to output (reporting period, newsgroups list, threshold).

=item B<-q> (quantity of postings)

Sort by number of postings instead of by newsgroup names.

Cannot be used with B<-l> or B<-b>.

=item B<-d> (descending)

Change sort order to descending.

Cannot be used with B<-l> or B<-b>.

=item B<-g> I<table> (postings per group table)

Override I<DBTableGrps> from F<newsstats.conf>.

=back

=head1 INSTALLATION

See doc/INSTALL.

=head1 EXAMPLES

Show number of postings per group for lasth month in I<dump> format:

    groupstats

Show that report for January of 2010 and de.alt.* plus de.test,
including display of hierarchy levels:

    groupstats -m 2010-01 -n de.alt.*:de.test -s

Show that report for the year of 2010 in I<pretty> format:

    groupstats -p 2010-01:2010-12 -o pretty

Only show newsgroups with less than 30 postings last month, ordered
by number of postings, descending, in I<pretty> format:

    groupstats -iqdt 30 -o pretty

Show top 10 for the first half-year of of 2010 in I<pretty> format:

    groupstats -p 2010-01:2010-06 -b 10 -o pretty

Report all groups that had less than 30 postings every singele month
in the year of 2010 (I<pretty> format is forced)

    groupstats -p 2010-01:2010-12 -il 30

=head1 FILES

=over 4

=item F<groupstats.pl>

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

=item -

gatherstats -h

=back

This script is part of the B<NewsStats> package.

=head1 AUTHOR

Thomas Hochstein <thh@inter.net>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2010 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
