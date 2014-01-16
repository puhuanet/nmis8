#!/usr/bin/perl
#
## $Id: install.pl,v 8.2 2012/05/24 13:24:37 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# TODO:
# * Unattended install e.g. install.pl site=/usr/local/nmis8 fping=/usr/local/sbin/fping cpan=true
# * Documented command line options

# Load the necessary libraries
use FindBin;
use lib "$FindBin::Bin/lib";
use NMIS;
use func;

use strict;
#use warnings;
use DirHandle;
use Data::Dumper;
#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
#use File::Copy;
use File::Find;
#use File::Path;
use Cwd;

## Setting Default Install Options.
my $defaultSite = "/usr/local/nmis8";
my $defaultFping = "/usr/local/sbin/fping";
my $defaultCpan = 1;
my $installLog = undef;
my $nmisModules;			# local modules used in our scripts

if ( $ARGV[0] =~ /\-\?|\-h|--help/ ) {
	printHelp();
	exit 0;
}

# Get some command line arguements.
my %arg = getArguements(@ARGV);

my $site = $arg{site} ? $arg{site} : $defaultSite;
my $fping = $arg{fping} ? $arg{fping} : $defaultFping;
my $cpan = 0 ? $arg{cpan} =~ /0|false|no/ : $defaultCpan;

my $debug = 0;
$debug = 1 if $arg{debug};

print qx|clear|;

###************************************************************************###
printBanner("NMIS Installation Version $NMIS::VERSION");

###************************************************************************###
printBanner("Getting installation source location...");

my $src = cwd() . $ARGV[0];
$src = input_str("Full path to distribution folder:", $src);

$installLog = "$src/install.log";
logInstall("Source is $src");


###************************************************************************###
printBanner("Checking Perl version...");

my $ver = ref($^V) eq 'version' ? $^V->normal : ( $^V ? join('.', unpack 'C*', $^V) : $] );
my $perl_ver_check = '';
if ($] < 5.010001) {  # our minimal requirement for support
	print qq|The version of Perl installed on your server is lower than the minimum supported version 5.10.1. Please upgrade to at least Perl 5.10.1|;
}
else {
	my $message = "The version of Perl installed on your server $ver is OK";
	print qq|\n$message\n\n|;
	logInstall($message);
}


###************************************************************************###
if ( $cpan ) {
	checkCpan();
}


###************************************************************************###
printBanner("Configuring installation path...");
my $site = input_str("Folder to install NMIS in", $defaultSite);


###************************************************************************###
if ( -d $site ) {
	printBanner("Make a backup of an existing install...");

	exit unless input_yn("OK to make a backup of your current NMIS?:");
	my $backupFile = getBackupFileName();
	execPrint("cd $site;tar cvf ~/$backupFile ./admin ./bin ./cgi-bin ./conf ./install ./lib ./menu ./mibs ./models");
	print "Backup of NMIS install in $backupFile\n";
}


###************************************************************************###
printBanner("Copying NMIS system files...");

exit unless input_yn("OK to copy NMIS distribution files from $src to $site:");
print "Copying source files from $src to $site...\n";

if ( not -d $site ) {
	execPrint("mkdir $site");
}
execPrint("cp -r $src/* $site");


###************************************************************************###
printBanner("Update the config files with new options...");

exit unless input_yn("OK to update the config files?:");
# merge changes for new NMIS Config options. 
execPrint("$site/admin/updateconfig.pl $site/install/Config.nmis $site/conf/Config.nmis");
execPrint("$site/admin/updateconfig.pl $site/install/Access.nmis $site/conf/Access.nmis");
 
# update default config options that have been changed:
execPrint("$site/install/update_config_defaults.pl $site/install/Config.nmis");


###************************************************************************###
if ( -f $fping ) {
	printBanner("Restart the fping daemon...");
	execPrint("$site/bin/fpingd.pl restart=true");
}

	
###************************************************************************###
printBanner("Cache some fonts...");
execPrint("fc-cache -f -v");


###************************************************************************###
printBanner("Checking configuration...");
execPrint("$site/bin/nmis.pl type=config");


###************************************************************************###
printBanner("Fixing file permissions...");
execPrint("$site/admin/fixperms.pl");


###************************************************************************###
printBanner("NMIS Should be Ready to Roll!");


exit 0;

# this is called for every file found
sub getModules {

	my $file = $File::Find::name;		# full path here

	return if ! -r $file;
	return unless $file =~ /\.pl|\.pm$/;
	parsefile( $file );
}

# this could be used again to find all module dependancies - TBD
sub parsefile {
	my $f = shift;

	open my $fh, '<', $f or print "couldn't open $f\n" && return;

	while (my $line = <$fh>) {
		chomp $line;
		next unless $line;
		
		# test for module use 'xxx' or 'xxx::yyy' or 'xxx::yyy::zzz'
		if ( $line =~ m/^#/ ) {
			next;
		}
		elsif ( 
			$line =~ m/^(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ 
			or $line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+)/ 
			or $line =~ m/(use|require)\s+(\w+);/ 
		) {
			my $mod = $2;
			if ( defined $mod and $mod ne '' and $mod !~ /^\d+/ ) {
				$nmisModules->{$mod}{file} = 'MODULE NOT FOUND';					# set all as 'MODULE NOT FOUND' here, will check installation status of '$mod' next
				$nmisModules->{$mod}{type} = $1;
				if (not grep {$_ eq $f} @{$nmisModules->{$mod}{by}}) {
					push(@{$nmisModules->{$mod}{by}},$f);
				}
			}
		}
		elsif ($line =~ m/(use|require)\s+(\w+::\w+::\w+|\w+::\w+|\w+)/ ) {
			print "PARSE $f: $line\n" if $debug;
		}

	}	#next line of script
	close $fh;
}



