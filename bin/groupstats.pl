#! /usr/bin/perl
#
# groupstats.pl
#
# This script will get statistical data on newgroup usage
# from a database.
#
# It is part of the NewsStats package.
#
# Copyright (c) 2010-2013 Thomas Hochstein <thh@inter.net>
#
# It can be redistributed and/or modified under the same terms under
# which Perl itself is published.

BEGIN {
  our $VERSION = "0.01";
  use File::Basename;
  # we're in .../bin, so our module is in ../lib
  push(@INC, dirname($0).'/../lib');
}
use strict;
use warnings;

use NewsStats qw(:DEFAULT :TimePeriods :Output :SQLHelper ReadGroupList);

use DBI;
use Getopt::Long qw(GetOptions);
Getopt::Long::config ('bundling');

################################# Main program #################################

### read commandline options
my ($OptBoundType,$OptCaptions,$OptCheckgroupsFile,$OptComments,
    $OptFileTemplate,$OptFormat,$OptGroupBy,$OptGroupsDB,$LowBound,$OptMonth,
    $OptNewsgroups,$OptOrderBy,$OptReportType,$OptSums,$UppBound,$OptConfFile);
GetOptions ('b|boundary=s'   => \$OptBoundType,
            'c|captions!'    => \$OptCaptions,
            'checkgroups=s'  => \$OptCheckgroupsFile,
            'comments!'      => \$OptComments,
            'filetemplate=s' => \$OptFileTemplate,
            'f|format=s'     => \$OptFormat,
            'g|group-by=s'   => \$OptGroupBy,
            'groupsdb=s'     => \$OptGroupsDB,
            'l|lower=i'      => \$LowBound,
            'm|month=s'      => \$OptMonth,
            'n|newsgroups=s' => \$OptNewsgroups,
            'o|order-by=s'   => \$OptOrderBy,
            'r|report=s'     => \$OptReportType,
            's|sums!'        => \$OptSums,
            'u|upper=i'      => \$UppBound,
            'conffile=s'     => \$OptConfFile,
            'h|help'         => \&ShowPOD,
            'V|version'      => \&ShowVersion) or exit 1;
# parse parameters
# $OptComments defaults to TRUE
$OptComments = 1 if (!defined($OptComments));
# force --nocomments when --filetemplate is used
$OptComments = 0 if ($OptFileTemplate);
# parse $OptBoundType
if ($OptBoundType) {
  if ($OptBoundType =~ /level/i) {
    $OptBoundType = 'level';
  } elsif ($OptBoundType =~ /av(era)?ge?/i) {
    $OptBoundType = 'average';
  } elsif ($OptBoundType =~ /sums?/i) {
    $OptBoundType = 'sum';
  } else {
    $OptBoundType = 'default';
  }
}
# parse $OptReportType
if ($OptReportType) {
  if ($OptReportType =~ /av(era)?ge?/i) {
    $OptReportType = 'average';
  } elsif ($OptReportType =~ /sums?/i) {
    $OptReportType = 'sum';
  } else {
    $OptReportType  = 'default';
  }
}
# read list of newsgroups from --checkgroups
# into a hash reference
my $ValidGroups = &ReadGroupList($OptCheckgroupsFile) if $OptCheckgroupsFile;

### read configuration
my %Conf = %{ReadConfig($OptConfFile)};

### override configuration via commandline options
my %ConfOverride;
$ConfOverride{'DBTableGrps'} = $OptGroupsDB if $OptGroupsDB;
&OverrideConfig(\%Conf,\%ConfOverride);

### init database
my $DBHandle = InitDB(\%Conf,1);

### get time period and newsgroups, prepare SQL 'WHERE' clause
# get time period
# and set caption for output and expression for SQL 'WHERE' clause
my ($CaptionPeriod,$SQLWherePeriod) = &GetTimePeriod($OptMonth);
# bail out if --month is invalid
&Bleat(2,"--month option has an invalid format - ".
         "please use 'YYYY-MM', 'YYYY-MM:YYYY-MM' or 'ALL'!") if !$CaptionPeriod;
