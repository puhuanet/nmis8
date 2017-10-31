#!/usr/bin/perl
#
#  Copyright 1999-2017 Opmantek Limited (www.opmantek.com)
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
# a command-line outage administration tool for NMIS
our $VERSION = "1.0.0";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use strict;
use FindBin;
use lib "$FindBin::RealBin/../lib";

use File::Basename;
use File::Spec;
use Data::Dumper;
use JSON::XS;

use func;
use NMIS;

my $bn = basename($0);
my $usage = "Usage: $bn act=[action to take] [extras...]

\t$bn act=list
\t$bn act=create [outage.A=B... outage.X.Y=Z...]
\t$bn act=update id=<outid> [outage.A=B... outage.X.Y=Z...]
\t$bn act={delete|show} id=<outid>
\t$bn act=check [id=<outid>] [node=X] [time=T]

list: shows overview of defined outage schedules
show: displays the details for an outage

create: creates new outage schedule
 for detailed help, run $0 act=create
update: updates existing outage schedule
 only the given outage.A, outage.X.Y properties are changed.

check: reports which outages would apply
 for one or all nodes, at the given time (or now)
\n\n";

my $create_help = qq|Supported Arguments for Outage Creation:

outage.description: free-form textual description.
outage.change_id: change management ticket identifier, used for event tagging

outage.frequency: one of 'once', 'daily', 'weekly' or 'monthly'
outage.start, outage.end: date and time of outage start and end, 
 format depends on frequency
  daily: "HH:MM" or "HH:MM:SS". 24:00 is allowed for end.
  weekly: "MDAY HH:MM" or "MDAY HH:MM:SS", MDAY one of 'Mon', 'Tue' etc.
  monthly: "D HH:MM:SS", "-D HH:MM:SS", "D HH:MM", "-D HH:MM"
   D is the numeric day of the month, 1..31.  -D counts from the end of the month, 
   -1 is the last day of the month, -2 the second to last etc.
  once: ISO8601 date time recommended,
   e.g. 2017-10-31T03:04:26+0000

outage.options: optional key=values to adjust NMIS' behaviour during an outage
outage.selector: any number of criteria for selecting devices for this outage
  selector keys: node.X or config.Y, node config or global config properties
  selector values: single string, /regex string/ or array or single strings.
  arrays must be given as separate indexed entries.
  all selectors must match for a node to be subject to the outage.

example: $0 act=create \\
outage.description='certain nodes are busy each month start' \\
outage.change_id='ticket #42' \\
outage.frequency=monthly outage.start="1 12:00" outage.end="1 13:30" \\
outage.selector.node.group.0="busybodies" \\
outage.selector.node.group.1="alsobad"\n\n|;

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));
my %args = getArguements(@ARGV);

my $debuglevel = setDebug($args{debug});
my $infolevel = setDebug($args{info});
my $confname = $args{conf} || "Config";

# get us a common config first
my $config = loadConfTable(conf=>$confname,
													 dir=>"$FindBin::RealBin/../conf",
													 debug => $debuglevel);
die "could not load configuration $confname!\n"
		if (!$config or !keys %$config);


# overview of all outages; no selector, no options
if ($args{act} eq "list")
{
	my $res = NMIS::find_outages;
	die "failed to find outages: $res->{error}\n" if (!$res->{success});

	if (!@{$res->{outages}})
	{
		print "No outages defined.\n";
		exit 0;
	}
	# header only if tty
	print join("\t", "ID", "Change ID", "Description",
						 "Frequency", "Start", "End")."\n" 
								 if (-t \*STDOUT);
			
	for my $orec (@{$res->{outages}}) 
	{
		print join("\t", $orec->{id}, 
							 $orec->{change_id}, 
							 $orec->{description},
							 $orec->{frequency},
							 $orec->{start},
							 $orec->{end}, )."\n";
	}
}
# remove one outage by id
elsif ($args{act} eq "delete")
{
	my $outid = $args{"id"};
	die "Cannot delete outage without id argument!\n\n$usage\n" if (!$outid);

	my $res = NMIS::remove_outage(id => $outid);
	die "failed to remove outage: $res->{error}\n" if (!$res->{success});
}
# show one outage structure in flattened form
elsif ($args{act} eq "show")
{
	my $outid = $args{"id"};
	die "Cannot show outage without id argument!\n\n$usage\n" if (!$outid);

	my $res = NMIS::find_outages(filter => { id => $outid });
	die "Failed to lookup outage: $res->{error}" if (!$res->{success});
	# there can be at most one with this id
	my $theoneandonly = $res->{outages}->[0];
	die "No outage with id $outid exists!\n" if (!$theoneandonly);

	my %flatearth = flatten($theoneandonly);
	for my $k (sort keys %flatearth)
	{
		my $val = $flatearth{$k};
		print "$k=$flatearth{$k}\n";
	}
	exit 0;
}
elsif ($args{act} eq "update")
{
	# update: id required 
	my $outid = $args{id};

	die "Cannot update outage without id argument!\n\n$usage\n"
			if (!$outid);
	
	# look it up, amend with given values
	my $res = NMIS::find_outages(filter => { id => $outid });
	die "Failed to lookup outage: $res->{error}" if (!$res->{success});
	# there can be at most one with this id
	my $updateme = $res->{outages}->[0];
	die "No outage with id $outid exists!\n" if (!$updateme);

	my $dosomething;
	for my $name (grep(/^outage\./, keys %args))
	{
		my $dotted = $name; $dotted =~ s/^outage\.//;
		$updateme->{$dotted} = (defined($args{$name}) && $args{$name} ne "")?
				$args{$name} : undef;
		++$dosomething;

		my $error = translate_dotfields($updateme);
		die "translation of arguments failed: $error\n" if ($error);
	}
	die "No changes for outage \"$outid\"!\n" if (!$dosomething);

	$updateme->{id} = $outid;			# bsts...
	my $res = NMIS::update_outage(%$updateme);
	die "Failed to update \"$outid\": $res->{error}\n" if (!$res->{success});
}
elsif ($args{act} eq "create")
{
	# create: id shouldn't be given

	# create w/o args? show help
	die $create_help if (!grep(/^outage\./, keys %args));

}
elsif ($args{act} eq "check")
{
	# fixme create!
 
}
else
{
	# fallback: complain about the arguments
	die "Could not parse arguments!\n\n$usage\n";
}