sub checkCpan {
	printBanner("Checking for required Perl modules");
	print <<EOF;
This will check for installed Perl modules, first by parsing the 
source code to build a list of used modules. Then by checking that 
the module exists in the src code or is found in the perl standard 
\@INC directory list: @INC

If the check reports that a required module is missing, which can be 
installed with CPAN

  perl -MCPAN -e shell
    install [module name]

EOF
	
	my $libPath = "$src/lib";
	
	my $mod;
	
	# Check that all the local libaries required by NMIS8, are available to us.
	# when a module is found, parse it for its own reqired modules, so we build a complete install list
	# the nmis base is assumed to be one dir above us, as we should be run from <nmisbasedir>/install folder
	
	# loop over the check and install script

	find(\&getModules, "$src");

	# now determine if installed or not.
	foreach my $mod ( keys %$nmisModules ) {

		my $mFile = $mod . '.pm';
		# check modules that are multivalued, such as 'xx::yyy'	and replace :: with directory '/'
		$mFile =~ s/::/\//g;
		# test for local include first
		if ( -e "$libPath/$mFile" ) {
			$nmisModules->{$mod}{file} = "$libPath/$mFile" . "\t\t" . &moduleVersion("$libPath/$mFile");
		}
		else {
			# Now look in @INC for module path and name
			foreach my $path( @INC ) {
				if ( -e "$path/$mFile" ) {
					$nmisModules->{$mod}{file} = "$path/$mFile" . "\t\t" . &moduleVersion("$path/$mFile");
				}
			}
		}

	}

	listModules();
}


# get the module version
# this is non-optimal, but gets the task done with no includes or 'use modulexxx'
# whhich would kill this script :-)
sub moduleVersion {
	my $mFile = shift;
	open FH,"<$mFile" or return 'FileNotFound';
	while (<FH>) {
		if ( /(?:our\s+\$VERSION|my\s+\$VERSION|\$VERSION|\s+version|::VERSION)/i ) {
			/(\d+\.\d+(?:\.\d+)?)/;
			if ( defined $1 and $1 ne '' ) {
				return " $1";
			}
		}
	}
	close FH;
	return ' ';
}

sub listModules {
	# list modules found/MODULE NOT FOUND
	my $f1;
	my $f2;
	my $f3;

	format =
  @<<<<<<<<<<<<<<<<<<<<<   @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   @>>>>>>>>>
  $f1,                     $f2,                                      $f3
.

	foreach my $k (sort {$nmisModules->{$a}{file} cmp $nmisModules->{$b}{file} } keys %$nmisModules) {
		$f1 = $k;
		( $f2 , $f3) = split /\s+/, $nmisModules->{$k}{file}, 2;
		$f3 = ' ' if !$f3;
		write();
	}
	
	print qq|
You will need to investigate and possibly install modules indicated with MODULE NOT FOUND

The modules Net::LDAP, Net::LDAPS, IO::Socket::SSL, Crypt::UnixCrypt, Authen::TacacsPlus, Authen::Simple::RADIUS are optionally required by the NMIS AAA system.

|;
	
	logInstall(Dumper $nmisModules);
}


# question , return true if y, else 0 if no, default is yes.
sub input_yn {

	print STDOUT qq|$_[0] ? <Enter> to accept, any other key for 'no'|;
	my $input = <STDIN>;
	chomp $input;
	return 1 if $input eq '';
	return 0;
}

# question, default answer
sub input_str {
	my $str = $_[1];
		
	while (1) {{
		print STDOUT qq|$_[0]: [$str]: type new value or <Enter> to accept default: |;
		my $input = <STDIN>;
		chomp $input;
		$str = $input if $input ne '';
		print qq|You entered [$str] -  Is this correct ? <Enter> to accept, or any other key to go back: |;
		$input = <STDIN>;
		chomp $input;
		return $str if !$input;			# accept default
		
	}}
}

sub getBackupFileName {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "nmis8-backup-$year-$mon-$mday-$hour$min.tar";
}

sub printBanner {
	my $string = shift;

	print <<EOF;

++++++++++++++++++++++++++++++++++++++++++++++++++++++
$string
++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF

	logInstall("\n\n###+++\n$string\n###+++\n");
}

sub execPrint {
	my $exec = shift;	
	my $out = `$exec 2>&1`;
	print $out;
	logInstall("\n\n###+++\nEXEC: $exec\n");
	logInstall($out);
	logInstall("###+++\n\n");
}

sub logInstall {
	my $string = shift;
	if ( $installLog ) {
		open(OUT,">>$installLog") or die "ERROR: Problem with file $installLog: $!\n";
		print OUT "$string\n";
		close(OUT);
	}
}

sub printHelp {
	print qq/
NMIS Install Script version $NMIS::VERSION

NMIS Copyright (C) Opmantek Limited (www.opmantek.com)
This program comes with ABSOLUTELY NO WARRANTY;

usage: $0 [site=$defaultSite] [fping=$defaultFping] [cpan=(true|false)]

Options:  
  site	Target site for installation, default is $defaultSite 
  fping	Location of the fping program, default is $defaultFping 
  cpan	Check Perl dependancies or not, default is true

eg: $0 site=$defaultSite fping=$defaultFping cpan=true

/;	
}