# get list of newsgroups and set expression for SQL 'WHERE' clause
# with placeholders as well as a list of newsgroup to bind to them
my ($SQLWhereNewsgroups,@SQLBindNewsgroups);
if ($OptNewsgroups) {
  ($SQLWhereNewsgroups,@SQLBindNewsgroups) = &SQLGroupList($OptNewsgroups);
  # bail out if --newsgroups is invalid
  &Bleat(2,"--newsgroups option has an invalid format!")
    if !$SQLWhereNewsgroups;
}

### build SQL WHERE clause (and HAVING clause, if needed)
my ($SQLWhereClause,$SQLHavingClause);
# $OptBoundType 'level'
if ($OptBoundType and $OptBoundType ne 'default') {
  $SQLWhereClause = SQLBuildClause('where',$SQLWherePeriod,
                                   $SQLWhereNewsgroups,&SQLHierarchies($OptSums));
  $SQLHavingClause = SQLBuildClause('having',&SQLSetBounds($OptBoundType,
                                                           $LowBound,$UppBound));
# $OptBoundType 'threshold' / 'default' or none
} else {
  $SQLWhereClause = SQLBuildClause('where',$SQLWherePeriod,
                                   $SQLWhereNewsgroups,&SQLHierarchies($OptSums),
                                   &SQLSetBounds('default',$LowBound,$UppBound));
}

### get sort order and build SQL 'ORDER BY' clause
# default to 'newsgroup' for $OptBoundType 'level' or 'average'
$OptGroupBy = 'newsgroup' if (!$OptGroupBy and
                              $OptBoundType and $OptBoundType ne 'default');
# force to 'month' for $OptReportType 'average' or 'sum'
$OptGroupBy = 'month' if ($OptReportType and $OptReportType ne 'default');
# parse $OptGroupBy to $GroupBy, create ORDER BY clause $SQLOrderClause
my ($GroupBy,$SQLOrderClause) = SQLSortOrder($OptGroupBy, $OptOrderBy);
# $GroupBy will contain 'month' or 'newsgroup' (parsed result of $OptGroupBy)
# set it to 'month' or 'key' for OutputData()
$GroupBy = ($GroupBy eq 'month') ? 'month' : 'key';

### get report type and build SQL 'SELECT' query
my $SQLSelect;
my $SQLGroupClause = '';
my $Precision = 0;       # number of digits right of decimal point for output
if ($OptReportType and $OptReportType ne 'default') {
  $SQLGroupClause = 'GROUP BY newsgroup';
  # change $SQLOrderClause: replace everything before 'postings'
  $SQLOrderClause =~ s/BY.+postings/BY postings/;
  if ($OptReportType eq 'average') {
    $SQLSelect = "'All months',newsgroup,AVG(postings)";
    $Precision = 2;
    # change $SQLOrderClause: replace 'postings' with 'AVG(postings)'
    $SQLOrderClause =~ s/postings/AVG(postings)/;
  } elsif ($OptReportType eq 'sum') {
    $SQLSelect = "'All months',newsgroup,SUM(postings)";
    # change $SQLOrderClause: replace 'postings' with 'SUM(postings)'
    $SQLOrderClause =~ s/postings/SUM(postings)/;
  }
 } else {
  $SQLSelect = 'month,newsgroup,postings';
};

### get length of longest newsgroup name delivered by query
### for formatting purposes
my $Field = ($GroupBy eq 'month') ? 'newsgroup' : 'month';
my ($MaxLength,$MaxValLength) = &GetMaxLength($DBHandle,$Conf{'DBTableGrps'},
                                              $Field,'postings',$SQLWhereClause,
                                              $SQLHavingClause,
                                              @SQLBindNewsgroups);

