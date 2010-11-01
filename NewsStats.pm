# NewsStats.pm
#
# Library functions for the NewsStats package.
#
# Copyright (c) 2010 Thomas Hochstein <thh@inter.net>
#
# This module can be redistributed and/or modified under the same terms under 
# which Perl itself is published.

package NewsStats;

use strict;
use warnings;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
  $MySelf
  $MyVersion
  $PackageVersion
  ReadOptions
  ReadConfig
  OverrideConfig
  InitDB
);
@EXPORT_OK = qw(
  GetTimePeriod
  LastMonth
  CheckMonth
  SplitPeriod
  ListMonth
  ListNewsgroups
  OutputData
  FormatOutput
  SQLHierarchies
  SQLGroupList
  GetMaxLenght
);
%EXPORT_TAGS = ( TimePeriods => [qw(GetTimePeriod LastMonth CheckMonth SplitPeriod ListMonth)],
                 Output      => [qw(OutputData FormatOutput)],
                 SQLHelper   => [qw(SQLHierarchies SQLGroupList GetMaxLenght)]);
$VERSION = '0.01';
our $PackageVersion = '0.01';

use Data::Dumper;
use File::Basename;
use Getopt::Std;

use Config::Auto;
use DBI;

#####-------------------------------- Vars --------------------------------#####

our $MySelf = fileparse($0, '.pl');
our $MyVersion = "$MySelf $::VERSION (NewsStats.pm $VERSION)";

#####------------------------------- Basics -------------------------------#####

################################################################################
sub ReadOptions {
################################################################################
### read commandline options and act on standard options -h and -V
### IN : $Params: list of legal commandline paramaters (without -h and -V)
### OUT: a hash containing the commandline options
  $Getopt::Std::STANDARD_HELP_VERSION = 1;

  my ($Params) = @_;
  my %Options;
  
  getopts('Vh'.$Params, \%Options);

  # -V: display version
  &ShowVersion if ($Options{'V'});

  # -h: feed myself to perldoc
  &ShowPOD if ($Options{'h'});

  return %Options;
};
################################################################################

################################################################################
sub ShowVersion {
################################################################################
### display version and exit
  print "NewsStats v$PackageVersion\n$MyVersion\nCopyright (c) 2010 Thomas Hochstein <thh\@inter.net>\n";
  print "This program is free software; you may redistribute it and/or modify it under the same terms as Perl itself.\n";
  exit(100);
};
################################################################################

################################################################################
sub ShowPOD {
################################################################################
### feed myself to perldoc and exit
  exec('perldoc', $0);
  exit(100);
};
################################################################################

################################################################################
sub ReadConfig {
################################################################################
### read config via Config::Auto
### IN : $ConfFile: config filename
### OUT: reference to a hash containing the configuration
  my ($ConfFile) = @_;
  return Config::Auto::parse($ConfFile, format => 'equal');
};
################################################################################

################################################################################
sub OverrideConfig  {
################################################################################
### override configuration values
### IN : $ConfigR  : reference to configuration hash
###      $OverrideR: reference to a hash containing overrides
  my ($ConfigR,$OverrideR) = @_;
  my %Override = %$OverrideR;
  # Config hash empty?
  warn "$MySelf W: Empty configuration hash passed to OverrideConfig().\n" if ( keys %$ConfigR < 1);
  # return if no overrides
  return if (keys %Override < 1 or keys %$ConfigR < 1);
  foreach my $Key (keys %Override) {
    $$ConfigR{$Key} = $Override{$Key};
  };
};
################################################################################

