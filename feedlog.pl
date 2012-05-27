#! /usr/bin/perl -W
#
# feedlog.pl
#
# This script will log headers and other data to a database
# for further analysis by parsing a feed from INN.
# 
# It is part of the NewsStats package.
#
# Copyright (c) 2010-2012 Thomas Hochstein <thh@inter.net>
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
use Getopt::Long qw(GetOptions);
Getopt::Long::config ('bundling');

################################# Main program #################################

### read commandline options
my ($OptDebug,$OptQuiet);
GetOptions ('d|debug!'        => \$OptDebug,
            'q|test!'         => \$OptQuiet,
            'h|help'          => \&ShowPOD,
            'V|version'       => \&ShowVersion) or exit 1;

### read configuration
my %Conf = %{ReadConfig($HomePath.'/newsstats.conf')};

### init syslog
openlog($0, 'nofatal,pid', LOG_NEWS);
syslog(LOG_NOTICE, "$MyVersion starting up.") if !$OptQuiet;

### init database
my $DBHandle = InitDB(\%Conf,0);
if (!$DBHandle) {
  syslog(LOG_CRIT, 'Database connection failed: %s', $DBI::errstr);
  while (1) {}; # go into endless loop to suppress further errors and respawning
};
my $DBQuery = $DBHandle->prepare(sprintf("INSERT INTO %s.%s (day,date,mid,
                                         timestamp,token,size,peer,path,
                                         newsgroups,headers)
                                         VALUES (?,?,?,?,?,?,?,?,?,?)",
                                         $Conf{'DBDatabase'},$Conf{'DBTableRaw'}));

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
  if (!$DBQuery->execute($Day, $Date, $Mid, $Timestamp, $Token, $Size, $Peer,
                         $Path, $Newsgroups, $Headers)) {
    syslog(LOG_ERR, 'Database error: %s', $DBI::errstr);
  };
  $DBQuery->finish;
  
  warn sprintf("-----\nDay: %s\nDate: %s\nMID: %s\nTS: %s\nToken: %s\n".
               "Size: %s\nPeer: %s\nPath: %s\nNewsgroups: %s\nHeaders: %s\n",
               $Day, $Date, $Mid, $Timestamp, $Token, $Size, $Peer, $Path,
               $Newsgroups, $Headers) if $OptDebug;
}

### close handles
$DBHandle->disconnect;
syslog(LOG_NOTICE, "$0 closing down.") if !$OptQuiet;
closelog();

__END__

################################ Documentation #################################

=head1 NAME

feedlog - log data from an INN feed to a database

=head1 SYNOPSIS

B<feedlog> [B<-Vhdq>]

=head1 REQUIREMENTS

See L<doc/README>.

=head1 DESCRIPTION

This script will log overview data and complete headers to a database
table for further examination by parsing a feed from INN. It will
parse that information and write it to a mysql database table in real
time.

All reporting is done to I<syslog> via I<news> facility. If B<feedlog>
fails to initiate a database connection at startup, it will log to
I<syslog> with I<CRIT> priority and go in an endless loop, as
terminating would only result in a rapid respawn.

=head2 Configuration

B<feedlog> will read its configuration from F<newsstats.conf> which
should be present in the same directory via Config::Auto.

See L<doc/INSTALL> for an overview of possible configuration options.

=head1 OPTIONS

=over 3

=item B<-V>, B<--version>

Print out version and copyright information and exit.

=item B<-h>, B<--help>

Print this man page and exit.

=item B<-d>, B<--debug>

Output debugging information to STDERR while parsing STDIN. You'll
find that information most probably in your B<INN> F<errlog> file.

=item B<-q>, B<--quiet>

Suppress logging to syslog.

=back

=head1 INSTALLATION

See L<doc/INSTALL.>

=head1 EXAMPLES

Set up a feed like that in your B<INN> F<newsfeeds> file:

    ## gather statistics for NewsStats
    newsstats!
            :!*,de.*
            :Tc,WmtfbsPNH,Ac:/path/to/feedlog.pl

See L<doc/INSTALL> for further information.

=head1 FILES

=over 4

=item F<feedlog.pl>

The script itself.

=item F<NewsStats.pm>

Library functions for the NewsStats package.

=item F<newsstats.conf>

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

Copyright (c) 2010-2012 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