### build and execute SQL query
my ($DBQuery);
# special query preparation for $OptBoundType 'level', 'average' or 'sums'
if ($OptBoundType and $OptBoundType ne 'default') {
  # prepare and execute first query:
  # get list of newsgroups meeting level conditions
  $DBQuery = $DBHandle->prepare(sprintf('SELECT newsgroup FROM %s.%s %s '.
                                        'GROUP BY newsgroup %s',
                                        $Conf{'DBDatabase'},$Conf{'DBTableGrps'},
                                        $SQLWhereClause,$SQLHavingClause));
  $DBQuery->execute(@SQLBindNewsgroups)
    or &Bleat(2,sprintf("Can't get groups data for %s from %s.%s: %s\n",
                        $CaptionPeriod,$Conf{'DBDatabase'},$Conf{'DBTableGrps'},
                        $DBI::errstr));
  # add newsgroups to a comma-seperated list ready for IN(...) query
  my $GroupList;
  while (my ($Newsgroup) = $DBQuery->fetchrow_array) {
    $GroupList .= ',' if $GroupList;
    $GroupList .= "'$Newsgroup'";
  };
  # enhance $WhereClause
  if ($GroupList) {
    $SQLWhereClause = SQLBuildClause('where',$SQLWhereClause,
                                     sprintf('newsgroup IN (%s)',$GroupList));
  } else {
    # condition cannot be satisfied;
    # force query to fail by adding '0=1'
    $SQLWhereClause = SQLBuildClause('where',$SQLWhereClause,'0=1');
  }
}

# prepare query
$DBQuery = $DBHandle->prepare(sprintf('SELECT %s FROM %s.%s %s %s %s',
                                      $SQLSelect,
                                      $Conf{'DBDatabase'},$Conf{'DBTableGrps'},
                                      $SQLWhereClause,$SQLGroupClause,
                                      $SQLOrderClause));

# execute query
$DBQuery->execute(@SQLBindNewsgroups)
  or &Bleat(2,sprintf("Can't get groups data for %s from %s.%s: %s\n",
                      $CaptionPeriod,$Conf{'DBDatabase'},$Conf{'DBTableGrps'},
                      $DBI::errstr));

### output results
# set default to 'pretty'
$OptFormat = 'pretty' if !$OptFormat;
# print captions if --caption is set
if ($OptCaptions && $OptComments) {
  # print time period with report type
  my $CaptionReportType= '(number of postings for each month)';
  if ($OptReportType and $OptReportType ne 'default') {
    $CaptionReportType= '(average number of postings for each month)'
      if $OptReportType eq 'average';
    $CaptionReportType= '(number of all postings for that time period)'
      if $OptReportType eq 'sum';
  }
  printf("# ----- Report for %s %s\n",$CaptionPeriod,$CaptionReportType);
  # print newsgroup list if --newsgroups is set
  printf("# ----- Newsgroups: %s\n",join(',',split(/:/,$OptNewsgroups)))
    if $OptNewsgroups;
  # print boundaries, if set
  my $CaptionBoundary= '(counting only month fulfilling this condition)';
  if ($OptBoundType and $OptBoundType ne 'default') {
    $CaptionBoundary= '(every single month)'  if $OptBoundType eq 'level';
    $CaptionBoundary= '(on average)'          if $OptBoundType eq 'average';
    $CaptionBoundary= '(all month summed up)' if $OptBoundType eq 'sum';
  }
  printf("# ----- Threshold: %s %s x %s %s %s\n",
         $LowBound ? $LowBound : '',$LowBound ? '=>' : '',
         $UppBound ? '<=' : '',$UppBound ? $UppBound : '',$CaptionBoundary)
    if ($LowBound or $UppBound);
  # print primary and secondary sort order
  printf("# ----- Grouped by %s (%s), sorted %s%s\n",
         ($GroupBy eq 'month') ? 'Months' : 'Newsgroups',
         ($OptGroupBy and $OptGroupBy =~ /-?desc$/i) ? 'descending' : 'ascending',
         ($OptOrderBy and $OptOrderBy =~ /posting/i) ? 'by number of postings ' : '',
         ($OptOrderBy and $OptOrderBy =~ /-?desc$/i) ? 'descending' : 'ascending');
}

# output data
&OutputData($OptFormat,$OptComments,$GroupBy,$Precision,
            $OptCheckgroupsFile ? $ValidGroups : '',
            $OptFileTemplate,$DBQuery,$MaxLength,$MaxValLength);

### close handles
$DBHandle->disconnect;

__END__

################################ Documentation #################################

=head1 NAME

groupstats - create reports on newsgroup usage

=head1 SYNOPSIS