################################################################################
sub InitDB {
################################################################################
### initialise database connection
### IN : $ConfigR: reference to configuration hash
###      $Die    : if TRUE, die if connection fails
### OUT: DBHandle
  my ($ConfigR,$Die) = @_;
  my %Conf = %$ConfigR;
  my $DBHandle = DBI->connect(sprintf('DBI:%s:database=%s;host=%s',$Conf{'DBDriver'},$Conf{'DBDatabase'},$Conf{'DBHost'}), $Conf{'DBUser'}, $Conf{'DBPw'}, { PrintError => 0 });
  if (!$DBHandle) {
    die ("$MySelf: E: $DBI::errstr\n") if (defined($Die) and $Die);
    warn("$MySelf: W: $DBI::errstr\n");
  };
  return $DBHandle;
};
################################################################################

#####------------------------------ GetStats ------------------------------#####

################################################################################
sub ListNewsgroups {
################################################################################
### explode a (scalar) list of newsgroup names to a list of newsgroup and
### hierarchy names where every newsgroup and hierarchy appears only once:
### de.alt.test,de.alt.admin -> de.ALL, de.alt.ALL, de.alt.test, de.alt.admin
### IN : $Newsgroups: a list of newsgroups (content of Newsgroups: header)
### OUT: %Newsgroups: hash containing all newsgroup and hierarchy names as keys
  my ($Newsgroups) = @_;
  my %Newsgroups;
  chomp($Newsgroups);
  # remove whitespace from contents of Newsgroups:
  $Newsgroups =~ s/\s//;
  # call &HierarchyCount for each newsgroup in $Newsgroups:
  for (split /,/, $Newsgroups) {
    # add original newsgroup to %Newsgroups
    $Newsgroups{$_} = 1;
    # add all hierarchy elements to %Newsgroups, amended by '.ALL',
    # i.e. de.alt.ALL and de.ALL
    foreach (ParseHierarchies($_)) {
      $Newsgroups{$_.'.ALL'} = 1;
    }
  };
  return %Newsgroups;
};

################################################################################
sub ParseHierarchies {
################################################################################
### return a list of all hierarchy levels a newsgroup belongs to
### (for de.alt.test.moderated that would be de/de.alt/de.alt.test)
### IN : $Newsgroup  : a newsgroup name
### OUT: @Hierarchies: array containing all hierarchies the newsgroup belongs to
  my ($Newsgroup) = @_;
  my @Hierarchies;
  # strip trailing dots
  $Newsgroup =~ s/(.+)\.+$/$1/;
  # butcher newsgroup name by "." and add each hierarchy to @Hierarchies
  # i.e. de.alt.test: "de.alt" and "de"
  while ($Newsgroup =~ /\./) {
    $Newsgroup =~ s/^((?:\.?[^.]+)*)\.[^.]+$/$1/;
    push @Hierarchies, $Newsgroup;
  };
  return @Hierarchies;
};

################################################################################

#####----------------------------- TimePeriods ----------------------------#####

################################################################################
sub GetTimePeriod {
################################################################################
### get a time period to act on, in order of preference: by default the
### last month; or a month submitted by -m YYYY-MM; or a time period submitted
### by -p YYYY-MM:YYYY-MM
### IN : $Month,$Period: contents of -m and -p
### OUT: $StartMonth, $EndMonth (identical if period is just one month)
  my ($Month,$Period) = @_;
  # exit if -m is set and not like YYYY-MM
  die "$MySelf: E: Wrong date format - use '$MySelf -m YYYY-MM'!\n" if not &CheckMonth($Month);
  # warn if -m and -p is set
  warn "$MySelf: W: Time period assigned by '-p' takes precendece over month assigned by '-m'.\n" if ($Month && $Period);
  # default: set -m to last month
  $Month = &LastMonth if (!defined($Month) and !defined($Period));
  # set $StartMonth, $EndMonth
  my ($StartMonth, $EndMonth);
  if ($Period) {
    # -p: get date range
    ($StartMonth, $EndMonth) = &SplitPeriod($Period);
    die "$MySelf: E: Wrong format for time period - use '$MySelf -p YYYY-MM:YYYY-MM'!\n" if !defined($StartMonth);
  } else {
    # set $StartMonth = $EndMonth = $Month if -p is not set
    $StartMonth = $EndMonth = $Month;
  };
  return ($StartMonth, $EndMonth);
};

