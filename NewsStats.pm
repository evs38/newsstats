# NewsStats.pm
#
# Library functions for the NewsStats package.
#
# Copyright (c) 2010-2012 Thomas Hochstein <thh@inter.net>
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
  $MyVersion
  $PackageVersion
  $FullPath
  $HomePath
  ShowVersion
  ShowPOD
  ReadConfig
  OverrideConfig
  InitDB
  Bleat
);
@EXPORT_OK = qw(
  GetTimePeriod
  LastMonth
  SplitPeriod
  ListMonth
  ListNewsgroups
  ReadGroupList
  OutputData
  FormatOutput
  SQLHierarchies
  SQLSortOrder
  SQLGroupList
  SQLSetBounds
  SQLBuildClause
  GetMaxLength
);
%EXPORT_TAGS = ( TimePeriods => [qw(GetTimePeriod LastMonth SplitPeriod
                                 ListMonth)],
                 Output      => [qw(OutputData FormatOutput)],
                 SQLHelper   => [qw(SQLHierarchies SQLSortOrder SQLGroupList
                                 SQLSetBounds SQLBuildClause GetMaxLength)]);
$VERSION = '0.01';
our $PackageVersion = '0.01';

use Data::Dumper;
use File::Basename;

use Config::Auto;
use DBI;

#####-------------------------------- Vars --------------------------------#####

# trim the path
our $FullPath = $0;
our $HomePath = dirname($0);
$0 =~ s%.*/%%;
# set version string
our $MyVersion = "$0 $::VERSION (NewsStats.pm $VERSION)";

#####------------------------------- Basics -------------------------------#####

################################################################################

################################################################################
sub ShowVersion {
################################################################################
### display version and exit
  print "NewsStats v$PackageVersion\n$MyVersion\n";
  print "Copyright (c) 2010-2012 Thomas Hochstein <thh\@inter.net>\n";
  print "This program is free software; you may redistribute it ".
        "and/or modify it under the same terms as Perl itself.\n";
  exit(100);
};
################################################################################

