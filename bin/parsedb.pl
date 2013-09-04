#! /usr/bin/perl
#
# parsedb.pl
#
# This script will parse a database with raw header information
# from a INN feed to a structured database.
#
# It is part of the NewsStats package.
#
# Copyright (c) 2013 Thomas Hochstein <thh@inter.net>
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

use NewsStats qw(:DEFAULT :TimePeriods :SQLHelper);

use DBI;
use Getopt::Long qw(GetOptions);
Getopt::Long::config ('bundling');

use Encode qw/decode/;
use Mail::Address;

################################# Definitions ##################################

# define header names with separate database fields
my %DBFields = ('date'                      => 'date',
                'references'                => 'refs',
                'followup-to'               => 'fupto',
                'from'                      => 'from_',
                'sender'                    => 'sender',
                'reply-to'                  => 'replyto',
                'subject'                   => 'subject',
                'organization'              => 'organization',
                'lines'                     => 'linecount',
                'approved'                  => 'approved',
                'supersedes'                => 'supersedes',
                'expires'                   => 'expires',
                'user-agent'                => 'useragent',
                'x-newsreader'              => 'xnewsreader',
                'x-mailer'                  => 'xmailer',
                'x-no-archive'              => 'xnoarchive',
                'content-type'              => 'contenttype',
                'content-transfer-encoding' => 'contentencoding',
                'cancel-lock'               => 'cancellock',
                'injection-info'            => 'injectioninfo',
                'x-trace'                   => 'xtrace',
                'nntp-posting-host'         => 'postinghost');

# define field list for database
my @DBFields = qw/day mid refs date path newsgroups fupto from_ from_parsed
                 from_name from_address sender sender_parsed sender_name
                 sender_address replyto replyto_parsed replyto_name
                 replyto_address subject subject_parsed organization linecount
                 approved supersedes expires useragent xnewsreader xmailer
                 xnoarchive contenttype contentencoding cancellock injectioninfo
                 xtrace postinghost headers disregard/;

################################# Main program #################################

### read commandline options
my ($OptDay,$OptDebug,$OptParseDB,$OptRawDB,$OptTest,$OptConfFile);
GetOptions ('d|day=s'         => \$OptDay,
            'debug!'          => \$OptDebug,
            'parsedb=s'       => \$OptParseDB,
            'rawdb=s'         => \$OptRawDB,
            't|test!'         => \$OptTest,
            'conffile=s'      => \$OptConfFile,
            'h|help'          => \&ShowPOD,
            'V|version'       => \&ShowVersion) or exit 1;

### read configuration
my %Conf = %{ReadConfig($OptConfFile)};

### override configuration via commandline options
my %ConfOverride;
$ConfOverride{'DBTableRaw'}   = $OptRawDB if $OptRawDB;
$ConfOverride{'DBTableParse'} = $OptParseDB if $OptParseDB;
&OverrideConfig(\%Conf,\%ConfOverride);

### get time period
### and set $Period for output and expression for SQL 'WHERE' clause
my ($Period,$SQLWherePeriod) = &GetTimePeriod($OptDay,'day');
# bail out if --month is invalid or "all"
&Bleat(2,"--day option has an invalid format - please use 'YYYY-MM-DD' or ".
         "'YYYY-MM-DD:YYYY-MM-DD'!") if (!$Period or $Period eq 'all time');

### init database
my $DBHandle = InitDB(\%Conf,1);

### get & write data
&Bleat(1,'Test mode. Database is not updated.') if $OptTest;

# create $SQLWhereClause
my $SQLWhereClause = SQLBuildClause('where',$SQLWherePeriod,'NOT disregard');

# delete old data for current period
if (!$OptTest) {
  print "----------- Deleting old data ... -----------\n" if $OptDebug;
  my $DBQuery = $DBHandle->do(sprintf("DELETE FROM %s.%s %s",
                                     $Conf{'DBDatabase'},$Conf{'DBTableParse'},
                                     $SQLWhereClause))
      or &Bleat(2,sprintf("Can't delete old parsed data for %s from %s.%s: ".
                          "$DBI::errstr\n",$Period,
                          $Conf{'DBDatabase'},$Conf{'DBTableParse'}));
};