exit 0;

# translates EXISTING deep structure into key1.key2.key3 constructs,
# also supports key1.N.key2.M but toplevel thing must be hash.
# args: deep hash ref, prefix
# returns: flat hash
sub flatten
{
	my ($deep, $prefix) = @_;
	my %flattened;

	if ($prefix ne "")
	{
		$prefix .= ".";
	}
	else
	{
		$prefix='outage.';
	}

	if (ref($deep) eq "HASH")
	{
		for my $k (keys %$deep)
		{
			if (ref($deep->{$k}))
			{
				%flattened = (%flattened, flatten($deep->{$k}, "$prefix$k"));
			}
			else
			{
				$flattened{"$prefix$k"} = $deep->{$k};
			}
		}
	}
	elsif (ref($deep) eq "ARRAY")
	{
		for my $idx (0..$#$deep)
		{
			if (ref($deep->[$idx]))
			{
				%flattened = (%flattened, flatten($deep->[$idx], "$prefix$idx"));
			}
			else
			{
				$flattened{"$prefix$idx"} = $deep->[$idx];
			}
		}
	}
	else
	{
		die "invalid inputs to flatten: ".Dumper($deep)."\n";
	}
	return %flattened;
}

# this function translates a toplevel hash with fields in dot-notation
# into a deep structure. this is primarily needed in deep data objects
# handled by the crudcontroller but not necessarily just there.
#
# notations supported: fieldname.number for array,
# fieldname.subfield for hash and nested combos thereof
#
# args: resource record ref to fix up, which will be changed inplace!
# returns: undef if ok, error message if problems were encountered
sub translate_dotfields
{
	my ($resource) = @_;
	return "toplevel structure must be hash, not ".ref($resource) if (ref($resource) ne "HASH");

	# we support hashkey1.hashkey2.hashkey3, and hashkey1.NN.hashkey2.MM
	for my $dotkey (grep(/\./, keys %{$resource}))
	{
		my $target = $resource;
		my @indir = split(/\./, $dotkey);
		for my $idx (0..$#indir) # span the intermediate structure
		{
			my $thisstep = $indir[$idx];
			# numeric? make array, textual? make hash
			if ($thisstep =~ /^\d+$/)
			{
				# check that structure is ok.
				return "data conflict with $dotkey at step $idx: need array but found ".(ref($target) || "leaf value")
						if (ref($target) ne "ARRAY");
				# last one? park value
				if ($idx == $#indir)
				{
					$target->[$thisstep] = $resource->{$dotkey};
				}
				else
				{
					# check what the next one is and prime the obj
					$target = $target->[$thisstep] ||= ($indir[$idx+1] =~ /^\d+$/? []:  {} );
				}
			}
			else											# hash
			{
				# check that structure is ok.
				return "data conflict with $dotkey at step $idx: need hash but found ". (ref($target) || "leaf value")
						if (ref($target) ne "HASH");
				# last one? park value
				if ($idx == $#indir)
				{
					$target->{$thisstep} = $resource->{$dotkey};
				}
				else
				{
					# check what the next one is and prime the obj
					$target = $target->{$thisstep} ||= ($indir[$idx+1] =~ /^\d+$/? []:  {} );
				}
			}
		}
		delete $resource->{$dotkey};
	}
	return undef;
}