################################################################################
sub ShowPOD {
################################################################################
### feed myself to perldoc and exit
  exec('perldoc', $FullPath);
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
sub OverrideConfig {
################################################################################
### override configuration values
### IN : $ConfigR  : reference to configuration hash
###      $OverrideR: reference to a hash containing overrides
  my ($ConfigR,$OverrideR) = @_;
  my %Override = %$OverrideR;
  # Config hash empty?
  &Bleat(1,"Empty configuration hash passed to OverrideConfig()")
    if ( keys %$ConfigR < 1);
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
  my $DBHandle = DBI->connect(sprintf('DBI:%s:database=%s;host=%s',
                                      $Conf{'DBDriver'},$Conf{'DBDatabase'},
                                      $Conf{'DBHost'}), $Conf{'DBUser'},
                                      $Conf{'DBPw'}, { PrintError => 0 });
  if (!$DBHandle) {
    &Bleat(2,$DBI::errstr) if (defined($Die) and $Die);
    &Bleat(1,$DBI::errstr);
  };
  return $DBHandle;
};
################################################################################

################################################################################
sub Bleat {
################################################################################
### print warning or error messages and terminate in case of error
### IN : $Level  : 1 = warning, 2 = error
###      $Message: warning or error message
  my ($Level,$Message) = @_;
  if ($Level == 1) {
    warn "$0 W: $Message\n"
  } elsif ($Level == 2) {
    die "$0 E: $Message\n"
  } else {
    print "$0: $Message\n"
  }
};
################################################################################

#####------------------------------ GetStats ------------------------------#####

################################################################################
sub ListNewsgroups {
################################################################################
### explode a (scalar) list of newsgroup names to a list of newsgroup and
### hierarchy names where every newsgroup and hierarchy appears only once:
### de.alt.test,de.alt.admin -> de.ALL, de.alt.ALL, de.alt.test, de.alt.admin
### IN : $Newsgroups  : a list of newsgroups (content of Newsgroups: header)
###      $TLH         : top level hierarchy (all other newsgroups are ignored)
###      $ValidGroupsR: reference to a hash containing all valid newsgroups
###                     as keys
### OUT: %Newsgroups  : hash containing all newsgroup and hierarchy names as keys
  my ($Newsgroups,$TLH,$ValidGroupsR) = @_;
  my %ValidGroups = %{$ValidGroupsR} if $ValidGroupsR;
  my %Newsgroups;
  chomp($Newsgroups);
  # remove whitespace from contents of Newsgroups:
  $Newsgroups =~ s/\s//;
  # call &HierarchyCount for each newsgroup in $Newsgroups:
  for (split /,/, $Newsgroups) {
    # don't count newsgroup/hierarchy in wrong TLH
    next if($TLH and !/^$TLH/);
    # don't count invalid newsgroups
    if(%ValidGroups and !defined($ValidGroups{$_})) {
      warn (sprintf("DROPPED: %s\n",$_));
      next;
    }
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
sub ReadGroupList {
################################################################################
### read a list of valid newsgroups from file (each group on one line,
### ignoring everything after the first whitespace and so accepting files
### in checkgroups format as well as (parts of) an INN active file)
### IN : $Filename    : file to read
### OUT: \%ValidGroups: hash containing all valid newsgroups
  my ($Filename) = @_;
  my %ValidGroups;
  open (my $LIST,"<$Filename") or &Bleat(2,"Cannot read $Filename: $!");
  while (<$LIST>) {
    s/^\s*(\S+).*$/$1/;
    chomp;
    next if /^$/;
    $ValidGroups{$_} = '1';
  };
  close $LIST;
  return \%ValidGroups;
};

################################################################################

#####----------------------------- TimePeriods ----------------------------#####

################################################################################
sub GetTimePeriod {
################################################################################
### get a time period to act on from --month option;
### if empty, default to last month
### IN : $Month: may be empty, 'YYYY-MM', 'YYYY-MM:YYYY-MM' or 'all'
### OUT: $Verbal,$SQL: verbal description and WHERE-clause
###                    of the chosen time period
  my ($Month) = @_;
  # define result variables
  my ($Verbal, $SQL);
  # define a regular expression for a month
  my $REMonth = '\d{4}-\d{2}';
  
  # default to last month if option is not set
  if(!$Month) {
    $Month = &LastMonth;
  }
  
  # check for valid input
  if ($Month =~ /^$REMonth$/) {
    # single month (YYYY-MM)
    ($Month) = &CheckMonth($Month);
    $Verbal  = $Month;
    $SQL     = sprintf("month = '%s'",$Month);
  } elsif ($Month =~ /^$REMonth:$REMonth$/) {
    # time period (YYYY-MM:YYYY-MM)
    $Verbal = sprintf('%s to %s',&SplitPeriod($Month));
    $SQL    = sprintf("month BETWEEN '%s' AND '%s'",&SplitPeriod($Month));
  } elsif ($Month =~ /^all$/i) {
    # special case: ALL
    $Verbal = 'all time';
    $SQL    = '';
  } else {
    # invalid input
    return (undef,undef);
  }
  
  return ($Verbal,$SQL);
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
### check if input (in YYYY-MM form) is valid with MM between 01 and 12;
### otherwise, fix it
### IN : @Month: array of month
### OUT: @Month: a valid month
  my (@Month) = @_;
  foreach my $Month (@Month) {
    my ($OldMonth) = $Month;
    my ($CalMonth) = substr ($Month, -2);
    if ($CalMonth < 1 or $CalMonth > 12) {
      $CalMonth = '12' if $CalMonth > 12;
      $CalMonth = '01' if $CalMonth < 1;
      substr($Month, -2) = $CalMonth;
      &Bleat(1,sprintf("'%s' is an invalid date (MM must be between '01' ".
                       "and '12'), set to '%s'.",$OldMonth,$Month));
    }
  }
  return @Month;
};

################################################################################
sub SplitPeriod {
################################################################################
### split a time period denoted by YYYY-MM:YYYY-MM into start and end month
### IN : $Period: time period
### OUT: $StartMonth, $EndMonth
  my ($Period) = @_;
  my ($StartMonth, $EndMonth) = split /:/, $Period;
  ($StartMonth,$EndMonth) = CheckMonth($StartMonth,$EndMonth);
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
### IN : $MonthExpression ('YYYY-MM' or 'YYYY-MM to YYYY-MM')
### OUT: @Months: array containing all months from $MonthExpression enumerated
  my ($MonthExpression )= @_;
  # return if single month
  return ($MonthExpression) if ($MonthExpression =~ /^\d{4}-\d{2}$/);
  # parse $MonthExpression
  my ($StartMonth, $EndMonth) = split(' to ',$MonthExpression);
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
### IN : $Format   : format specifier
###      $Comments : print or suppress all comments for machine-readable output
###      $GroupBy  : primary sorting order (month or key)
###      $Precision: number of digits right of decimal point (0 or 2)
###      $ValidKeys: reference to a hash containing all valid keys
###      $FileTempl: file name template (--filetemplate): filetempl-YYYY-MM
###      $DBQuery  : database query handle with executed query,
###                 containing $Month, $Key, $Value
###      $PadGroup : padding length for key field (optional) for 'pretty'
  my ($Format, $Comments, $GroupBy, $Precision, $ValidKeys, $FileTempl,
      $DBQuery, $PadGroup) = @_;
  my %ValidKeys = %{$ValidKeys} if $ValidKeys;
  my ($FileName, $Handle, $OUT);
  our $LastIteration;
  
  # define output types
  my %LegalOutput;
  @LegalOutput{('dump',,'list','pretty')} = ();
  # bail out if format is unknown
  &Bleat(2,"Unknown output type '$Format'!") if !exists($LegalOutput{$Format});

  while (my ($Month, $Key, $Value) = $DBQuery->fetchrow_array) {
    # don't display invalid keys
    if(%ValidKeys and !defined($ValidKeys{$Key})) {
      # FIXME
      # &Bleat(1,sprintf("DROPPED: %s",$Key));
      next;
    };
    # care for correct sorting order and abstract from month and keys:
    # $Caption will be $Month or $Key, according to sorting order,
    # and $Key will be $Key or $Month, respectively
    my $Caption;
    if ($GroupBy eq 'key') {
      $Caption = $Key;
      $Key     = $Month;
    } else {
      $Caption = $Month;
    }
    # set output file handle
    if (!$FileTempl) {
      $Handle = *STDOUT{IO}; # set $Handle to a reference to STDOUT
    } elsif (!defined($LastIteration) or $LastIteration ne $Caption) {
      close $OUT if ($LastIteration);
      # safeguards for filename creation:
      # replace potential problem characters with '_'
      $FileName = sprintf('%s-%s',$FileTempl,$Caption);
      $FileName =~ s/[^a-zA-Z0-9_-]+/_/g; 
      open ($OUT,">$FileName")
        or &Bleat(2,sprintf("Cannot open output file '%s': $!",
                            $FileName));
      $Handle = $OUT;
    };
    print $Handle &FormatOutput($Format, $Comments, $Caption, $Key, $Value,
                                $Precision, $PadGroup);
    $LastIteration = $Caption;
  };
  close $OUT if ($FileTempl);
};

################################################################################
sub FormatOutput {
################################################################################
### format information for output according to format specifier
### IN : $Format   : format specifier
###      $Comments : print or suppress all comments for machine-readable output
###      $Caption  : month (as YYYY-MM) or $Key, according to sorting order
###      $Key      : newsgroup, client, ... or $Month, as above
###      $Value    : number of postings with that attribute
###      $Precision: number of digits right of decimal point (0 or 2)
###      $PadGroup : padding length for key field (optional) for 'pretty'
### OUT: $Output: formatted output
  my ($Format, $Comments, $Caption, $Key, $Value, $Precision, $PadGroup) = @_;
  my ($Output);
  # keep last caption in mind
  our ($LastIteration);
  # create one line of output
  if ($Format eq 'dump') {
    # output as dump (key value)
    $Output = sprintf ("# %s:\n",$Caption)
      if ($Comments and (!defined($LastIteration) or $Caption ne $LastIteration));
    $Output .= sprintf ("%s %u\n",$Key,$Value);
  } elsif ($Format eq 'list') {
    # output as list (caption key value)
    $Output = sprintf ("%s %s %u\n",$Caption,$Key,$Value);
  } elsif ($Format eq 'pretty') {
    # output as a table
    $Output = sprintf ("# ----- %s:\n",$Caption)
      if ($Comments and (!defined($LastIteration) or $Caption ne $LastIteration));
    $Output .= sprintf ($PadGroup ? sprintf("%%-%us %%10.*f\n",$PadGroup) :
                        "%s %.*f\n",$Key,$Precision,$Value);
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
  return $ShowHierarchies ? '' : "newsgroup NOT LIKE '%.ALL'";
};

################################################################################
sub GetMaxLength {
################################################################################
### get length of longest field in future query result
### IN : $DBHandle    : database handel
###      $Table       : table to query
###      $Field       : field to check
###      $WhereClause : WHERE clause
###      $HavingClause: HAVING clause
###      @BindVars    : bind variables for WHERE clause
### OUT: $Length: length of longest instnace of $Field
  my ($DBHandle,$Table,$Field,$WhereClause,$HavingClause,@BindVars) = @_;
  my $DBQuery = $DBHandle->prepare(sprintf("SELECT MAX(LENGTH(%s)) ".
                                           "FROM %s %s %s",$Field,$Table,
                                           $WhereClause,$HavingClause ?
                                           'GROUP BY newsgroup' . $HavingClause .
                                           ' ORDER BY LENGTH(newsgroup) '.
                                           'DESC LIMIT 1': ''));
  $DBQuery->execute(@BindVars) or &Bleat(1,sprintf("Can't get field length ".
                                                   "for '%s' from table '%s': ".
                                                   "$DBI::errstr",$Field,$Table));
  my ($Length) = $DBQuery->fetchrow_array;
  return $Length;
};

################################################################################
sub SQLSortOrder {
################################################################################
### build a SQL 'ORDER BY' clause from $OptGroupBy (primary sorting) and
### $OptOrderBy (secondary sorting), both ascending or descending;
### descending sorting order is done by adding '-desc'
### IN : $GroupBy: primary sort by 'month' (default) or 'newsgroups'
###      $OrderBy: secondary sort by month/newsgroups (default)
###                or number of 'postings'
### OUT: a SQL ORDER BY clause
  my ($GroupBy,$OrderBy) = @_;
  my ($GroupSort,$OrderSort) = ('','');
  # $GroupBy (primary sorting)
  if (!$GroupBy) {
    $GroupBy   = 'month';
  } else {
    ($GroupBy, $GroupSort) = SQLParseOrder($GroupBy);
    if ($GroupBy =~ /group/i) {
      $GroupBy   = 'newsgroup';
    } else {
      $GroupBy   = 'month';
    }
  }
  my $Secondary = ($GroupBy eq 'month') ? 'newsgroup' : 'month';
  # $OrderBy (secondary sorting)
  if (!$OrderBy) {
    $OrderBy = $Secondary;
  } else {
    ($OrderBy, $OrderSort) = SQLParseOrder($OrderBy);
    if ($OrderBy =~ /posting/i) {
      $OrderBy = "postings $OrderSort, $Secondary";
    } else {
      $OrderBy = "$Secondary $OrderSort";
    }
  }
  return ($GroupBy,&SQLBuildClause('order',"$GroupBy $GroupSort",$OrderBy));
};

################################################################################
sub SQLParseOrder {
################################################################################
### parse $OptGroupBy or $OptOrderBy option of the form param[-desc], e.g.
### 'month', 'month-desc', 'newsgroups-desc', but also just 'desc'
### IN : $OrderOption: order option (see above)
### OUT: parameter to sort by,
###      sort order ('DESC' or nothing, meaning 'ASC')
  my ($OrderOption) = @_;
  my $SortOrder = '';
  if ($OrderOption =~ s/-?desc$//i) {
    $SortOrder = 'DESC';
  } else {
    $OrderOption =~ s/-?asc$//i
  }
  return ($OrderOption,$SortOrder);
};

################################################################################
sub SQLGroupList {
################################################################################
### explode list of newsgroups separated by : (with wildcards)
### to a SQL 'WHERE' expression
### IN : $Newsgroups: list of newsgroups (group.one.*:group.two:group.three.*)
### OUT: SQL code to become part of a 'WHERE' clause,
###      list of newsgroups for SQL bindings
  my ($Newsgroups) = @_;
  # substitute '*' wildcard with SQL wildcard character '%'
  $Newsgroups =~ s/\*/%/g;
  # just one newsgroup?
  return (SQLGroupWildcard($Newsgroups),$Newsgroups) if $Newsgroups !~ /:/;
  # list of newsgroups separated by ':'
  my $SQL = '(';
  my @GroupList = split /:/, $Newsgroups;
  foreach (@GroupList) {
     $SQL .= ' OR ' if $SQL gt '(';
     $SQL .= SQLGroupWildcard($_);
  };
  $SQL .= ')';
  return ($SQL,@GroupList);
};

################################################################################
sub SQLGroupWildcard {
################################################################################
### build a valid SQL 'WHERE' expression with or without wildcards
### IN : $Newsgroup: newsgroup expression, probably with wildcard
###                  (group.name or group.name.%)
### OUT: SQL code to become part of a 'WHERE' clause
  my ($Newsgroup) = @_;
  # FIXME: check for validity
  if ($Newsgroup !~ /%/) {
    return 'newsgroup = ?';
  } else {
    return 'newsgroup LIKE ?';
  }
};

################################################################################
sub SQLSetBounds {
################################################################################
### set upper and/or lower boundary (number of postings)
### IN : $Type: 'level', 'average', 'sum' or 'default'
###      $LowBound,$UppBound: lower/upper boundary, respectively
### OUT: SQL code to become part of a WHERE or HAVING clause
  my ($Type,$LowBound,$UppBound) = @_;
  ($LowBound,$UppBound) = SQLCheckNumber($LowBound,$UppBound);
  if($LowBound and $UppBound and $LowBound > $UppBound) {
    &Bleat(1,"Lower boundary $LowBound is larger than Upper boundary ".
             "$UppBound, exchanging boundaries.");
    ($LowBound,$UppBound) = ($UppBound,$LowBound);
  }
  # default to 'default'
  my $WhereHavingFunction = 'postings';
  # set $LowBound to SQL statement:
  # 'WHERE postings >=', 'HAVING MIN(postings) >=' or 'HAVING AVG(postings) >='
  if ($Type eq 'level') {
    $WhereHavingFunction = 'MIN(postings)'
  } elsif ($Type eq 'average') {
    $WhereHavingFunction = 'AVG(postings)'
  } elsif ($Type eq 'sum') {
    $WhereHavingFunction = 'SUM(postings)'
  }
  $LowBound = sprintf('%s >= '.$LowBound,$WhereHavingFunction) if ($LowBound);
  # set $LowBound to SQL statement:
  # 'WHERE postings <=', 'HAVING MAX(postings) <=' or 'HAVING AVG(postings) <='
  if ($Type eq 'level') {
    $WhereHavingFunction = 'MAX(postings)'
  } elsif ($Type eq 'average') {
    $WhereHavingFunction = 'AVG(postings)'
  } elsif ($Type eq 'sum') {
    $WhereHavingFunction = 'SUM(postings)'
  }
  $UppBound = sprintf('%s <= '.$UppBound,$WhereHavingFunction) if ($UppBound);
  return ($LowBound,$UppBound);
};

################################################################################
sub SQLCheckNumber {
################################################################################
### check if input is a valid positive integer; otherwise, make it one
### IN : @Numbers: array of parameters
### OUT: @Numbers: a valid positive integer
  my (@Numbers) = @_;
  foreach my $Number (@Numbers) {
    if ($Number and $Number < 0) {
      &Bleat(1,"Boundary $Number is < 0, set to ".-$Number);
      $Number = -$Number;
    }
    $Number = '' if ($Number and $Number !~ /^\d+$/);
  }
  return @Numbers;
};

################################################################################
sub SQLBuildClause {
################################################################################
### build a valid SQL WHERE, GROUP BY, ORDER BY or HAVING clause
### from multiple expressions which *may* be empty
### IN : $Type: 'where', 'having', 'group' or 'order'
###      @Expressions: array of expressions
### OUT: $SQLClause: a SQL clause
  my ($Type,@Expressions) = @_;
  my ($SQLClause,$Separator,$Statement);
  # set separator ('AND' or ',')
  if ($Type eq 'where' or $Type eq 'having') {
    $Separator = 'AND';
  } else {
    $Separator = ',';
  }
  # set statement
  if ($Type eq 'where') {
    $Statement = 'WHERE';
  } elsif ($Type eq 'order') {
    $Statement = 'ORDER BY';
  } elsif ($Type eq 'having') {
    $Statement = 'HAVING';
  } else {
    $Statement = 'GROUP BY';
  }
  # build query from expressions with separators
  foreach my $Expression (@Expressions) {
    if ($Expression) {
      $SQLClause .= " $Separator " if ($SQLClause);
      $SQLClause .= $Expression;
    }
  }
  # add statement in front if not already present
  $SQLClause = " $Statement " . $SQLClause
    if ($SQLClause and $SQLClause !~ /$Statement/);
  return $SQLClause;
};


#####------------------------------- done ---------------------------------#####
1;