B<groupstats> [B<-Vhcs> B<--comments>] [B<-m> I<YYYY-MM>[:I<YYYY-MM>] | I<all>] [B<-n> I<newsgroup(s)>] [B<--checkgroups> I<checkgroups file>] [B<-r> I<report type>] [B<-l> I<lower boundary>] [B<-u> I<upper boundary>] [B<-b> I<boundary type>] [B<-g> I<group by>] [B<-o> I<order by>] [B<-f> I<output format>] [B<--filetemplate> I<filename template>] [B<--groupsdb> I<database table>] [--conffile I<filename>]

=head1 REQUIREMENTS

See L<doc/README>.

=head1 DESCRIPTION

This script create reports on newsgroup usage (number of postings per
group per month) taken from result tables created by
B<gatherstats.pl>.

=head2 Features and options

=head3 Time period and newsgroups

The time period to act on defaults to last month; you can assign another
time period or a single month (or drop all time constraints) via the
B<--month> option (see below).

B<groupstats> will process all newsgroups by default; you can limit
processing to only some newsgroups by supplying a list of those groups via
B<--newsgroups> option (see below). You can include hierarchy levels in
the output by adding the B<--sums> switch (see below). Optionally
newsgroups not present in a checkgroups file can be excluded from output,
sse B<--checkgroups> below.

=head3 Report type

You can choose between different B<--report> types: postings per month,
average postings per month or all postings summed up; for details, see
below.

=head3 Upper and lower boundaries

Furthermore you can set an upper and/or lower boundary to exclude some
results from output via the B<--lower> and B<--upper> options,
respectively. By default, all newsgroups with more and/or less postings
per month will be excluded from the result set (i.e. not shown and not
considered for average and sum reports). You can change the meaning of
those boundaries with the B<--boundary> option. For details, please see
below.

=head3 Sorting and formatting the output

By default, all results are grouped by month; you can group results by
newsgroup instead via the B<--groupy-by> option. Within those groups, the
list of newsgroups (or months) is sorted alphabetically (or
chronologically, respectively) ascending. You can change that order (and
sort by number of postings) with the B<--order-by> option. For details and
exceptions, please see below.

The results will be formatted as a kind of table; you can change the
output format to a simple list or just a list of newsgroups and number of
postings with the B<--format> option. Captions will be added by means of
the B<--caption> option; all comments (and captions) can be supressed by
using B<--nocomments>.

Last but not least you can redirect all output to a number of files, e.g.
one for each month, by submitting the B<--filetemplate> option, see below.
Captions and comments are automatically disabled in this case.

=head2 Configuration

B<groupstats> will read its configuration from F<newsstats.conf>
which should be present in the same directory via Config::Auto.

See doc/INSTALL for an overview of possible configuration options.

You can override some configuration options via the B<--groupsdb> option.

=head1 OPTIONS

=over 3

=item B<-V>, B<--version>

Print out version and copyright information and exit.

=item B<-h>, B<--help>

Print this man page and exit.

=item B<-m>, B<--month> I<YYYY-MM[:YYYY-MM]|all>

Set processing period to a single month in YYYY-MM format or to a time
period between two month in YYYY-MM:YYYY-MM format (two month, separated
by a colon). By using the keyword I<all> instead, you can set no
processing period to process the whole database.

=item B<-n>, B<--newsgroups> I<newsgroup(s)>

Limit processing to a certain set of newsgroups. I<newsgroup(s)> can
be a single newsgroup name (de.alt.test), a newsgroup hierarchy
(de.alt.*) or a list of either of these, separated by colons, for
example

   de.test:de.alt.test:de.newusers.*

=item B<-s>, B<--sums|--nosums> (sum per hierarchy level)

Include "virtual" groups for every hierarchy level in output, for
example:

    de.alt.ALL 10
    de.alt.test 5
    de.alt.admin 7

See the B<gatherstats> man page for details.

=item B<--checkgroups> I<filename>

Restrict output to those newgroups present in a file in checkgroups format
(one newgroup name per line; everything after the first whitespace on each
line is ignored). All other newsgroups will be removed from output.

Contrary to B<gatherstats>, I<filename> is not a template, but refers to
a single file in checkgroups format.

=item B<-r>, B<--report> I<default|average|sums>

Choose the report type: I<default>, I<average> or I<sums>