################################################################################
sub LastMonth {
################################################################################
### get last month from todays date in YYYY-MM format
### OUT: last month as YYYY-MM
  # get today's date
  my (undef,undef,undef,undef,$Month,$Year,undef,undef,undef) = localtime(time);
  # $Month is already defined from 0 to 11, so no need to decrease it by 1
  $Year += 1900;
  if ($Month < 1) {
    $Month = 12;
    $Year--;
  };
  # return last month
  return sprintf('%4d-%02d',$Year,$Month);
};

################################################################################
sub CheckMonth {
################################################################################
### check if input is a valid month in YYYY-MM form
### IN : $Month: month
### OUT: TRUE / FALSE
  my ($Month) = @_;
  return 0 if (defined($Month) and $Month !~ /^\d{4}-\d{2}$/);
  return 1;
};

################################################################################
sub SplitPeriod {
################################################################################
### split a time period denoted by YYYY-MM:YYYY-MM into start and end month
### IN : $Period: time period
### OUT: $StartMonth, Â$EndMonth
  my ($Period) = @_;
  return (undef,undef) if $Period !~ /^\d{4}-\d{2}:\d{4}-\d{2}$/;
  my ($StartMonth, $EndMonth) = split /:/, $Period;
  # switch parameters as necessary
  if ($EndMonth gt $StartMonth) {
    return ($StartMonth, $EndMonth);
  } else {
    return ($EndMonth, $StartMonth);
  };
};

################################################################################
sub ListMonth {
################################################################################
### return a list of months (YYYY-MM) between start and end month
### IN : $StartMonth, $EndMonth
### OUT: @Months: array containing all months from $StartMonth to $EndMonth
  my ($StartMonth, $EndMonth) = @_;
  return (undef,undef) if ($StartMonth !~ /^\d{4}-\d{2}$/ or $EndMonth !~ /^\d{4}-\d{2}$/);
  # return if $StartMonth = $EndMonth
  return ($StartMonth) if ($StartMonth eq $EndMonth);
  # set $Year, $Month from $StartMonth
  my ($Year, $Month) = split /-/, $StartMonth;
  # define @Months
  my (@Months);
  until ("$Year-$Month" gt $EndMonth) {
    push @Months, "$Year-$Month";
    $Month = "$Month"; # force string context
    $Month++;
    if ($Month > 12) {
      $Month = '01';
      $Year++;
    };
  };
  return @Months;
};

#####---------------------------- OutputFormats ---------------------------#####

################################################################################
sub OutputData {
################################################################################
### read database query results from DBHandle and print results with formatting
### IN : $Format  : format specifier
###      $FileName: file name template (-f): filename-YYYY-MM
###      $DBQuery : database query handle with executed query,
###                 containing $Month, $Key, $Value
###      $PadGroup: padding length for newsgroups field (optional) for 'pretty'
  my ($Format, $FileName, $DBQuery, $PadGroup) = @_;
  my ($Handle, $OUT);
  our $LastIteration;
  while (my ($Month, $Key, $Value) = $DBQuery->fetchrow_array) {
    # set output file handle
    if (!$FileName) {
      $Handle = *STDOUT{IO}; # set $Handle to a reference to STDOUT
    } elsif (!defined($LastIteration) or $LastIteration ne $Month) {
      close $OUT if ($LastIteration);
      open ($OUT,sprintf('>%s-%s',$FileName,$Month)) or die sprintf("$MySelf: E: Cannot open output file '%s-%s': $!\n",$FileName,$Month);
      $Handle = $OUT;
    };
    print $Handle &FormatOutput($Format, $Month, $Key, $Value, $PadGroup);
    $LastIteration = $Month;
  };
  close $OUT if ($FileName);
};