# read from DBTableRaw
print "-------------- Reading data ... -------------\n" if $OptDebug;
my $DBQuery = $DBHandle->prepare(sprintf("SELECT id, day, mid, peer, path, ".
                                         "newsgroups, headers, disregard ".
                                         "FROM %s.%s %s", $Conf{'DBDatabase'},
                                         $Conf{'DBTableRaw'}, $SQLWhereClause));
$DBQuery->execute()
  or &Bleat(2,sprintf("Can't get data for %s from %s.%s: ".
                      "$DBI::errstr\n",$Period,
                      $Conf{'DBDatabase'},$Conf{'DBTableRaw'}));

# set output and database connection to UTF-8
# as we're going to write decoded header contents containing UTF-8 chars
binmode(STDOUT, ":utf8");
$DBHandle->do("SET NAMES 'utf8'");

# parse data in a loop and write it out
print "-------------- Parsing data ... -------------\n" if $OptDebug;
while (my $HeadersR = $DBQuery->fetchrow_hashref) {
  my %Headers = %{$HeadersR};

  # parse $Headers{'headers'} ('headers' from DBTableRaw)
  # merge continuation lines
  # from Perl Cookbook, 1st German ed. 1999, pg. 91
  $Headers{'headers'} =~ s/\n\s+/ /g;
  # split headers in single lines
  my $OtherHeaders;
  for (split(/\n/,$Headers{'headers'})) {
    # split header lines in header name and header content
    my ($key,$value) = split(/:/,$_,2);
    $key =~ s/\s*//;
    $value =~ s/^\s*(.+)\s*$/$1/;
    # save each header, separate database fields in %Headers,
    # the rest in $OtherHeaders (but not Message-ID, Path, Peer
    # and Newsgroups as those do already exist)
    if (defined($DBFields{lc($key)})) {
      $Headers{$DBFields{lc($key)}} = $value;
    } else {
      $OtherHeaders .= sprintf("%s: %s\n",$key,$value)
        if lc($key) !~ /^(message-id|path|peer|newsgroups)$/;
    }
  }
  # replace old (now parsed) $Headers{'headers'} with remanining $OtherHeaders
  chomp($OtherHeaders);
  $Headers{'headers'} = $OtherHeaders;

  foreach ('from_','sender', 'replyto', 'subject') {
    if ($Headers{$_}) {
      my $HeaderName = $_;
      $HeaderName  =~ s/_$//;
      # decode From: / Sender: / Reply-To: / Subject:
      if ($Headers{$_} =~ /\?(B|Q)\?/) {
        $Headers{$HeaderName.'_parsed'} = decode('MIME-Header',$Headers{$_});
      }
      # extract name(s) and mail(s) from From: / Sender: / Reply-To:
      # in parsed form, if available
      if ($_ ne 'subject') {
        my @Address;
        # start parser on header or parsed header
        # @Address will have an array of Mail::Address objects, one for
        # each name/mail (you can have more than one person in From:!)
        if (defined($Headers{$HeaderName.'_parsed'})) {
          @Address = Mail::Address->parse($Headers{$HeaderName.'_parsed'});
        } else {
          @Address = Mail::Address->parse($Headers{$_});
        }
        # split each Mail::Address object to @Names and @Adresses
        my (@Names,@Adresses);
        foreach (@Address) {
          # take address part in @Addresses
          push (@Adresses, $_->address());
          # take name part form "phrase", if there is one:
          # From: My Name <addr@ess> (Comment)
          # otherwise, take it from "comment":
          # From: addr@ess (Comment)
          # and push it in @Names
          my ($Name);
          $Name = $_->comment() unless $Name = $_->phrase;
          $Name =~ s/^\((.+)\)$/$1/;
          push (@Names, $Name);
        }
        # put all @Adresses and all @Names in %Headers as comma separated lists
        $Headers{$HeaderName.'_address'} = join(', ',@Adresses);
        $Headers{$HeaderName.'_name'}    = join(', ',@Names);
      }
    }
  }

  # order output for database entry: fill @SQLBindVars
  print "-------------- Next entry:\n" if $OptDebug;
  my @SQLBindVars;
  foreach (@DBFields) {
    if (defined($Headers{$_}) and $Headers{$_} ne '') {
      push (@SQLBindVars,$Headers{$_});
      printf ("FOUND: %s -> %s\n",$_,$Headers{$_}) if $OptDebug;
    } else {
      push (@SQLBindVars,undef);
    }
  }

  # write data to DBTableParse
  if (!$OptTest) {
    print "-------------- Writing data ... -------------\n" if $OptDebug;
    my $DBWrite =
       $DBHandle->prepare(sprintf("INSERT INTO %s.%s (%s) VALUES (%s)",
                                  $Conf{'DBDatabase'},
                                  $Conf{'DBTableParse'},
                                  # get field names from @DBFields
                                  join(', ',@DBFields),
                                  # create a list of '?' for each DBField
                                  join(', ',
                                       split(/ /,'? ' x scalar(@DBFields)))
                                ));
  $DBWrite->execute(@SQLBindVars)
      or &Bleat(2,sprintf("Can't write parsed data for %s to %s.%s: ".
                          "$DBI::errstr\n",$Period,
                          $Conf{'DBDatabase'},$Conf{'DBTableParse'}));
    $DBWrite->finish;
  }
};
$DBQuery->finish;