By default, B<groupstats> will report the number of postings for each
newsgroup in each month. But it can also report the average number of
postings per group for all months or the total sum of postings per group
for all months.

For report types I<average> and I<sums>, the B<group-by> option has no
meaning and will be silently ignored (see below).

=item B<-l>, B<--lower> I<lower boundary>

Set the lower boundary. See B<--boundary> below.

=item B<-l>, B<--upper> I<upper boundary>

Set the upper boundary. See B<--boundary> below.

=item B<-b>, B<--boundary> I<boundary type>

Set the boundary type to one of I<default>, I<level>, I<average> or
I<sums>.

By default, all newsgroups with more postings per month than the upper
boundary and/or less postings per month than the lower boundary will be
excluded from further processing. For the default report that means each
month only newsgroups with a number of postings between the boundaries
will be displayed. For the other report types, newsgroups with a number of
postings exceeding the boundaries in all (!) months will not be
considered.

For example, lets take a list of newsgroups like this:

    ----- 2012-01:
    de.comp.datenbanken.misc               6
    de.comp.datenbanken.ms-access         84
    de.comp.datenbanken.mysql             88
    ----- 2012-02:
    de.comp.datenbanken.misc               8
    de.comp.datenbanken.ms-access        126
    de.comp.datenbanken.mysql             21
    ----- 2012-03:
    de.comp.datenbanken.misc              24
    de.comp.datenbanken.ms-access         83
    de.comp.datenbanken.mysql             36

With C<groupstats --month 2012-01:2012-03 --lower 25 --report sums>,
you'll get the following result:

    ----- All months:
    de.comp.datenbanken.ms-access        293
    de.comp.datenbanken.mysql            124

de.comp.datenbanken.misc has not been considered even though it has 38
postings in total, because it has less than 25 postings in every single
month. If you want to list all newsgroups with more than 25 postings
I<in total>, you'll have to set the boundary type to I<sum>, see below.

A boundary type of I<level> will show only those newsgroups - at all -
that satisfy the boundaries in each and every single month. With the above
list of newsgroups and
C<groupstats --month 2012-01:2012-03 --lower 25 --boundary level --report sums>,
you'll get this result:

    ----- All months:
    de.comp.datenbanken.ms-access        293

de.comp.datenbanken.mysql has not been considered because it had less than
25 postings in 2012-02 (only).

You can use that to get a list of newsgroups that have more (or less) then
x postings in every month during the whole reporting period.

A boundary type of I<average> will show only those newsgroups - at all -that
satisfy the boundaries on average. With the above list of newsgroups and
C<groupstats --month 2012-01:2012-03 --lower 25 --boundary avg --report sums>,
you'll get this result:

   ----- All months:
   de.comp.datenbanken.ms-access        293
   de.comp.datenbanken.mysql            145

The average number of postings in the three groups is:

    de.comp.datenbanken.misc           12.67
    de.comp.datenbanken.ms-access      97.67
    de.comp.datenbanken.mysql          48.33

Last but not least, a boundary type of I<sums> will show only those
newsgroups - at all - that satisfy the boundaries with the total sum of
all postings during the reporting period. With the above list of
newsgroups and
C<groupstats --month 2012-01:2012-03 --lower 25 --boundary sum --report sums>,
you'll finally get this result:

    ----- All months:
    de.comp.datenbanken.misc              38
    de.comp.datenbanken.ms-access        293
    de.comp.datenbanken.mysql            145


=item B<-g>, B<--group-by> I<month[-desc]|newsgroups[-desc]>

By default, all results are grouped by month, sorted chronologically in
ascending order, like this:

    ----- 2012-01:
    de.comp.datenbanken.ms-access         84
    de.comp.datenbanken.mysql             88
    ----- 2012-02:
    de.comp.datenbanken.ms-access        126
    de.comp.datenbanken.mysql             21

The results can be grouped by newsgroups instead via
B<--group-by> I<newsgroup>:

    ----- de.comp.datenbanken.ms-access:
    2012-01         84
    2012-02        126
    ----- de.comp.datenbanken.mysql:
    2012-01         88
    2012-02         21