################################################################################
sub FormatOutput {
################################################################################
### format information for output according to format specifier
### IN : $Format  : format specifier
###      $Month   : month (as YYYY-MM)
###      $Key     : newsgroup, client, ...
###      $Value   : number of postings with that attribute
###      $PadGroup: padding length for key field (optional) for 'pretty'
### OUT: $Output: formatted output
  my ($Format, $Month, $Key, $Value, $PadGroup) = @_;

  # define output types
  my %LegalOutput;
  @LegalOutput{('dump','dumpgroup','list','pretty')} = ();
  # bail out if format is unknown
  die "$MySelf: E: Unknown output type '$Format'!\n" if !exists($LegalOutput{$Format});

  my ($Output);
  # keep last month in mind
  our ($LastIteration);
  if ($Format eq 'dump') {
    # output as dump (ng nnnnn)
    $Output = sprintf ("%s %u\n",$Key,$Value);
  } elsif ($Format eq 'dumpgroup') {
    # output as dump (YYYY-NN: nnnnn)
    $Output = sprintf ("%s: %5u\n",$Month,$Value);
  } elsif ($Format eq 'list') {
    # output as list (YYYY-NN: ng nnnnn)
    $Output = sprintf ("%s: %s %u\n",$Month,$Key,$Value);
  } elsif ($Format eq 'pretty') {
    # output as table
    $Output = sprintf ("----- %s:\n",$Month) if (!defined($LastIteration) or $Month ne $LastIteration);
    $LastIteration = $Month;
    $Output .= sprintf ($PadGroup ? sprintf("%%-%us %%5u\n",$PadGroup) : "%s %u\n",$Key,$Value);
  };
  return $Output;
};

#####------------------------- QueryModifications -------------------------#####

################################################################################
sub SQLHierarchies {
################################################################################
### add exclusion of hierarchy levels (de.alt.ALL) from SQL query by
### amending the WHERE clause if $ShowHierarchies is false (or don't, if it is
### true, accordingly)
### IN : $ShowHierarchies: boolean value
### OUT: SQL code
  my ($ShowHierarchies) = @_;
  return $ShowHierarchies ? '' : "AND newsgroup NOT LIKE '%.ALL'";
};

################################################################################
sub GetMaxLenght {
################################################################################
### get length of longest field in future query result
### IN : $DBHandle   : database handel
###      $Table      : table to query
###      $Field      : field to check
###      $WhereClause: WHERE clause
###      @BindVars   : bind variables for WHERE clause
### OUT: $Length: length of longest instnace of $Field
  my ($DBHandle,$Table,$Field,$WhereClause,@BindVars) = @_;
  my $DBQuery = $DBHandle->prepare(sprintf("SELECT MAX(LENGTH(%s)) FROM %s WHERE %s",$Field,$Table,$WhereClause));
  $DBQuery->execute(@BindVars) or warn sprintf("$MySelf: W: Can't get field length for %s from table %s: $DBI::errstr\n",$Field,$Table);
  my ($Length) = $DBQuery->fetchrow_array;
  return $Length;
};

################################################################################
sub SQLGroupList {
################################################################################
### explode list of newsgroups separated by : (with wildcards) to a SQL WHERE
### clause
### IN : $Newsgroups: list of newsgroups (group.one.*:group.two:group.three.*)
### OUT: SQL code, list of newsgroups
  my ($Newsgroups) = @_;
  $Newsgroups =~ s/\*/%/g;
  return ('newsgroup LIKE ?', $Newsgroups) if $Newsgroups !~ /:/;
  my $SQL = '(';
  my @GroupList = split /:/, $Newsgroups;
  foreach (@GroupList) {
     $SQL .= ' OR ' if $SQL gt '(';
     $SQL .= 'newsgroup LIKE ?';
  };
  $SQL .= ')';
  return ($SQL,@GroupList);
};

#####------------------------------- done ---------------------------------#####
1;