### close handles
$DBHandle->disconnect;

print "------------------- DONE! -------------------\n" if $OptDebug;
__END__

################################ Documentation #################################

=head1 NAME

parsedb - parse raw data and save it to a database

=head1 SYNOPSIS

B<parsedb> [B<-Vht>] [B<--day> I<YYYY-MM-DD> | I<YYYY-MM-DD:YYYY-MM-DD>] [B<--rawdb> I<database table>] [B<--parsedb> I<database table>] [B<--conffile> I<filename>] [B<--debug>]

=head1 REQUIREMENTS

See L<doc/README>.

=head1 DESCRIPTION

This script will parse raw, unstructured headers from a database table which is
fed from F<feedlog.pl> for a given time period and write its results to
nother database table with separate fields (columns) for most (or even all)
relevant headers.

I<Subject:>, I<From:>, I<Sender:> and I<Reply-To:> will be parsed from MIME
encoded words to UTF-8 as needed while the unparsed copy is kept. From that
parsed copy, I<From:>, I<Sender:> and I<Reply-To:> will also be split into
separate name(s) and address(es) fields while the un-splitted copy is kept,
too.

B<parsedb> should be run nightly from cron for yesterdays data so all
other scripts get current information. The time period to act on defaults to
yesterday, accordingly; you can assign another time period or a single day via
the B<--day> option (see below).

=head2 Configuration

B<parsedb> will read its configuration from F<newsstats.conf>
should be present in etc/ via Config::Auto or from a configuration file
submitted by the B<--conffile> option.

See L<doc/INSTALL> for an overview of possible configuration options.

You can override configuration options via the B<--rawdb> and
B<--parsedb> options, respectively.

=head1 OPTIONS

=over 3

=item B<-V>, B<--version>

Print out version and copyright information and exit.

=item B<-h>, B<--help>

Print this man page and exit.

=item B<--debug>

Output (rather much) debugging information to STDOUT while processing.

=item B<-t>, B<--test>

Do not write results to database. You should use B<--debug> in
conjunction with B<--test> ... everything else seems a bit pointless.

=item B<-d>, B<--day> I<YYYY-MM-DD[:YYYY-MM-DD]>

Set processing period to a single day in YYYY-MM-DD format or to a time
period between two days in YYYY-MM-DD:YYYY-MM-DD format (two days, separated
by a colon).

Defaults to yesterday.

=item B<--rawdb> I<table> (raw data table)

Override I<DBTableRaw> from F<newsstats.conf>.

=item B<--parsedb> I<table> (parsed data table)

Override I<DBTableParse> from F<newsstats.conf>.

=item B<--conffile> I<filename>

Load configuration from I<filename> instead of F<newsstats.conf>.

=back

=head1 INSTALLATION

See L<doc/INSTALL>.

=head1 EXAMPLES

An example crontab entry:

    0 1 * * * /path/to/bin/parsedb.pl

Do a dry run for yesterday's data, showing results of processing:

    parsedb --debug --test | less

=head1 FILES

=over 4

=item F<bin/parsedb.pl>

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

Copyright (c) 2013 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