By appending I<-desc> to the group-by option parameter, you can reverse
the sort order - e.g. B<--group-by> I<month-desc> will give:

    ----- 2012-02:
    de.comp.datenbanken.ms-access        126
    de.comp.datenbanken.mysql             21
    ----- 2012-01:
    de.comp.datenbanken.ms-access         84
    de.comp.datenbanken.mysql             88

Average and sums reports (see above) will always be grouped by months;
this option will therefore be ignored.

=item B<-o>, B<--order-by> I<default[-desc]|postings[-desc]>

Within each group (a single month or single newsgroup, see above), the
report will be sorted by newsgroup names in ascending alphabetical order
by default. You can change the sort order to descending or sort by number
of postings instead.

=item B<-f>, B<--format> I<pretty|list|dump>

Select the output format, I<pretty> being the default:

    ----- 2012-01:
    de.comp.datenbanken.ms-access         84
    de.comp.datenbanken.mysql             88
    ----- 2012-02:
    de.comp.datenbanken.ms-access        126
    de.comp.datenbanken.mysql             21

I<list> format looks like this:

    2012-01 de.comp.datenbanken.ms-access 84
    2012-01 de.comp.datenbanken.mysql 88
    2012-02 de.comp.datenbanken.ms-access 126
    2012-02 de.comp.datenbanken.mysql 21

And I<dump> format looks like this:

    # 2012-01:
    de.comp.datenbanken.ms-access 84
    de.comp.datenbanken.mysql 88
    # 2012-02:
    de.comp.datenbanken.ms-access 126
    de.comp.datenbanken.mysql 21

You can remove the comments by using B<--nocomments>, see below.

=item B<-c>, B<--captions|--nocaptions>

Add captions to output, like this:

    ----- Report for 2012-01 to 2012-02 (number of postings for each month)
    ----- Newsgroups: de.comp.datenbanken.*
    ----- Threshold: 10 => x <= 20 (on average)
    ----- Grouped by Newsgroups (ascending), sorted by number of postings descending

False by default.

=item B<--comments|--nocomments>

Add comments (group headers) to I<dump> and I<pretty> output. True by default.

Use I<--nocomments> to suppress anything except newsgroup names/months and
numbers of postings. This is enforced when using B<--filetemplate>, see below.

=item B<--filetemplate> I<filename template>

Save output to file(s) instead of dumping it to STDOUT. B<groupstats> will
create one file for each month (or each newsgroup, accordant to the
setting of B<--group-by>, see above), with filenames composed by adding
year and month (or newsgroup names) to the I<filename template>, for
example with B<--filetemplate> I<stats>:

    stats-2012-01
    stats-2012-02
    ... and so on

B<--nocomments> is enforced, see above.

=item B<--groupsdb> I<database table>

Override I<DBTableGrps> from F<newsstats.conf>.

=item B<--conffile> I<filename>

Load configuration from I<filename> instead of F<newsstats.conf>.

=back

=head1 INSTALLATION

See L<doc/INSTALL>.

=head1 EXAMPLES

Show number of postings per group for lasth month in I<pretty> format:

    groupstats

Show that report for January of 2010 and de.alt.* plus de.test,
including display of hierarchy levels:

    groupstats --month 2010-01 --newsgroups de.alt.*:de.test --sums

Only show newsgroups with 30 postings or less last month, ordered
by number of postings, descending, in I<pretty> format:

    groupstats --upper 30 --order-by postings-desc

Show the total of all postings for the year of 2010 for all groups that
had 30 postings or less in every single month in that year, ordered by
number of postings in descending order:

    groupstats -m 2010-01:2010-12 -u 30 -b level -r sums -o postings-desc

The same for the average number of postings in the year of 2010:

    groupstats -m 2010-01:2010-12 -u 30 -b level -r avg -o postings-desc

List number of postings per group for eacht month of 2010 and redirect
output to one file for each month, namend stats-2010-01 and so on, in
machine-readable form (without formatting):

    groupstats -m 2010-01:2010-12 -f dump --filetemplate stats


=head1 FILES

=over 4

=item F<bin/groupstats.pl>

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

l>doc/INSTALL>

=item -

gatherstats -h

=back

This script is part of the B<NewsStats> package.

=head1 AUTHOR

Thomas Hochstein <thh@inter.net>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2010-2012 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
